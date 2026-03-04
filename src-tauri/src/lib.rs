mod bridge;

use bridge::RacketBridge;
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
    if let Some(bridge) = state.bridge.as_ref() {
        bridge.flush_pending();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        .setup(|app| {
            // Resolve the Racket script path.
            // First try relative to the current working directory, then fall
            // back to the Tauri resource directory.
            let script_path = {
                let local = std::path::PathBuf::from("./racket/mrracket-core/main.rkt");
                if local.exists() {
                    local
                } else {
                    app.path()
                        .resource_dir()
                        .unwrap_or_default()
                        .join("racket/mrracket-core/main.rkt")
                }
            };

            let script_str = script_path.to_string_lossy().to_string();
            log::info!("Racket script path: {script_str}");

            let bridge = match RacketBridge::start(app.handle().clone(), &script_str) {
                Ok(b) => {
                    log::info!("Racket bridge started successfully");
                    Some(Arc::new(b))
                }
                Err(e) => {
                    log::error!("Failed to start Racket bridge: {e}");
                    None
                }
            };
            app.manage(AppState { bridge });

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
        .invoke_handler(tauri::generate_handler![send_to_racket, frontend_ready])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
