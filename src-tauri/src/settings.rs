use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

/// Return the settings file path:
/// ~/Library/Application Support/com.linkuistics.heavymental/settings.json
pub fn settings_path() -> PathBuf {
    let mut path = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    path.push("com.linkuistics.heavymental");
    path.push("settings.json");
    path
}

/// Read settings from disk. Returns empty object if file doesn't exist.
pub fn read_settings() -> Value {
    let path = settings_path();
    match fs::read_to_string(&path) {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or(json!({})),
        Err(_) => json!({}),
    }
}

/// Write settings to disk. Creates parent directories if needed.
pub fn write_settings(settings: &Value) -> Result<(), String> {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create settings directory: {e}"))?;
    }
    let contents = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("Failed to serialize settings: {e}"))?;
    fs::write(&path, contents)
        .map_err(|e| format!("Failed to write settings: {e}"))?;
    Ok(())
}
