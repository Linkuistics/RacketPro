use ignore::WalkBuilder;
use regex::Regex;
use serde_json::{json, Value};
use std::fs;

/// Search files in `root` matching `query`.
/// Returns a JSON object with `results` array and `truncated` flag.
pub fn search_project(
    root: &str,
    query: &str,
    is_regex: bool,
    case_sensitive: bool,
    file_glob: Option<&str>,
    exclude_dirs: &[String],
) -> Value {
    let pattern = if is_regex {
        if case_sensitive {
            Regex::new(query)
        } else {
            Regex::new(&format!("(?i){query}"))
        }
    } else {
        let escaped = regex::escape(query);
        if case_sensitive {
            Regex::new(&escaped)
        } else {
            Regex::new(&format!("(?i){escaped}"))
        }
    };

    let re = match pattern {
        Ok(re) => re,
        Err(e) => {
            return json!({
                "error": format!("Invalid search pattern: {e}")
            });
        }
    };

    let mut results: Vec<Value> = Vec::new();
    let max_results = 500; // Prevent overwhelming the frontend

    let mut walker = WalkBuilder::new(root);
    walker
        .hidden(true) // skip hidden by default
        .git_ignore(true)
        .git_global(true);

    // Add custom exclude directories and optional file glob filter
    let mut overrides = ignore::overrides::OverrideBuilder::new(root);
    for dir in exclude_dirs {
        let _ = overrides.add(&format!("!{dir}/"));
    }
    if let Some(glob) = file_glob {
        let _ = overrides.add(glob);
    }
    if let Ok(built) = overrides.build() {
        walker.overrides(built);
    }

    for entry in walker.build() {
        if results.len() >= max_results {
            break;
        }

        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };

        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        // Skip binary files (read_to_string fails on non-UTF-8)
        let content = match fs::read_to_string(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        for (line_num, line) in content.lines().enumerate() {
            if results.len() >= max_results {
                break;
            }

            if re.is_match(line) {
                results.push(json!({
                    "file": path.to_string_lossy(),
                    "line": line_num + 1,
                    "text": line.trim(),
                    "col": re.find(line).map(|m| m.start()).unwrap_or(0),
                }));
            }
        }
    }

    json!({
        "results": results,
        "truncated": results.len() >= max_results,
    })
}
