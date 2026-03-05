mod bridge;
mod debug;
mod fs;
mod pty;

use bridge::RacketBridge;
use pty::PtyManager;
use serde_json::Value;
use std::sync::Arc;
use tauri::{Manager, State};

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
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

            // Create PtyManager first — shared between the bridge and Tauri commands.
            let pty_manager = PtyManager::new();

            let bridge = match RacketBridge::start(
                app.handle().clone(),
                &script_str,
                pty_manager.clone(),
            ) {
                Ok(b) => {
                    eprintln!("[bridge] Racket bridge started successfully");
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
