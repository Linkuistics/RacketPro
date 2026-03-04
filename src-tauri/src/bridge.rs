use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Mutex};
use std::thread;
use tauri::menu::{MenuBuilder, MenuItem, PredefinedMenuItem, SubmenuBuilder};
use tauri::{AppHandle, Emitter};

/// Manages a child Racket process, routing JSON-RPC messages between the
/// Tauri WebView and Racket's stdin/stdout.
pub struct RacketBridge {
    /// Sender half of the channel used to write JSON messages to Racket's stdin.
    tx: mpsc::Sender<Value>,
    /// Handle to the child Racket process, wrapped in a Mutex so `stop()` can
    /// take ownership via `Option::take`.
    child: Mutex<Option<Child>>,
}

/// Convert a Racket-style shortcut string (e.g. "Cmd+Shift+Z") to a Tauri
/// accelerator string (e.g. "CmdOrCtrl+Shift+Z").
fn convert_shortcut(shortcut: &str) -> String {
    shortcut
        .split('+')
        .map(|part| match part.trim() {
            "Cmd" | "Command" => "CmdOrCtrl",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

/// Build a native menu from the JSON structure sent by Racket and set it on
/// the application.
fn handle_menu_set(app: &AppHandle, menu_data: &Value) {
    let items = match menu_data.as_array() {
        Some(arr) => arr,
        None => {
            log::error!("menu:set 'menu' field is not an array");
            return;
        }
    };

    let menu = match MenuBuilder::new(app).build() {
        Ok(m) => m,
        Err(e) => {
            log::error!("Failed to create menu: {e}");
            return;
        }
    };

    for submenu_def in items {
        let label = submenu_def
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or("?");

        let children = match submenu_def.get("children").and_then(|v| v.as_array()) {
            Some(c) => c,
            None => continue,
        };

        let mut submenu = SubmenuBuilder::new(app, label);

        for child in children {
            let child_label = child
                .get("label")
                .and_then(|v| v.as_str())
                .unwrap_or("");

            // Separator
            if child_label == "---" {
                submenu = submenu.separator();
                continue;
            }

            let action = child.get("action").and_then(|v| v.as_str());
            let shortcut = child.get("shortcut").and_then(|v| v.as_str());

            // Check for well-known predefined items
            match action {
                Some("quit") => {
                    match PredefinedMenuItem::quit(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create Quit item: {e}"),
                    }
                    continue;
                }
                Some("copy") => {
                    match PredefinedMenuItem::copy(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create Copy item: {e}"),
                    }
                    continue;
                }
                Some("cut") => {
                    match PredefinedMenuItem::cut(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create Cut item: {e}"),
                    }
                    continue;
                }
                Some("paste") => {
                    match PredefinedMenuItem::paste(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create Paste item: {e}"),
                    }
                    continue;
                }
                Some("select-all") => {
                    match PredefinedMenuItem::select_all(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create SelectAll item: {e}"),
                    }
                    continue;
                }
                _ => {}
            }

            // Regular menu item with optional shortcut
            let action_id = action.unwrap_or(child_label);
            let item_result = if let Some(sc) = shortcut {
                let accel = convert_shortcut(sc);
                MenuItem::with_id(app, action_id, child_label, true, Some(accel.as_str()))
            } else {
                MenuItem::with_id(app, action_id, child_label, true, None::<&str>)
            };

            match item_result {
                Ok(item) => {
                    submenu = submenu.item(&item);
                }
                Err(e) => {
                    log::error!("Failed to create menu item '{child_label}': {e}");
                }
            }
        }

        match submenu.build() {
            Ok(built) => {
                if let Err(e) = menu.append(&built) {
                    log::error!("Failed to append submenu '{label}': {e}");
                }
            }
            Err(e) => {
                log::error!("Failed to build submenu '{label}': {e}");
            }
        }
    }

    if let Err(e) = app.set_menu(menu) {
        log::error!("Failed to set menu on app: {e}");
    } else {
        log::info!("Native menu set successfully from Racket menu:set message");
    }
}

impl RacketBridge {
    /// Spawn a Racket process running `script_path` and wire up the message
    /// channels.  Returns `Err` only if the process cannot be spawned.
    pub fn start(app_handle: AppHandle, script_path: &str) -> Result<Self, String> {
        let mut child = Command::new("racket")
            .arg(script_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("Failed to spawn Racket process: {e}"))?;

        // --- stdout reader (blocking, runs in a std::thread) ----------------
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Failed to capture Racket stdout".to_string())?;

        let reader_handle = app_handle.clone();
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                match line {
                    Ok(text) => {
                        if text.trim().is_empty() {
                            continue;
                        }
                        match serde_json::from_str::<Value>(&text) {
                            Ok(msg) => {
                                let msg_type = msg
                                    .get("type")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("unknown");

                                // Intercept menu:set to build native menus
                                if msg_type == "menu:set" {
                                    if let Some(menu_data) = msg.get("menu") {
                                        let app = reader_handle.clone();
                                        let menu_data = menu_data.clone();
                                        // Menu operations must run on the main
                                        // thread, so dispatch via
                                        // run_on_main_thread.
                                        let _ = reader_handle.run_on_main_thread(
                                            move || {
                                                handle_menu_set(&app, &menu_data);
                                            },
                                        );
                                    } else {
                                        log::warn!(
                                            "menu:set message missing 'menu' field"
                                        );
                                    }
                                    continue;
                                }

                                let event_name = format!("racket:{msg_type}");
                                if let Err(e) =
                                    reader_handle.emit(&event_name, &msg)
                                {
                                    log::error!(
                                        "Failed to emit Tauri event {event_name}: {e}"
                                    );
                                }
                            }
                            Err(e) => {
                                log::warn!(
                                    "Non-JSON line from Racket: {e} — raw: {text}"
                                );
                            }
                        }
                    }
                    Err(e) => {
                        log::error!("Error reading Racket stdout: {e}");
                        break;
                    }
                }
            }
            log::info!("Racket stdout reader thread exiting");
        });

        // --- stdin writer (blocking, runs in a std::thread) -----------------
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| "Failed to capture Racket stdin".to_string())?;

        let (tx, rx) = mpsc::channel::<Value>();

        thread::spawn(move || {
            let mut stdin = stdin;
            for msg in rx {
                let mut line = match serde_json::to_string(&msg) {
                    Ok(s) => s,
                    Err(e) => {
                        log::error!("Failed to serialize message for Racket: {e}");
                        continue;
                    }
                };
                line.push('\n');
                if let Err(e) = stdin.write_all(line.as_bytes()) {
                    log::error!("Failed to write to Racket stdin: {e}");
                    break;
                }
                if let Err(e) = stdin.flush() {
                    log::error!("Failed to flush Racket stdin: {e}");
                    break;
                }
            }
            log::info!("Racket stdin writer thread exiting");
        });

        Ok(Self {
            tx,
            child: Mutex::new(Some(child)),
        })
    }

    /// Send a JSON message to the Racket process via its stdin.
    pub fn send(&self, msg: Value) -> Result<(), String> {
        self.tx
            .send(msg)
            .map_err(|e| format!("Failed to send message to Racket: {e}"))
    }

    /// Kill the child Racket process (idempotent).
    pub fn stop(&self) {
        if let Ok(mut guard) = self.child.lock() {
            if let Some(mut child) = guard.take() {
                log::info!("Stopping Racket process");
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

impl Drop for RacketBridge {
    fn drop(&mut self) {
        self.stop();
    }
}
