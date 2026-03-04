use serde::{Deserialize, Serialize};
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

/// A single directory entry returned by `list_dir`.
#[derive(Serialize, Deserialize)]
pub struct DirEntry {
    pub name: String,
    /// "file" or "dir"
    pub kind: String,
    /// File extension (empty string for dirs / extensionless files)
    pub ext: String,
}

/// List directory contents. Returns dirs first, then files, both sorted
/// alphabetically. Skips dotfiles unless `show_hidden` is true.
pub fn list_dir(path: &str, show_hidden: bool) -> Result<Vec<DirEntry>, String> {
    let dir = Path::new(path);
    if !dir.is_dir() {
        return Err(format!("Not a directory: {}", path));
    }

    let mut dirs: Vec<DirEntry> = Vec::new();
    let mut files: Vec<DirEntry> = Vec::new();

    let entries = std::fs::read_dir(dir)
        .map_err(|e| format!("Failed to read dir {}: {}", path, e))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("Error reading entry: {}", e))?;
        let name = entry.file_name().to_string_lossy().to_string();

        // Skip hidden files unless requested
        if !show_hidden && name.starts_with('.') {
            continue;
        }

        let file_type = entry
            .file_type()
            .map_err(|e| format!("Error reading file type: {}", e))?;

        if file_type.is_dir() {
            dirs.push(DirEntry {
                name,
                kind: "dir".to_string(),
                ext: String::new(),
            });
        } else {
            let ext = Path::new(&name)
                .extension()
                .map(|e| e.to_string_lossy().to_string())
                .unwrap_or_default();
            files.push(DirEntry {
                name,
                kind: "file".to_string(),
                ext,
            });
        }
    }

    dirs.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    files.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    dirs.append(&mut files);
    Ok(dirs)
}
