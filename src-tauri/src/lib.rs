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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
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
        .invoke_handler(tauri::generate_handler![send_to_racket])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
