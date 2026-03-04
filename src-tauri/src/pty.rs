use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde_json::json;
use std::collections::HashMap;
use std::io::Write;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

pub struct PtyInstance {
    writer: Box<dyn Write + Send>,
    _master: Box<dyn MasterPty + Send>,
}

#[derive(Clone)]
pub struct PtyManager {
    instances: Arc<Mutex<HashMap<String, PtyInstance>>>,
}

impl PtyManager {
    pub fn new() -> Self {
        Self {
            instances: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn create(
        &self,
        id: &str,
        command: &str,
        args: &[String],
        cols: u16,
        rows: u16,
        app_handle: AppHandle,
    ) -> Result<(), String> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("Failed to open PTY: {}", e))?;

        let mut cmd = CommandBuilder::new(command);
        for arg in args {
            cmd.arg(arg);
        }

        let _child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| format!("Failed to spawn command: {}", e))?;

        drop(pair.slave);

        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("Failed to clone reader: {}", e))?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("Failed to take writer: {}", e))?;

        {
            let mut instances = self.instances.lock().unwrap();
            instances.insert(
                id.to_string(),
                PtyInstance {
                    writer,
                    _master: pair.master,
                },
            );
        }

        let pty_id = id.to_string();
        let instances_ref = self.instances.clone();
        std::thread::spawn(move || {
            let mut buf_reader = std::io::BufReader::new(reader);
            let mut buf = [0u8; 4096];
            loop {
                match std::io::Read::read(&mut buf_reader, &mut buf) {
                    Ok(0) => {
                        let _ =
                            app_handle.emit("pty:exit", json!({ "id": pty_id, "code": 0 }));
                        break;
                    }
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buf[..n]).to_string();
                        let _ = app_handle
                            .emit("pty:output", json!({ "id": pty_id, "data": data }));
                    }
                    Err(e) => {
                        log::error!("PTY read error for {}: {}", pty_id, e);
                        let _ =
                            app_handle.emit("pty:exit", json!({ "id": pty_id, "code": -1 }));
                        break;
                    }
                }
            }
            let mut instances = instances_ref.lock().unwrap();
            instances.remove(&pty_id);
        });

        Ok(())
    }

    pub fn write(&self, id: &str, data: &str) -> Result<(), String> {
        let mut instances = self.instances.lock().unwrap();
        let instance = instances
            .get_mut(id)
            .ok_or_else(|| format!("PTY not found: {}", id))?;
        instance
            .writer
            .write_all(data.as_bytes())
            .map_err(|e| format!("PTY write error: {}", e))?;
        instance
            .writer
            .flush()
            .map_err(|e| format!("PTY flush error: {}", e))?;
        Ok(())
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let instances = self.instances.lock().unwrap();
        let instance = instances
            .get(id)
            .ok_or_else(|| format!("PTY not found: {}", id))?;
        instance
            ._master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| format!("PTY resize error: {}", e))?;
        Ok(())
    }

    pub fn kill(&self, id: &str) -> Result<(), String> {
        let mut instances = self.instances.lock().unwrap();
        instances
            .remove(id)
            .ok_or_else(|| format!("PTY not found: {}", id))?;
        Ok(())
    }
}
