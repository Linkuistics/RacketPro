use crate::pty::PtyManager;
use notify::{self, EventKind, RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use tauri::menu::{MenuBuilder, MenuItem, PredefinedMenuItem, SubmenuBuilder};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::DialogExt;

/// Manages a child Racket process, routing JSON-RPC messages between the
/// Tauri WebView and Racket's stdin/stdout.
pub struct RacketBridge {
    /// Sender half of the channel used to write JSON messages to Racket's stdin.
    tx: mpsc::Sender<Value>,
    /// Handle to the child Racket process, wrapped in a Mutex so `stop()` can
    /// take ownership via `Option::take`.
    child: Mutex<Option<Child>>,
    /// Whether the frontend has signalled readiness.
    ready: Arc<AtomicBool>,
    /// Messages queued before the frontend was ready.
    pending: Arc<Mutex<Vec<(String, Value)>>>,
    /// Tauri app handle, used to emit events when flushing.
    app_handle: AppHandle,
    /// PTY manager, needed to process deferred pty:create messages.
    pty_manager: PtyManager,
    /// Filesystem watcher manager for extension fs:watch support.
    fs_watcher: FsWatchManager,
}

/// Manages filesystem watchers for extensions.
#[derive(Clone)]
pub struct FsWatchManager {
    watchers: Arc<Mutex<HashMap<String, notify::RecommendedWatcher>>>,
}

impl FsWatchManager {
    pub fn new() -> Self {
        Self {
            watchers: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn watch(&self, id: &str, path: &str, tx: &mpsc::Sender<Value>) -> Result<(), String> {
        let tx = tx.clone();
        let watch_id = id.to_string();
        let mut watcher = notify::recommended_watcher(
            move |res: Result<notify::Event, notify::Error>| match res {
                Ok(event) => {
                    let kind = match event.kind {
                        EventKind::Create(_) => "create",
                        EventKind::Modify(_) => "modify",
                        EventKind::Remove(_) => "remove",
                        _ => return,
                    };
                    for path in &event.paths {
                        let msg = json!({
                            "type": "fs:change",
                            "watch-id": watch_id,
                            "event": kind,
                            "path": path.to_string_lossy(),
                        });
                        let _ = tx.send(msg);
                    }
                }
                Err(e) => {
                    eprintln!("[fs-watch] Error: {e}");
                }
            },
        )
        .map_err(|e| format!("Failed to create watcher: {e}"))?;

        watcher
            .watch(std::path::Path::new(path), RecursiveMode::Recursive)
            .map_err(|e| format!("Failed to watch path: {e}"))?;

        self.watchers
            .lock()
            .unwrap()
            .insert(id.to_string(), watcher);
        Ok(())
    }

    pub fn unwatch(&self, id: &str) {
        self.watchers.lock().unwrap().remove(id);
    }

    pub fn unwatch_all(&self) {
        self.watchers.lock().unwrap().clear();
    }
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

    // On macOS, the first submenu is always the "application menu" (shown
    // under the app name).  Prepend a standard one so that "File" appears
    // in its expected position as the second submenu.
    #[cfg(target_os = "macos")]
    {
        let mut app_submenu = SubmenuBuilder::new(app, "HeavyMental");
        if let Ok(item) = PredefinedMenuItem::about(app, Some("About HeavyMental"), None) {
            app_submenu = app_submenu.item(&item);
        }
        app_submenu = app_submenu.separator();
        if let Ok(item) = PredefinedMenuItem::services(app, Some("Services")) {
            app_submenu = app_submenu.item(&item);
        }
        app_submenu = app_submenu.separator();
        if let Ok(item) = PredefinedMenuItem::hide(app, Some("Hide HeavyMental")) {
            app_submenu = app_submenu.item(&item);
        }
        if let Ok(item) = PredefinedMenuItem::hide_others(app, Some("Hide Others")) {
            app_submenu = app_submenu.item(&item);
        }
        if let Ok(item) = PredefinedMenuItem::show_all(app, Some("Show All")) {
            app_submenu = app_submenu.item(&item);
        }
        app_submenu = app_submenu.separator();
        if let Ok(item) = PredefinedMenuItem::quit(app, Some("Quit HeavyMental")) {
            app_submenu = app_submenu.item(&item);
        }
        match app_submenu.build() {
            Ok(built) => {
                if let Err(e) = menu.append(&built) {
                    log::error!("Failed to append macOS app submenu: {e}");
                }
            }
            Err(e) => {
                log::error!("Failed to build macOS app submenu: {e}");
            }
        }
    }

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
                Some("undo") => {
                    match PredefinedMenuItem::undo(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create Undo item: {e}"),
                    }
                    continue;
                }
                Some("redo") => {
                    match PredefinedMenuItem::redo(app, Some(child_label)) {
                        Ok(item) => {
                            submenu = submenu.item(&item);
                        }
                        Err(e) => log::error!("Failed to create Redo item: {e}"),
                    }
                    continue;
                }
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

/// Process a single message from Racket: intercept if appropriate, otherwise
/// forward to the frontend via a Tauri event.
/// Process a single message from Racket: intercept if appropriate, otherwise
/// forward to the frontend via a Tauri event.
///
/// IMPORTANT: We must NOT call `app.emit()` directly from the reader thread.
/// On macOS, wry's `evaluate_script` uses `dispatch_sync` to the main queue
/// when called from a non-main thread.  If the main thread is busy servicing
/// WebView IPC (e.g. `event.listen()` responses), the reader thread deadlocks
/// waiting for `dispatch_sync` to complete.
///
/// Instead, we dispatch the emit to the main thread via `run_on_main_thread`,
/// which is async (non-blocking).  The emit then runs on the main thread
/// where wry calls `evaluateJavaScript` directly without `dispatch_sync`.
fn process_message(
    msg_type: &str,
    msg: &Value,
    app: &AppHandle,
    tx: &mpsc::Sender<Value>,
    pty: &PtyManager,
    fs_watcher: &FsWatchManager,
) {
    let intercepted = handle_intercepted_message(msg_type, msg, app, tx, pty, fs_watcher);
    if !intercepted {
        let event_name = format!("racket:{msg_type}");
        let app_clone = app.clone();
        let msg_clone = msg.clone();
        eprintln!("[bridge]   emit → {event_name}");
        let _ = app.run_on_main_thread(move || {
            if let Err(e) = app_clone.emit(&event_name, &msg_clone) {
                eprintln!("[bridge]   emit FAILED {event_name}: {e}");
            }
            eprintln!("[bridge]   emit ✓ {event_name}");
        });
    }
}

/// Handle messages from Racket that should be intercepted by the Rust layer
/// rather than forwarded to the frontend.  Returns `true` if the message was
/// handled (and should NOT be forwarded).
fn handle_intercepted_message(
    msg_type: &str,
    msg: &Value,
    app: &AppHandle,
    tx: &mpsc::Sender<Value>,
    pty: &PtyManager,
    fs_watcher: &FsWatchManager,
) -> bool {
    match msg_type {
        // ----- Menu --------------------------------------------------------
        "menu:set" => {
            if let Some(menu_data) = msg.get("menu") {
                let app_clone = app.clone();
                let menu_data = menu_data.clone();
                eprintln!("[bridge]   menu:set scheduling on main thread");
                let _ = app.run_on_main_thread(move || {
                    eprintln!("[bridge]   menu:set handler START (main thread)");
                    handle_menu_set(&app_clone, &menu_data);
                    eprintln!("[bridge]   menu:set handler DONE (main thread)");
                });
                eprintln!("[bridge]   menu:set scheduled");
            } else {
                log::warn!("menu:set message missing 'menu' field");
            }
            true
        }

        // ----- PTY ---------------------------------------------------------
        "pty:create" => {
            eprintln!("[bridge]   pty:create START");
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let command = msg
                .get("command")
                .and_then(|v| v.as_str())
                .unwrap_or("/bin/sh");
            let args: Vec<String> = msg
                .get("args")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let cols = msg.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
            let rows = msg.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;

            if let Err(e) = pty.create(id, command, &args, cols, rows, app.clone()) {
                eprintln!("[bridge]   pty:create FAILED: {e}");
            } else {
                // Notify the frontend so the terminal component can report its
                // current dimensions to the new PTY process.  Without this, a
                // restarted PTY inherits the default 80×24 size while xterm.js
                // may be much smaller, causing Racket's xrepl to crash.
                //
                // Use run_on_main_thread (dispatch_async) instead of a direct
                // app.emit() to avoid blocking the bridge reader thread.  The
                // new PTY's reader thread starts immediately and pumps output
                // callbacks onto the main thread; a synchronous emit here would
                // block behind those callbacks on macOS WKWebView.
                let emit_app = app.clone();
                let emit_id = id.to_string();
                let _ = app.run_on_main_thread(move || {
                    let _ = emit_app.emit("pty:created", json!({ "id": emit_id }));
                });
            }
            eprintln!("[bridge]   pty:create DONE");
            true
        }
        "pty:write" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let data = msg.get("data").and_then(|v| v.as_str()).unwrap_or("");
            if let Err(e) = pty.write(id, data) {
                log::error!("pty:write failed: {e}");
            }
            true
        }
        "pty:resize" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let cols = msg.get("cols").and_then(|v| v.as_u64()).unwrap_or(80) as u16;
            let rows = msg.get("rows").and_then(|v| v.as_u64()).unwrap_or(24) as u16;
            if let Err(e) = pty.resize(id, cols, rows) {
                log::error!("pty:resize failed: {e}");
            }
            true
        }
        "pty:kill" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            if let Err(e) = pty.kill(id) {
                log::error!("pty:kill failed: {e}");
            }
            true
        }

        // ----- File I/O ----------------------------------------------------
        "file:read" => {
            let path = msg
                .get("path")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let tx = tx.clone();
            match crate::fs::read_file(&path) {
                Ok(result) => {
                    let _ = tx.send(result);
                }
                Err(e) => {
                    let _ = tx.send(serde_json::json!({
                        "type": "file:read:error",
                        "path": path,
                        "error": e,
                    }));
                }
            }
            true
        }
        "file:write" => {
            let path = msg
                .get("path")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let content = msg
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let tx = tx.clone();
            match crate::fs::write_file(&path, &content) {
                Ok(result) => {
                    let _ = tx.send(result);
                }
                Err(e) => {
                    let _ = tx.send(serde_json::json!({
                        "type": "file:write:error",
                        "path": path,
                        "error": e,
                    }));
                }
            }
            true
        }

        // ----- File Dialogs (blocking — run on separate threads) -----------
        "file:open-dialog" => {
            let tx = tx.clone();
            let app = app.clone();
            thread::spawn(move || {
                let picked = app
                    .dialog()
                    .file()
                    .add_filter("Racket", &["rkt", "scrbl", "rhm"])
                    .add_filter("All", &["*"])
                    .blocking_pick_file();

                match picked {
                    Some(file_path) => match file_path.into_path() {
                        Ok(path_buf) => {
                            let path = path_buf.to_string_lossy().to_string();
                            match crate::fs::read_file(&path) {
                                Ok(result) => {
                                    let _ = tx.send(result);
                                }
                                Err(e) => {
                                    let _ = tx.send(serde_json::json!({
                                        "type": "file:read:error",
                                        "path": path,
                                        "error": e,
                                    }));
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(serde_json::json!({
                                "type": "file:read:error",
                                "path": "",
                                "error": format!("Invalid file path: {e}"),
                            }));
                        }
                    },
                    None => {
                        let _ = tx.send(serde_json::json!({
                            "type": "file:open-dialog:cancelled",
                        }));
                    }
                }
            });
            true
        }
        "file:save-dialog" => {
            let content = msg
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let tx = tx.clone();
            let app = app.clone();
            thread::spawn(move || {
                let picked = app
                    .dialog()
                    .file()
                    .add_filter("Racket", &["rkt", "scrbl", "rhm"])
                    .add_filter("All", &["*"])
                    .blocking_save_file();

                match picked {
                    Some(file_path) => match file_path.into_path() {
                        Ok(path_buf) => {
                            let path = path_buf.to_string_lossy().to_string();
                            match crate::fs::write_file(&path, &content) {
                                Ok(result) => {
                                    let _ = tx.send(result);
                                }
                                Err(e) => {
                                    let _ = tx.send(serde_json::json!({
                                        "type": "file:write:error",
                                        "path": path,
                                        "error": e,
                                    }));
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(serde_json::json!({
                                "type": "file:write:error",
                                "path": "",
                                "error": format!("Invalid file path: {e}"),
                            }));
                        }
                    },
                    None => {
                        let _ = tx.send(serde_json::json!({
                            "type": "file:save-dialog:cancelled",
                        }));
                    }
                }
            });
            true
        }

        // ----- Dialogs ---------------------------------------------------
        "dialog:confirm" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let title = msg.get("title").and_then(|v| v.as_str()).unwrap_or("Confirm").to_string();
            let message = msg.get("message").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let save_label = msg.get("save_label").and_then(|v| v.as_str()).unwrap_or("Save").to_string();
            let dont_save_label = msg.get("dont_save_label").and_then(|v| v.as_str()).unwrap_or("Don\u{2019}t Save").to_string();
            let cancel_label = msg.get("cancel_label").and_then(|v| v.as_str()).unwrap_or("Cancel").to_string();
            let tx = tx.clone();
            let app = app.clone();
            thread::spawn(move || {
                use tauri_plugin_dialog::{MessageDialogButtons, MessageDialogKind, MessageDialogResult};
                let result = app.dialog()
                    .message(&message)
                    .title(&title)
                    .kind(MessageDialogKind::Warning)
                    .buttons(MessageDialogButtons::YesNoCancelCustom(
                        save_label.clone(),
                        dont_save_label.clone(),
                        cancel_label.clone(),
                    ))
                    .blocking_show_with_result();
                let choice = match result {
                    MessageDialogResult::Custom(ref s) if s == &save_label => "save",
                    MessageDialogResult::Custom(ref s) if s == &dont_save_label => "dont-save",
                    MessageDialogResult::Yes => "save",
                    MessageDialogResult::No => "dont-save",
                    _ => "cancel",
                };
                let _ = tx.send(serde_json::json!({
                    "type": "dialog:confirm:result",
                    "id": id,
                    "choice": choice,
                }));
            });
            true
        }

        // ----- Lifecycle ------------------------------------------------
        "lifecycle:quit" => {
            let app_caller = app.clone();
            let app_inner = app.clone();
            let _ = app_caller.run_on_main_thread(move || {
                if let Some(window) = app_inner.get_webview_window("main") {
                    window.destroy().ok();
                }
            });
            true
        }

        // ----- JS Eval (Racket → WebView → Racket) --------------------------
        "eval:exec" => {
            let id = msg
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let code = msg
                .get("code")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let app_caller = app.clone();
            let app_inner = app.clone();

            // Run eval on the main thread where the WebView lives
            let _ = app_caller.run_on_main_thread(move || {
                if let Some(window) = app_inner.get_webview_window("main") {
                    // Wrap the code to:
                    // 1. Execute it (async-capable)
                    // 2. Capture the return value or error
                    // 3. Send the result back to Racket via send_to_racket
                    let escaped_id = id.replace('\\', "\\\\").replace('"', "\\\"");
                    let wrapped = format!(
                        r#"(async function() {{
    try {{
        var __result = await (async function() {{ {code} }})();
        var __val;
        if (__result === undefined) {{
            __val = null;
        }} else if (typeof __result === 'object') {{
            try {{ __val = JSON.parse(JSON.stringify(__result)); }} catch(e) {{ __val = String(__result); }}
        }} else {{
            __val = __result;
        }}
        window.__TAURI__.core.invoke('send_to_racket', {{ message: {{
            type: 'eval:result',
            id: "{escaped_id}",
            value: __val
        }} }});
    }} catch(e) {{
        window.__TAURI__.core.invoke('send_to_racket', {{ message: {{
            type: 'eval:error',
            id: "{escaped_id}",
            error: e.message,
            stack: e.stack || ''
        }} }});
    }}
}})()"#
                    );
                    if let Err(e) = window.eval(&wrapped) {
                        log::error!("eval:exec failed for id={id}: {e}");
                        let _ = app_inner.emit("racket:eval:error", serde_json::json!({
                            "type": "eval:error",
                            "id": id,
                            "error": format!("Rust eval error: {e}"),
                        }));
                    }
                }
            });
            true
        }

        // ----- Filesystem Watching -----------------------------------------
        "fs:watch" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let path = msg.get("path").and_then(|v| v.as_str()).unwrap_or("");
            if let Err(e) = fs_watcher.watch(id, path, tx) {
                log::error!("fs:watch failed: {e}");
            }
            true
        }
        "fs:unwatch" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            fs_watcher.unwatch(id);
            true
        }
        "fs:unwatch-all" => {
            fs_watcher.unwatch_all();
            true
        }

        // Not intercepted — forward to frontend
        _ => false,
    }
}

