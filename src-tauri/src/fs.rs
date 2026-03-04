use serde_json::{json, Value};
use std::path::Path;

/// Read a file and return its content.
pub fn read_file(path: &str) -> Result<Value, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Failed to read {}: {}", path, e))?;
    Ok(json!({
        "type": "file:read:result",
        "path": path,
        "content": content
    }))
}

/// Write content to a file.
pub fn write_file(path: &str, content: &str) -> Result<Value, String> {
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create dirs for {}: {}", path, e))?;
    }
    std::fs::write(path, content)
        .map_err(|e| format!("Failed to write {}: {}", path, e))?;
    Ok(json!({
        "type": "file:write:result",
        "path": path,
        "success": true
    }))
}
