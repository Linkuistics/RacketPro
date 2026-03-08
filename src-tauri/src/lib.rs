mod bridge;
mod debug;
mod fs;
mod pty;
mod search;
mod settings;

use bridge::RacketBridge;
use pty::PtyManager;
use serde_json::Value;
use std::sync::Arc;
use tauri::{Manager, State};
use tauri_plugin_dialog::DialogExt;

/// Application state shared across all Tauri command handlers.
pub struct AppState {
    pub bridge: Option<Arc<RacketBridge>>,
}

/// Tauri command: forward a JSON message from the WebView to the Racket process.
#[tauri::command]
fn send_to_racket(state: State<'_, AppState>, message: Value) -> Result<(), String> {
    state
        .bridge
        .as_ref()
        .ok_or_else(|| "Racket bridge is not running".to_string())?
        .send(message)
}

/// Tauri command: signal that the frontend has registered its listeners and is
/// ready to receive events.  Flushes any messages queued during startup.
#[tauri::command]
fn frontend_ready(state: State<'_, AppState>) {
    eprintln!("[bridge] frontend_ready: starting flush");
    if let Some(bridge) = state.bridge.as_ref() {
        bridge.flush_pending();
    }
    eprintln!("[bridge] frontend_ready: flush complete, returning to WebView");
}

/// Tauri command: write data to a PTY instance (keyboard input from the terminal).
#[tauri::command]
fn pty_input(id: String, data: String, state: State<'_, PtyManager>) -> Result<(), String> {
    state.write(&id, &data)
}

/// Tauri command: list directory contents for the file tree.
#[tauri::command]
fn list_dir(path: String, show_hidden: bool) -> Result<Vec<fs::DirEntry>, String> {
    fs::list_dir(&path, show_hidden)
}

/// Tauri command: resize a PTY instance (terminal dimensions changed).
#[tauri::command]
fn pty_resize(
    id: String,
    cols: u16,
    rows: u16,
    state: State<'_, PtyManager>,
) -> Result<(), String> {
    state.resize(&id, cols, rows)
}

