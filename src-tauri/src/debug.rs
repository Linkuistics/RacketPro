//! Debug harness — captures WebView console output and DOM snapshots to disk.
//!
//! All writes go to /tmp/heavymental-debug/.  Commands are registered unconditionally
//! but are no-ops in release builds, so the JS capture code runs harmlessly when
//! the backend isn't writing files.

use std::fs;
use std::io::Write;
use std::path::Path;

const DEBUG_DIR: &str = "/tmp/heavymental-debug";

/// Ensure the debug output directory exists.
fn ensure_dir() {
    let _ = fs::create_dir_all(DEBUG_DIR);
}

/// Append one or more newline-delimited log entries to console.log.
#[tauri::command]
pub fn debug_log(entries: String) {
    #[cfg(debug_assertions)]
    {
        ensure_dir();
        let path = Path::new(DEBUG_DIR).join("console.log");
        if let Ok(mut f) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(f, "{entries}");
        }
    }

    // Suppress unused-variable warning in release builds.
    #[cfg(not(debug_assertions))]
    let _ = entries;
}

/// Write (or overwrite) an arbitrary named file inside the debug directory.
/// Used for DOM snapshots, eval results, and ad-hoc debug dumps.
#[tauri::command]
pub fn debug_write(name: String, content: String) {
    #[cfg(debug_assertions)]
    {
        ensure_dir();
        // Sanitise the filename to prevent directory traversal.
        let safe = name.replace("..", "").replace('/', "_");
        let path = Path::new(DEBUG_DIR).join(safe);
        let _ = fs::write(path, content);
    }

    #[cfg(not(debug_assertions))]
    {
        let _ = (name, content);
    }
}

/// Start a background thread that watches for `/tmp/heavymental-debug/eval-input.js`.
/// When the file appears, its content is executed in the WebView via `eval()`.
/// The JS code can write results back via `__TAURI__.core.invoke('debug_write', ...)`.
/// The wrapper automatically captures the return value or any thrown error and
/// writes it to `eval-output.txt`.
#[cfg(debug_assertions)]
pub fn start_eval_watcher(handle: tauri::AppHandle) {
    use tauri::Manager;

    std::thread::spawn(move || {
        let input_path = Path::new(DEBUG_DIR).join("eval-input.js");
        loop {
            std::thread::sleep(std::time::Duration::from_millis(500));
            if input_path.exists() {
                if let Ok(code) = fs::read_to_string(&input_path) {
                    let _ = fs::remove_file(&input_path);
                    if code.trim().is_empty() {
                        continue;
                    }
                    if let Some(window) = handle.get_webview_window("main") {
                        // Wrap the user code to capture its return value (or error)
                        // and write it to eval-output.txt via the debug_write command.
                        let wrapped = format!(
                            r#"(async function() {{
    try {{
        var __result = await (async function() {{ {code} }})();
        if (__result !== undefined) {{
            window.__TAURI__.core.invoke('debug_write', {{
                name: 'eval-output.txt',
                content: typeof __result === 'object'
                    ? JSON.stringify(__result, null, 2)
                    : String(__result)
            }});
        }} else {{
            window.__TAURI__.core.invoke('debug_write', {{
                name: 'eval-output.txt',
                content: '(undefined)'
            }});
        }}
    }} catch(e) {{
        window.__TAURI__.core.invoke('debug_write', {{
            name: 'eval-output.txt',
            content: 'ERROR: ' + e.message + '\n' + (e.stack || '')
        }});
    }}
}})()"#
                        );
                        if let Err(e) = window.eval(&wrapped) {
                            let _ = fs::write(
                                Path::new(DEBUG_DIR).join("eval-output.txt"),
                                format!("RUST_EVAL_ERROR: {e}"),
                            );
                        }
                    }
                }
            }
        }
    });
}

/// Ensure the debug directory exists and truncate known output files so each
/// run starts fresh.  Does NOT remove the directory itself (callers may already
/// have file descriptors open for stderr redirection).
pub fn reset() {
    #[cfg(debug_assertions)]
    {
        let dir = Path::new(DEBUG_DIR);
        let _ = fs::create_dir_all(dir);
        // Truncate stale output files from previous runs
        for name in &["console.log", "dom.html"] {
            let p = dir.join(name);
            if p.exists() {
                let _ = fs::write(&p, "");
            }
        }
    }
}
