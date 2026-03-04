mod bridge;

use bridge::RacketBridge;
use serde_json::Value;
use std::sync::Arc;
use tauri::{Manager, State};

/// Application state shared across all Tauri command handlers.
pub struct AppState {
    pub bridge: Arc<RacketBridge>,
}

/// Tauri command: forward a JSON message from the WebView to the Racket process.
#[tauri::command]
fn send_to_racket(state: State<'_, AppState>, message: Value) -> Result<(), String> {
    state.bridge.send(message)
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

            match RacketBridge::start(app.handle().clone(), &script_str) {
                Ok(bridge) => {
                    app.manage(AppState {
                        bridge: Arc::new(bridge),
                    });
                    log::info!("Racket bridge started successfully");
                }
                Err(e) => {
                    log::error!("Failed to start Racket bridge: {e}");
                    // Provide a fallback AppState so commands don't panic when
                    // there is no Racket runtime.  We still let the app run so
                    // the UI can display an appropriate error.  The bridge will
                    // simply reject any messages sent to it.
                    //
                    // NOTE: We do *not* manage state here — commands that depend
                    // on AppState will return an internal error, which the
                    // frontend can surface to the user.
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![send_to_racket])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