impl RacketBridge {
    /// Spawn a Racket process running `script_path` and wire up the message
    /// channels.  Returns `Err` only if the process cannot be spawned.
    pub fn start(
        app_handle: AppHandle,
        script_path: &str,
        pty_manager: PtyManager,
    ) -> Result<Self, String> {
        let mut child = Command::new("racket")
            .arg(script_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("Failed to spawn Racket process: {e}"))?;

        // --- stdin writer (blocking, runs in a std::thread) -----------------
        // Created before the stdout reader so that tx can be cloned into the
        // reader thread (for sending responses back to Racket).
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

        // --- stdout reader (blocking, runs in a std::thread) ----------------
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Failed to capture Racket stdout".to_string())?;

        let ready = Arc::new(AtomicBool::new(false));
        let pending: Arc<Mutex<Vec<(String, Value)>>> = Arc::new(Mutex::new(Vec::new()));

        let fs_watcher = FsWatchManager::new();

        let reader_handle = app_handle.clone();
        let reader_ready = Arc::clone(&ready);
        let reader_pending = Arc::clone(&pending);
        let reader_tx = tx.clone();
        let reader_pty = pty_manager.clone();
        let reader_fs_watcher = fs_watcher.clone();
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
                                    .unwrap_or("unknown")
                                    .to_string();

                                // Queue ALL messages until the frontend is ready.
                                // This prevents intercepted handlers (menu:set,
                                // pty:create) from touching the main thread or
                                // emitting events while WKWebView is still loading,
                                // which can cause a deadlock on macOS.
                                if !reader_ready.load(Ordering::Acquire) {
                                    eprintln!("[bridge] queuing (frontend not ready): {msg_type}");
                                    if let Ok(mut q) = reader_pending.lock() {
                                        q.push((msg_type, msg));
                                    }
                                    continue;
                                }

                                eprintln!("[bridge] processing live: {msg_type}");
                                process_message(
                                    &msg_type,
                                    &msg,
                                    &reader_handle,
                                    &reader_tx,
                                    &reader_pty,
                                    &reader_fs_watcher,
                                );
                                eprintln!("[bridge] processing done: {msg_type}");
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

        Ok(Self {
            tx,
            child: Mutex::new(Some(child)),
            ready,
            pending,
            app_handle,
            pty_manager,
            fs_watcher,
        })
    }

    /// Send a JSON message to the Racket process via its stdin.
    pub fn send(&self, msg: Value) -> Result<(), String> {
        self.tx
            .send(msg)
            .map_err(|e| format!("Failed to send message to Racket: {e}"))
    }

    /// Flush all queued messages to the frontend and mark as ready.
    /// Called once when the frontend signals that its listeners are registered.
    pub fn flush_pending(&self) {
        // Set ready first so the reader thread starts processing directly
        self.ready.store(true, Ordering::Release);

        let queued: Vec<(String, Value)> = {
            let mut q = self.pending.lock().expect("pending lock poisoned");
            std::mem::take(&mut *q)
        };

        let count = queued.len();
        eprintln!("[bridge] flush_pending: {count} queued messages");
        for (i, (msg_type, msg)) in queued.iter().enumerate() {
            eprintln!("[bridge] flush {}/{count}: {msg_type}", i + 1);
            process_message(
                msg_type,
                msg,
                &self.app_handle,
                &self.tx,
                &self.pty_manager,
                &self.fs_watcher,
            );
        }
        eprintln!("[bridge] flush_pending complete");
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