/// Augment the process PATH so that Racket can be found when the app is
/// launched as a macOS `.app` bundle (which has a minimal default PATH).
fn augment_path() {
    let current = std::env::var("PATH").unwrap_or_default();

    // Well-known locations where Racket may live on macOS.
    let mut extra: Vec<String> = vec![
        "/opt/homebrew/bin".into(),  // Homebrew (Apple Silicon)
        "/usr/local/bin".into(),     // Homebrew (Intel) / manual install
    ];

    // Official Racket .dmg installer: /Applications/Racket v8.x/bin
    if let Ok(entries) = std::fs::read_dir("/Applications") {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if name.starts_with("Racket") {
                    let bin = entry.path().join("bin");
                    if bin.is_dir() {
                        extra.push(bin.to_string_lossy().into_owned());
                    }
                }
            }
        }
    }

    // Also try to read the user's login shell PATH for non-standard installs.
    if let Some(shell) = std::env::var("SHELL").ok().or_else(|| Some("/bin/zsh".into())) {
        if let Ok(output) = std::process::Command::new(&shell)
            .args(["-l", "-c", "echo $PATH"])
            .output()
        {
            if output.status.success() {
                let shell_path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                for p in shell_path.split(':') {
                    if !p.is_empty() && !extra.contains(&p.to_string()) && !current.contains(p) {
                        extra.push(p.to_string());
                    }
                }
            }
        }
    }

    // Prepend extra paths (preserving originals).
    let mut all_paths = extra;
    for p in current.split(':') {
        if !p.is_empty() && !all_paths.contains(&p.to_string()) {
            all_paths.push(p.to_string());
        }
    }
    // SAFETY: called once at startup before any threads are spawned.
    unsafe {
        std::env::set_var("PATH", all_paths.join(":"));
    }
    eprintln!("[init] PATH: {}", std::env::var("PATH").unwrap_or_default());
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Augment PATH for macOS .app bundles, which don't inherit the user's
    // shell PATH.  Without this, Racket (typically in /opt/homebrew/bin or
    // /usr/local/bin) won't be found when launched from Finder/Dock.
    augment_path();

    // Clear debug output from previous run
    debug::reset();

    // Devtools plugin must be initialized as early as possible.
    // It sets up a tracing subscriber, so we skip env_logger in debug builds
    // to avoid the "logger already initialized" panic.
    #[cfg(debug_assertions)]
    let devtools = tauri_plugin_devtools::init();

    #[cfg(not(debug_assertions))]
    env_logger::init();

    let mut builder = tauri::Builder::default();

    #[cfg(debug_assertions)]
    {
        builder = builder.plugin(devtools);
    }

    builder
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Prevent default close — let Racket decide
                api.prevent_close();
                // Send lifecycle:close-request to Racket
                let state = window.state::<AppState>();
                if let Some(bridge) = state.bridge.as_ref() {
                    let msg = serde_json::json!({
                        "type": "lifecycle:close-request",
                    });
                    if let Err(e) = bridge.send(msg) {
                        log::error!("Failed to send lifecycle:close-request: {e}");
                        // If we can't reach Racket, just close
                        window.destroy().ok();
                    }
                } else {
                    // No bridge running, just close
                    window.destroy().ok();
                }
            }
        })
        .setup(|app| {
            // Resolve the Racket script path.
            // Use CARGO_MANIFEST_DIR (src-tauri/) at compile time to find the
            // project root, so the path works regardless of runtime CWD.
            let script_path = {
                let manifest_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
                let project_root = manifest_dir.parent().unwrap();
                let local = project_root.join("racket/heavymental-core/main.rkt");
                if local.exists() {
                    local
                } else {
                    app.path()
                        .resource_dir()
                        .unwrap_or_default()
                        .join("racket/heavymental-core/main.rkt")
                }
            };

            let script_str = script_path.to_string_lossy().to_string();
            eprintln!("[bridge] Racket script path: {script_str}");

            // Check for Racket before starting bridge
            if std::process::Command::new("racket")
                .arg("--version")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_err()
            {
                eprintln!("[bridge] Racket not found on PATH");
                let handle = app.handle().clone();
                handle
                    .dialog()
                    .message("Racket is required but was not found on your PATH.\n\nPlease install Racket from https://racket-lang.org and ensure the 'racket' command is available in your terminal.")
                    .title("Racket Not Found")
                    .kind(tauri_plugin_dialog::MessageDialogKind::Error)
                    .show(|_| {});
            }

            // Create PtyManager first — shared between the bridge and Tauri commands.
            let pty_manager = PtyManager::new();

            let bridge = match RacketBridge::start(
                app.handle().clone(),
                &script_str,
                pty_manager.clone(),
            ) {
                Ok(b) => {
                    eprintln!("[bridge] Racket bridge started successfully");
                    let startup_settings = crate::settings::read_settings();
                    let _ = b.send(serde_json::json!({
                        "type": "settings:loaded",
                        "settings": startup_settings,
                    }));
                    Some(Arc::new(b))
                }
                Err(e) => {
                    eprintln!("[bridge] Failed to start Racket bridge: {e}");
                    None
                }
            };
            app.manage(AppState { bridge });
            app.manage(pty_manager);

            // Debug: file-based JS eval loop for unattended debugging.
            // Write JS to /tmp/heavymental-debug/eval-input.js → result appears
            // in eval-output.txt.  WebKit DevTools: use Cmd+Option+I manually.
            #[cfg(debug_assertions)]
            debug::start_eval_watcher(app.handle().clone());

            Ok(())
        })
        .on_menu_event(|app, event| {
            // Forward menu item clicks to Racket as menu:action events.
            let action = event.id().0.clone();
            log::info!("Menu event: {action}");

            let state = app.state::<AppState>();
            if let Some(bridge) = state.bridge.as_ref() {
                let msg = serde_json::json!({
                    "type": "menu:action",
                    "action": action,
                });
                if let Err(e) = bridge.send(msg) {
                    log::error!("Failed to send menu action to Racket: {e}");
                }
            }
        })
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            send_to_racket,
            frontend_ready,
            pty_input,
            pty_resize,
            list_dir,
            debug::debug_log,
            debug::debug_write,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
