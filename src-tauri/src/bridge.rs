use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::sync::{mpsc, Mutex};
use std::thread;
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
                                let event_name = format!("racket:{msg_type}");
                                if let Err(e) = reader_handle.emit(&event_name, &msg) {
                                    log::error!("Failed to emit Tauri event {event_name}: {e}");
                                }
                            }
                            Err(e) => {
                                log::warn!("Non-JSON line from Racket: {e} — raw: {text}");
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
