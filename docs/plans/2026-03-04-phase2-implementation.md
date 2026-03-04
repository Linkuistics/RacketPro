# Phase 2: Editor + REPL — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn MrRacket into a minimum viable IDE — Monaco editor, xterm.js terminal with PTY-backed REPL, file open/save via native dialogs, Racket syntax highlighting, and a Run button that loads definitions DrRacket-style.

**Architecture:** Racket controls lifecycle (create PTY, open files, trigger runs). Rust manages PTY processes and file I/O. Frontend owns internal state of Monaco and xterm.js. Three new Lit primitives (`mr-split`, `mr-editor`, `mr-terminal`) plus two chrome components (`mr-toolbar`, `mr-statusbar`). PTY data flows directly Rust↔Frontend — Racket only controls lifecycle and sends occasional commands (like `,enter <file>` on Run).

**Tech Stack:**
- Monaco Editor via `monaco-esm` (vendored ESM, workers bundled)
- xterm.js via `@xterm/xterm` + `@xterm/addon-fit` (vendored ESM)
- `portable-pty` 0.9 (Rust crate, cross-platform PTY)
- `tauri-plugin-dialog` 2.x (native open/save dialogs)
- Monarch tokenizer for Racket syntax highlighting (Monaco-native, no WASM needed)

---

## Task 1: Vendor Monaco Editor and xterm.js

**Files:**
- Create: `frontend/vendor/monaco/` (Monaco ESM bundle)
- Create: `frontend/vendor/xterm/` (xterm.js ESM + CSS)
- Modify: `frontend/index.html` (add import map entries)

**Step 1: Install Monaco ESM and copy to vendor**

```bash
cd /tmp && mkdir mr-vendor && cd mr-vendor
npm init -y
npm install monaco-esm
```

Find the main ESM entry and worker files:
```bash
ls node_modules/monaco-esm/dist/
```

Copy the entire dist directory:
```bash
mkdir -p /Users/antony/Development/Linkuistics/MrRacket/frontend/vendor/monaco
cp -r node_modules/monaco-esm/dist/* /Users/antony/Development/Linkuistics/MrRacket/frontend/vendor/monaco/
```

If `monaco-esm` has a different structure, look for the main `.mjs` or `.js` entry point that exports `monaco` and `loadCss`. Copy that file plus any `workers/` directory.

**Step 2: Install xterm.js and copy to vendor**

```bash
npm install @xterm/xterm @xterm/addon-fit
```

Copy xterm ESM files:
```bash
mkdir -p /Users/antony/Development/Linkuistics/MrRacket/frontend/vendor/xterm
cp node_modules/@xterm/xterm/lib/xterm.mjs /Users/antony/Development/Linkuistics/MrRacket/frontend/vendor/xterm/
cp node_modules/@xterm/xterm/css/xterm.css /Users/antony/Development/Linkuistics/MrRacket/frontend/vendor/xterm/
cp node_modules/@xterm/addon-fit/lib/addon-fit.mjs /Users/antony/Development/Linkuistics/MrRacket/frontend/vendor/xterm/
```

If the file names differ (e.g., `.js` instead of `.mjs`), adapt accordingly. The key exports are `Terminal` from xterm and `FitAddon` from addon-fit.

**Step 3: Update import map in index.html**

Add entries to the existing `<script type="importmap">` block in `frontend/index.html`:

```json
{
  "imports": {
    "lit": "./vendor/lit/lit-core.min.js",
    "@preact/signals-core": "./vendor/signals/signals-core.mjs",
    "monaco-esm": "./vendor/monaco/index.mjs",
    "@xterm/xterm": "./vendor/xterm/xterm.mjs",
    "@xterm/addon-fit": "./vendor/xterm/addon-fit.mjs"
  }
}
```

Adjust the Monaco path based on the actual entry point file name found in Step 1.

**Step 4: Add xterm CSS to index.html**

Add a `<link>` tag in the `<head>`:

```html
<link rel="stylesheet" href="./vendor/xterm/xterm.css">
```

**Step 5: Verify imports**

Add a temporary test in `frontend/core/main.js`:

```javascript
// Temporary — remove after verification
import('monaco-esm').then(m => console.log('Monaco loaded:', !!m.monaco));
import('@xterm/xterm').then(m => console.log('xterm loaded:', !!m.Terminal));
```

Run: `cd /Users/antony/Development/Linkuistics/MrRacket && cargo tauri dev`

Check browser console for "Monaco loaded: true" and "xterm loaded: true". Remove the test imports after verifying.

**Step 6: Clean up and commit**

```bash
rm -rf /tmp/mr-vendor
```

```bash
git add frontend/vendor/monaco/ frontend/vendor/xterm/ frontend/index.html
git commit -m "feat: vendor Monaco Editor and xterm.js as local ESM"
```

---

## Task 2: Rust PTY Module

**Files:**
- Create: `src-tauri/src/pty.rs`
- Modify: `src-tauri/Cargo.toml` (add portable-pty)
- Modify: `src-tauri/src/lib.rs` (register PtyManager state + commands)

**Step 1: Add portable-pty dependency**

In `src-tauri/Cargo.toml`, add to `[dependencies]`:

```toml
portable-pty = "0.9"
```

Run: `cd src-tauri && cargo check` — verify it compiles.

**Step 2: Write pty.rs**

Create `src-tauri/src/pty.rs`:

```rust
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

pub struct PtyInstance {
    writer: Box<dyn Write + Send>,
    // master is kept alive to keep the PTY open
    _master: Box<dyn MasterPty + Send>,
}

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

        // Drop slave — we only need the master side
        drop(pair.slave);

        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| format!("Failed to clone reader: {}", e))?;

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| format!("Failed to take writer: {}", e))?;

        // Store instance
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

        // Spawn output reader thread
        let pty_id = id.to_string();
        let instances_ref = self.instances.clone();
        std::thread::spawn(move || {
            let mut buf_reader = BufReader::new(reader);
            let mut buf = [0u8; 4096];
            loop {
                match std::io::Read::read(&mut buf_reader, &mut buf) {
                    Ok(0) => {
                        // PTY closed
                        let _ = app_handle.emit("pty:exit", json!({ "id": pty_id, "code": 0 }));
                        break;
                    }
                    Ok(n) => {
                        let data = String::from_utf8_lossy(&buf[..n]).to_string();
                        let _ = app_handle
                            .emit("pty:output", json!({ "id": pty_id, "data": data }));
                    }
                    Err(e) => {
                        log::error!("PTY read error for {}: {}", pty_id, e);
                        let _ = app_handle
                            .emit("pty:exit", json!({ "id": pty_id, "code": -1 }));
                        break;
                    }
                }
            }
            // Clean up
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
        // Dropping the instance closes the PTY
        Ok(())
    }
}
```

**Step 3: Add Tauri commands for frontend PTY access**

Add to `src-tauri/src/lib.rs`:

```rust
mod pty;
use pty::PtyManager;

#[tauri::command]
fn pty_input(id: String, data: String, state: tauri::State<'_, PtyManager>) -> Result<(), String> {
    state.write(&id, &data)
}

#[tauri::command]
fn pty_resize(id: String, cols: u16, rows: u16, state: tauri::State<'_, PtyManager>) -> Result<(), String> {
    state.resize(&id, cols, rows)
}
```

Register in the Tauri builder:

```rust
.manage(PtyManager::new())
.invoke_handler(tauri::generate_handler![send_to_racket, frontend_ready, pty_input, pty_resize])
```

**Step 4: Verify compilation**

Run: `cd src-tauri && cargo check`
Expected: compiles without errors.

**Step 5: Commit**

```bash
git add src-tauri/src/pty.rs src-tauri/Cargo.toml src-tauri/src/lib.rs
git commit -m "feat: add PTY module with portable-pty"
```

---

## Task 3: Rust File I/O Module

**Files:**
- Create: `src-tauri/src/fs.rs`
- Modify: `src-tauri/Cargo.toml` (add tauri-plugin-dialog)
- Modify: `src-tauri/src/lib.rs` (register dialog plugin)

**Step 1: Add tauri-plugin-dialog dependency**

In `src-tauri/Cargo.toml`:

```toml
tauri-plugin-dialog = "2"
```

**Step 2: Write fs.rs**

Create `src-tauri/src/fs.rs`:

```rust
use serde_json::{json, Value};
use std::path::Path;

/// Read a file and return its content.
pub fn read_file(path: &str) -> Result<Value, String> {
    let content =
        std::fs::read_to_string(path).map_err(|e| format!("Failed to read {}: {}", path, e))?;
    Ok(json!({
        "type": "file:read:result",
        "path": path,
        "content": content
    }))
}

/// Write content to a file.
pub fn write_file(path: &str, content: &str) -> Result<Value, String> {
    // Create parent directories if needed
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create dirs for {}: {}", path, e))?;
    }
    std::fs::write(path, content).map_err(|e| format!("Failed to write {}: {}", path, e))?;
    Ok(json!({
        "type": "file:write:result",
        "path": path,
        "success": true
    }))
}
```

**Step 3: Register dialog plugin in lib.rs**

```rust
mod fs;

// In the builder:
.plugin(tauri_plugin_dialog::init())
```

**Step 4: Verify compilation**

Run: `cd src-tauri && cargo check`

**Step 5: Commit**

```bash
git add src-tauri/src/fs.rs src-tauri/Cargo.toml src-tauri/src/lib.rs
git commit -m "feat: add file I/O module and dialog plugin"
```

---

## Task 4: Update Bridge Routing + Tauri Permissions

**Files:**
- Modify: `src-tauri/src/bridge.rs` (route pty:* and file:* messages)
- Modify: `src-tauri/src/lib.rs` (pass PtyManager to bridge)
- Modify: `src-tauri/capabilities/default.json` (add dialog permissions)

**Step 1: Update bridge.rs to route new message types**

In the stdout reader thread where messages from Racket are processed, add routing for PTY and file messages. The existing pattern intercepts `menu:set` — extend it for `pty:*` and `file:*`:

```rust
// In the stdout reader match on msg_type:
match msg_type.as_str() {
    "menu:set" => {
        // existing menu handling...
    }
    "pty:create" => {
        let id = msg["id"].as_str().unwrap_or("default").to_string();
        let command = msg["command"].as_str().unwrap_or("racket").to_string();
        let args: Vec<String> = msg["args"]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        let cols = msg["cols"].as_u64().unwrap_or(80) as u16;
        let rows = msg["rows"].as_u64().unwrap_or(24) as u16;
        let pty_mgr = pty_manager.clone();
        let app = app_handle.clone();
        std::thread::spawn(move || {
            if let Err(e) = pty_mgr.create(&id, &command, &args, cols, rows, app) {
                log::error!("Failed to create PTY {}: {}", id, e);
            }
        });
    }
    "pty:write" => {
        let id = msg["id"].as_str().unwrap_or("default");
        let data = msg["data"].as_str().unwrap_or("");
        if let Err(e) = pty_manager.write(id, data) {
            log::error!("PTY write error: {}", e);
        }
    }
    "pty:kill" => {
        let id = msg["id"].as_str().unwrap_or("default");
        if let Err(e) = pty_manager.kill(id) {
            log::error!("PTY kill error: {}", e);
        }
    }
    "file:read" => {
        let path = msg["path"].as_str().unwrap_or("").to_string();
        let writer = writer_tx.clone();
        std::thread::spawn(move || {
            let result = match crate::fs::read_file(&path) {
                Ok(v) => v,
                Err(e) => serde_json::json!({
                    "type": "file:read:error",
                    "path": path,
                    "error": e
                }),
            };
            let _ = writer.send(result);
        });
    }
    "file:write" => {
        let path = msg["path"].as_str().unwrap_or("").to_string();
        let content = msg["content"].as_str().unwrap_or("").to_string();
        let writer = writer_tx.clone();
        std::thread::spawn(move || {
            let result = match crate::fs::write_file(&path, &content) {
                Ok(v) => v,
                Err(e) => serde_json::json!({
                    "type": "file:write:error",
                    "path": path,
                    "error": e
                }),
            };
            let _ = writer.send(result);
        });
    }
    "file:open-dialog" => {
        let app = app_handle.clone();
        let writer = writer_tx.clone();
        std::thread::spawn(move || {
            use tauri_plugin_dialog::DialogExt;
            let path = app.dialog()
                .file()
                .add_filter("Racket", &["rkt", "scrbl", "rhm"])
                .add_filter("All", &["*"])
                .blocking_pick_file();
            let result = match path {
                Some(p) => {
                    let path_str = p.path().to_string_lossy().to_string();
                    match crate::fs::read_file(&path_str) {
                        Ok(v) => v,
                        Err(e) => serde_json::json!({
                            "type": "file:read:error",
                            "path": path_str,
                            "error": e
                        }),
                    }
                }
                None => serde_json::json!({
                    "type": "file:open-dialog:cancelled"
                }),
            };
            let _ = writer.send(result);
        });
    }
    "file:save-dialog" => {
        let app = app_handle.clone();
        let content = msg["content"].as_str().unwrap_or("").to_string();
        let writer = writer_tx.clone();
        std::thread::spawn(move || {
            use tauri_plugin_dialog::DialogExt;
            let path = app.dialog()
                .file()
                .add_filter("Racket", &["rkt", "scrbl", "rhm"])
                .blocking_save_file();
            let result = match path {
                Some(p) => {
                    let path_str = p.path().to_string_lossy().to_string();
                    match crate::fs::write_file(&path_str, &content) {
                        Ok(v) => v,
                        Err(e) => serde_json::json!({
                            "type": "file:write:error",
                            "path": path_str,
                            "error": e
                        }),
                    }
                }
                None => serde_json::json!({
                    "type": "file:save-dialog:cancelled"
                }),
            };
            let _ = writer.send(result);
        });
    }
    _ => {
        // Forward to frontend (existing behavior)
        // ...
    }
}
```

The bridge constructor needs to accept a `PtyManager` reference. Update the `RacketBridge::new()` signature to take `pty_manager: PtyManager` (or `Arc<PtyManager>`) and store it alongside the existing fields.

**Step 2: Pass PtyManager to bridge in lib.rs**

In the Tauri setup handler where `RacketBridge::new()` is called, create the PtyManager and pass it:

```rust
let pty_manager = PtyManager::new();
// Store a clone in Tauri state for frontend commands
app.manage(pty_manager.clone());
// Pass to bridge for Racket-side PTY commands
let bridge = RacketBridge::new(&racket_script_path, app.handle().clone(), pty_manager)?;
```

Note: `PtyManager` needs to be `Clone`. Add `#[derive(Clone)]` or implement Clone by wrapping instances in `Arc`.

Update `PtyManager` to be clonable:
```rust
#[derive(Clone)]
pub struct PtyManager {
    instances: Arc<Mutex<HashMap<String, Arc<Mutex<PtyInstance>>>>>,
}
```

Adjust methods accordingly — the inner `PtyInstance` will need `Arc<Mutex<>>` wrapping.

**Step 3: Update Tauri capabilities**

Modify `src-tauri/capabilities/default.json`:

```json
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "MrRacket default capabilities",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "dialog:default"
  ]
}
```

**Step 4: Verify compilation**

Run: `cd src-tauri && cargo check`

**Step 5: Commit**

```bash
git add src-tauri/src/bridge.rs src-tauri/src/lib.rs src-tauri/capabilities/default.json
git commit -m "feat: route PTY and file messages through bridge"
```

---

## Task 5: Build mr-split and mr-toolbar Components

**Files:**
- Create: `frontend/core/primitives/chrome.js` (mr-toolbar, mr-statusbar)
- Create: `frontend/core/primitives/split.js` (mr-split)

**Step 1: Write mr-split**

Create `frontend/core/primitives/split.js`:

```javascript
import { LitElement, html, css } from 'lit';

export class MrSplit extends LitElement {
  static properties = {
    direction: { type: String },
    ratio: { type: Number },
    minSize: { type: Number, attribute: 'min-size' },
  };

  static styles = css`
    :host {
      display: flex;
      width: 100%;
      height: 100%;
      overflow: hidden;
    }
    :host([direction='horizontal']) {
      flex-direction: row;
    }
    :host([direction='vertical']) {
      flex-direction: column;
    }
    .pane {
      overflow: hidden;
      position: relative;
    }
    .divider {
      flex-shrink: 0;
      background: var(--mr-divider-color, #e0e0e0);
      z-index: 10;
    }
    :host([direction='vertical']) .divider {
      height: 4px;
      cursor: row-resize;
    }
    :host([direction='horizontal']) .divider {
      width: 4px;
      cursor: col-resize;
    }
    .divider:hover {
      background: var(--mr-divider-hover, #90caf9);
    }
  `;

  constructor() {
    super();
    this.direction = 'vertical';
    this.ratio = 0.5;
    this.minSize = 50;
    this._dragging = false;
  }

  render() {
    const isVert = this.direction === 'vertical';
    const firstSize = `${this.ratio * 100}%`;
    const secondSize = `${(1 - this.ratio) * 100}%`;
    const firstStyle = isVert
      ? `height: ${firstSize}; width: 100%`
      : `width: ${firstSize}; height: 100%`;
    const secondStyle = isVert
      ? `height: ${secondSize}; width: 100%`
      : `width: ${secondSize}; height: 100%`;

    return html`
      <div class="pane" style="${firstStyle}">
        <slot name="first"></slot>
      </div>
      <div class="divider" @mousedown=${this._startDrag}></div>
      <div class="pane" style="${secondStyle}">
        <slot name="second"></slot>
      </div>
    `;
  }

  _startDrag(e) {
    e.preventDefault();
    this._dragging = true;
    const rect = this.getBoundingClientRect();
    const isVert = this.direction === 'vertical';

    const onMove = (e) => {
      if (!this._dragging) return;
      const pos = isVert ? e.clientY - rect.top : e.clientX - rect.left;
      const total = isVert ? rect.height : rect.width;
      const minRatio = this.minSize / total;
      const maxRatio = 1 - minRatio;
      this.ratio = Math.max(minRatio, Math.min(maxRatio, pos / total));
    };

    const onUp = () => {
      this._dragging = false;
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }
}

customElements.define('mr-split', MrSplit);
```

**Step 2: Write mr-toolbar and mr-statusbar**

Create `frontend/core/primitives/chrome.js`:

```javascript
import { LitElement, html, css } from 'lit';
import { resolveValue } from '../cells.js';

export class MrToolbar extends LitElement {
  static styles = css`
    :host {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 12px;
      background: var(--mr-toolbar-bg, #f5f5f5);
      border-bottom: 1px solid var(--mr-border, #e0e0e0);
      flex-shrink: 0;
      min-height: 36px;
    }
    ::slotted(*) {
      flex-shrink: 0;
    }
  `;

  render() {
    return html`<slot></slot>`;
  }
}

export class MrStatusbar extends LitElement {
  static properties = {
    content: { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      padding: 2px 12px;
      background: var(--mr-statusbar-bg, #f0f0f0);
      border-top: 1px solid var(--mr-border, #e0e0e0);
      font-size: 12px;
      color: var(--mr-statusbar-fg, #666);
      flex-shrink: 0;
      min-height: 24px;
    }
  `;

  constructor() {
    super();
    this.content = '';
  }

  render() {
    return html`${resolveValue(this.content)}`;
  }
}

customElements.define('mr-toolbar', MrToolbar);
customElements.define('mr-statusbar', MrStatusbar);
```

**Step 3: Commit**

```bash
git add frontend/core/primitives/split.js frontend/core/primitives/chrome.js
git commit -m "feat: add mr-split, mr-toolbar, and mr-statusbar components"
```

---

## Task 6: Build mr-editor Component + Racket Syntax

**Files:**
- Create: `frontend/core/primitives/editor.js` (Monaco wrapper)
- Create: `frontend/core/racket-language.js` (Monarch tokenizer)

**Step 1: Write Racket Monarch tokenizer**

Create `frontend/core/racket-language.js`:

```javascript
// Racket syntax highlighting for Monaco (Monarch tokenizer)
// Adapted from VS Code Racket extension patterns

export const racketLanguageId = 'racket';

export const racketLanguageConfig = {
  comments: {
    lineComment: ';',
    blockComment: ['#|', '|#'],
  },
  brackets: [
    ['(', ')'],
    ['[', ']'],
    ['{', '}'],
  ],
  autoClosingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"' },
    { open: '|', close: '|' },
  ],
  surroundingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"' },
  ],
};

export const racketTokenProvider = {
  defaultToken: '',
  keywords: [
    'define', 'define-syntax', 'define-values', 'define-struct',
    'lambda', 'λ', 'let', 'let*', 'letrec', 'let-values',
    'if', 'cond', 'else', 'when', 'unless', 'case', 'match',
    'begin', 'begin0', 'do',
    'and', 'or', 'not',
    'require', 'provide', 'module', 'module+', 'module*',
    'struct', 'class', 'interface',
    'for', 'for/list', 'for/fold', 'for/hash', 'for/and', 'for/or',
    'for*', 'for*/list', 'for*/fold',
    'with-handlers', 'parameterize', 'syntax-rules', 'syntax-case',
    'quote', 'quasiquote', 'unquote', 'unquote-splicing',
    'set!', 'define-syntax-rule',
    'apply', 'map', 'filter', 'foldl', 'foldr',
    'values', 'call-with-values',
    'raise', 'error', 'with-handlers',
  ],
  constants: ['#t', '#f', '#true', '#false', 'null', 'void'],
  tokenizer: {
    root: [
      // #lang line
      [/^#lang\s+\S+/, 'keyword.control'],

      // Block comments (nested)
      [/#\|/, 'comment', '@blockComment'],

      // Line comments
      [/;.*$/, 'comment'],

      // Strings
      [/"/, 'string', '@string'],

      // Characters
      [/#\\(space|tab|newline|return|nul|backspace|delete|escape|[^\s])/, 'string.character'],

      // Numbers
      [/#[bodxei][\d.+\-/]+/, 'number'],
      [/[+-]?\d+\.\d*([eE][+-]?\d+)?/, 'number.float'],
      [/[+-]?\d+\/\d+/, 'number.fraction'],
      [/[+-]?\d+/, 'number'],

      // Booleans
      [/#t(rue)?|#f(alse)?/, 'constant.language'],

      // Byte strings
      [/#"/, 'string', '@string'],

      // Regex
      [/#rx"/, 'regexp', '@string'],
      [/#px"/, 'regexp', '@string'],

      // Quote/quasiquote shorthand
      [/['`],?@?/, 'keyword.operator'],

      // Hash literals
      [/#hash[ei]?/, 'keyword'],

      // Vectors
      [/#\d*\(/, 'keyword'],

      // Symbols and identifiers
      [/[a-zA-Z_!$%&*+\-./:<=>?@^~][\w!$%&*+\-./:<=>?@^~]*/, {
        cases: {
          '@keywords': 'keyword',
          '@constants': 'constant.language',
          '@default': 'identifier',
        },
      }],

      // Brackets
      [/[()[\]{}]/, '@brackets'],

      // Whitespace
      [/\s+/, 'white'],
    ],

    string: [
      [/[^"\\]+/, 'string'],
      [/\\./, 'string.escape'],
      [/"/, 'string', '@pop'],
    ],

    blockComment: [
      [/#\|/, 'comment', '@push'],
      [/\|#/, 'comment', '@pop'],
      [/./, 'comment'],
    ],
  },
};
```

**Step 2: Write mr-editor component**

Create `frontend/core/primitives/editor.js`:

```javascript
import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';
import { racketLanguageId, racketLanguageConfig, racketTokenProvider } from '../racket-language.js';

let monacoInstance = null;
let languageRegistered = false;

async function getMonaco() {
  if (monacoInstance) return monacoInstance;
  const mod = await import('monaco-esm');
  if (mod.loadCss) mod.loadCss();
  monacoInstance = mod.monaco;

  // Register Racket language once
  if (!languageRegistered) {
    monacoInstance.languages.register({ id: racketLanguageId });
    monacoInstance.languages.setLanguageConfiguration(racketLanguageId, racketLanguageConfig);
    monacoInstance.languages.setMonarchTokensProvider(racketLanguageId, racketTokenProvider);
    languageRegistered = true;
  }

  return monacoInstance;
}

export class MrEditor extends LitElement {
  static properties = {
    filePath: { type: String, attribute: 'file-path' },
    language: { type: String },
    theme: { type: String },
    readOnly: { type: Boolean, attribute: 'read-only' },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      overflow: hidden;
    }
    #editor-container {
      width: 100%;
      height: 100%;
    }
  `;

  constructor() {
    super();
    this.filePath = '';
    this.language = 'racket';
    this.theme = 'vs';
    this.readOnly = false;
    this._editor = null;
    this._dirty = false;
    this._unsubs = [];
  }

  render() {
    return html`<div id="editor-container"></div>`;
  }

  async firstUpdated() {
    const monaco = await getMonaco();
    const container = this.shadowRoot.getElementById('editor-container');

    this._editor = monaco.editor.create(container, {
      value: '',
      language: this.language,
      theme: this.theme,
      readOnly: this.readOnly,
      automaticLayout: true,
      minimap: { enabled: false },
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace",
      tabSize: 2,
      scrollBeyondLastLine: false,
    });

    // Track dirty state
    this._editor.onDidChangeModelContent(() => {
      if (!this._dirty) {
        this._dirty = true;
        dispatch('editor:dirty', { path: this.filePath, dirty: true });
      }
    });

    // Ctrl/Cmd+S → save request
    this._editor.addCommand(
      monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS,
      () => {
        const content = this._editor.getValue();
        dispatch('editor:save-request', { path: this.filePath, content });
      }
    );

    // Listen for editor:open messages
    this._unsubs.push(
      onMessage('editor:open', (payload) => {
        if (payload.path !== undefined) this.filePath = payload.path;
        if (payload.content !== undefined) {
          this._editor.setValue(payload.content);
          this._dirty = false;
        }
        if (payload.language) {
          const model = this._editor.getModel();
          if (model) {
            monacoInstance.editor.setModelLanguage(model, payload.language);
          }
        }
      })
    );

    // Listen for editor:set-content messages
    this._unsubs.push(
      onMessage('editor:set-content', (payload) => {
        if (payload.content !== undefined) {
          this._editor.setValue(payload.content);
          this._dirty = false;
        }
      })
    );
  }

  // Called after file save succeeds
  markClean() {
    this._dirty = false;
    dispatch('editor:dirty', { path: this.filePath, dirty: false });
  }

  getValue() {
    return this._editor ? this._editor.getValue() : '';
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._unsubs.forEach((unsub) => unsub());
    if (this._editor) {
      this._editor.dispose();
      this._editor = null;
    }
  }
}

customElements.define('mr-editor', MrEditor);
```

**Step 3: Commit**

```bash
git add frontend/core/primitives/editor.js frontend/core/racket-language.js
git commit -m "feat: add mr-editor component with Racket syntax highlighting"
```

---

## Task 7: Build mr-terminal Component

**Files:**
- Create: `frontend/core/primitives/terminal.js`

**Step 1: Write mr-terminal**

Create `frontend/core/primitives/terminal.js`:

```javascript
import { LitElement, html, css } from 'lit';

// Dynamic imports — these are heavy modules
let Terminal = null;
let FitAddon = null;

async function loadXterm() {
  if (Terminal) return;
  const xtermMod = await import('@xterm/xterm');
  const fitMod = await import('@xterm/addon-fit');
  Terminal = xtermMod.Terminal;
  FitAddon = fitMod.FitAddon;
}

export class MrTerminal extends LitElement {
  static properties = {
    ptyId: { type: String, attribute: 'pty-id' },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background: #1e1e1e;
    }
    #terminal-container {
      width: 100%;
      height: 100%;
    }
  `;

  constructor() {
    super();
    this.ptyId = '';
    this._terminal = null;
    this._fitAddon = null;
    this._tauriUnlistens = [];
    this._resizeObserver = null;
  }

  render() {
    return html`<div id="terminal-container"></div>`;
  }

  async firstUpdated() {
    await loadXterm();
    const container = this.shadowRoot.getElementById('terminal-container');

    this._terminal = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'JetBrains Mono', 'Fira Code', monospace",
      theme: {
        background: '#1e1e1e',
        foreground: '#d4d4d4',
      },
    });

    this._fitAddon = new FitAddon();
    this._terminal.loadAddon(this._fitAddon);
    this._terminal.open(container);

    // Fit to container
    requestAnimationFrame(() => {
      this._fitAddon.fit();
    });

    // Auto-resize on container size change
    this._resizeObserver = new ResizeObserver(() => {
      requestAnimationFrame(() => {
        if (this._fitAddon) {
          this._fitAddon.fit();
          this._sendResize();
        }
      });
    });
    this._resizeObserver.observe(container);

    // User input → PTY
    this._terminal.onData((data) => {
      if (this.ptyId) {
        window.__TAURI__.core.invoke('pty_input', {
          id: this.ptyId,
          data: data,
        });
      }
    });

    // PTY output → terminal
    const tauriListen = window.__TAURI__.event.listen;

    const unlistenOutput = await tauriListen('pty:output', (event) => {
      const { id, data } = event.payload;
      if (id === this.ptyId && this._terminal) {
        this._terminal.write(data);
      }
    });
    this._tauriUnlistens.push(unlistenOutput);

    const unlistenExit = await tauriListen('pty:exit', (event) => {
      const { id, code } = event.payload;
      if (id === this.ptyId && this._terminal) {
        this._terminal.write(`\r\n[Process exited with code ${code}]\r\n`);
      }
    });
    this._tauriUnlistens.push(unlistenExit);
  }

  _sendResize() {
    if (this.ptyId && this._terminal) {
      window.__TAURI__.core.invoke('pty_resize', {
        id: this.ptyId,
        cols: this._terminal.cols,
        rows: this._terminal.rows,
      });
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._tauriUnlistens.forEach((unlisten) => unlisten());
    if (this._resizeObserver) this._resizeObserver.disconnect();
    if (this._terminal) {
      this._terminal.dispose();
      this._terminal = null;
    }
  }
}

customElements.define('mr-terminal', MrTerminal);
```

**Step 2: Commit**

```bash
git add frontend/core/primitives/terminal.js
git commit -m "feat: add mr-terminal component wrapping xterm.js"
```

---

## Task 8: Update Renderer and Boot Sequence

**Files:**
- Modify: `frontend/core/renderer.js` (add slot handling for mr-split, register new types)
- Modify: `frontend/core/main.js` (import new primitives)

**Step 1: Update renderer.js**

The renderer's `renderNode` function needs two changes:

1. Handle slot assignment for mr-split children (first child gets `slot="first"`, second gets `slot="second"`)
2. No new prop mappings needed — the new components use their own prop names

In `renderNode`, after creating the element and setting props, add:

```javascript
// In renderNode, when appending to parent:
if (parent && parent.tagName === 'MR-SPLIT') {
  const existingChildren = parent.querySelectorAll('[slot]');
  el.slot = existingChildren.length === 0 ? 'first' : 'second';
}
```

Also add prop mappings for the new components. In the prop mapping section:

```javascript
// Map Racket prop names to component attributes
const propMap = {
  text: 'content',        // existing
  style: 'textStyle',     // existing
  onClick: 'onClick',     // existing
  'file-path': 'file-path',
  'pty-id': 'pty-id',
  'min-size': 'min-size',
  'read-only': 'read-only',
};
```

**Step 2: Update main.js**

Add imports for the new primitive modules:

```javascript
// Add alongside existing primitive imports
import './primitives/split.js';
import './primitives/chrome.js';
import './primitives/editor.js';
import './primitives/terminal.js';
```

**Step 3: Verify app still boots**

Run: `cargo tauri dev`
Expected: App opens with existing counter demo. No errors in console. New components registered but not yet in the layout tree.

**Step 4: Commit**

```bash
git add frontend/core/renderer.js frontend/core/main.js
git commit -m "feat: register new components and update renderer for mr-split"
```

---

## Task 9: Build Racket editor.rkt and repl.rkt

**Files:**
- Create: `racket/mrracket-core/editor.rkt`
- Create: `racket/mrracket-core/repl.rkt`
- Modify: `racket/mrracket-core/info.rkt` (if exists, add deps)

**Step 1: Write editor.rkt**

Create `racket/mrracket-core/editor.rkt`:

```racket
#lang racket/base

(require "protocol.rkt"
         "cell.rkt")

(provide handle-editor-event
         open-file
         save-current-file
         new-file
         current-file-path
         current-file-dirty?)

;; State
(define current-file-path (make-parameter ""))
(define current-file-dirty? (make-parameter #f))

;; Handle editor events from frontend
(define (handle-editor-event msg)
  (define name (message-ref msg 'name ""))
  (cond
    [(string=? name "editor:dirty")
     (define dirty (message-ref msg 'dirty #f))
     (current-file-dirty? dirty)
     (cell-set! "file-dirty" dirty)]
    [(string=? name "editor:save-request")
     (define path (message-ref msg 'path ""))
     (define content (message-ref msg 'content ""))
     (when (string=? path "")
       ;; No path yet — trigger save dialog
       (send-message! (make-message "file:save-dialog"
                                     'content content))
       (void))
     (when (not (string=? path ""))
       (save-file path content))]
    [else (void)]))

;; Request file open dialog from Rust
(define (open-file)
  (send-message! (make-message "file:open-dialog")))

;; Save to a specific path
(define (save-file path content)
  (send-message! (make-message "file:write"
                               'path path
                               'content content)))

;; Handle file operation results from Rust
(define (handle-file-result msg)
  (define type (message-type msg))
  (cond
    [(string=? type "file:read:result")
     (define path (message-ref msg 'path ""))
     (define content (message-ref msg 'content ""))
     (current-file-path path)
     (current-file-dirty? #f)
     (cell-set! "current-file" (path->filename path))
     (cell-set! "file-dirty" #f)
     ;; Tell frontend to load the file
     (send-message! (make-message "editor:open"
                                   'path path
                                   'content content
                                   'language (detect-language path)))]
    [(string=? type "file:write:result")
     (current-file-dirty? #f)
     (cell-set! "file-dirty" #f)]
    [(string=? type "file:open-dialog:cancelled")
     (void)]
    [(string=? type "file:save-dialog:cancelled")
     (void)]
    [else (void)]))

;; Save the current file
(define (save-current-file content)
  (define path (current-file-path))
  (if (string=? path "")
      (send-message! (make-message "file:save-dialog" 'content content))
      (save-file path content)))

;; Start a new empty file
(define (new-file)
  (current-file-path "")
  (current-file-dirty? #f)
  (cell-set! "current-file" "untitled.rkt")
  (cell-set! "file-dirty" #f)
  (send-message! (make-message "editor:open"
                               'path ""
                               'content "#lang racket\n\n"
                               'language "racket")))

;; Helpers
(define (path->filename path)
  (define parts (regexp-split #rx"[/\\\\]" path))
  (if (null? parts) path (last parts)))

(define (detect-language path)
  (cond
    [(regexp-match? #rx"\\.rkt$" path) "racket"]
    [(regexp-match? #rx"\\.scrbl$" path) "racket"]
    [(regexp-match? #rx"\\.rhm$" path) "racket"]
    [else "plaintext"]))
```

**Step 2: Write repl.rkt**

Create `racket/mrracket-core/repl.rkt`:

```racket
#lang racket/base

(require "protocol.rkt"
         "cell.rkt")

(provide start-repl
         run-file
         handle-repl-event)

;; State
(define repl-pty-id "repl")

;; Create the REPL PTY at startup
(define (start-repl)
  (cell-set! "repl-status" "starting")
  (send-message! (make-message "pty:create"
                               'id repl-pty-id
                               'command "racket"
                               'args (list)
                               'cols 80
                               'rows 24))
  (cell-set! "repl-status" "ready"))

;; Run a file: load definitions into the REPL namespace
(define (run-file path)
  (cell-set! "repl-status" "running")
  ;; Send ,enter command to switch namespace to file
  (define cmd (string-append ",enter \"" path "\"\n"))
  (send-message! (make-message "pty:write"
                               'id repl-pty-id
                               'data cmd))
  (cell-set! "repl-status" "ready"))

;; Handle REPL-related events
(define (handle-repl-event msg)
  (define name (message-ref msg 'name ""))
  (cond
    [(string=? name "pty:exit")
     (cell-set! "repl-status" "exited")]
    [else (void)]))
```

**Step 3: Write tests**

Add to `test/test-bridge.rkt` (or create `test/test-editor.rkt`):

```racket
;; Test detect-language
(check-equal? (detect-language "/foo/bar.rkt") "racket")
(check-equal? (detect-language "/foo/bar.txt") "plaintext")

;; Test path->filename
(check-equal? (path->filename "/Users/foo/bar.rkt") "bar.rkt")
(check-equal? (path->filename "bar.rkt") "bar.rkt")
```

Run: `cd racket/mrracket-core && raco test ../../test/test-editor.rkt`

**Step 4: Commit**

```bash
git add racket/mrracket-core/editor.rkt racket/mrracket-core/repl.rkt test/
git commit -m "feat: add Racket editor and REPL modules"
```

---

## Task 10: Update Racket main.rkt

**Files:**
- Modify: `racket/mrracket-core/main.rkt`

**Step 1: Rewrite main.rkt with new layout and handlers**

The existing main.rkt has a demo counter layout. Replace it with the IDE layout:

```racket
#lang racket/base

(require "protocol.rkt"
         "cell.rkt"
         "editor.rkt"
         "repl.rkt")

;; ─── Cells ──────────────────────────────────

(define-cell "current-file" "untitled.rkt")
(define-cell "file-dirty" #f)
(define-cell "repl-status" "starting")

;; ─── Layout ─────────────────────────────────

(define layout
  (hasheq 'type "vbox"
          'props (hasheq 'flex "1")
          'children
          (list
           ;; Toolbar
           (hasheq 'type "toolbar"
                   'props (hasheq)
                   'children
                   (list
                    (hasheq 'type "button"
                            'props (hasheq 'label "Run"
                                           'onClick "run"
                                           'variant "primary")
                            'children (list))
                    (hasheq 'type "text"
                            'props (hasheq 'text "cell:current-file"
                                           'style "mono")
                            'children (list))))
           ;; Split: editor + terminal
           (hasheq 'type "split"
                   'props (hasheq 'direction "vertical"
                                  'ratio 0.6)
                   'children
                   (list
                    (hasheq 'type "editor"
                            'props (hasheq 'file-path ""
                                           'language "racket")
                            'children (list))
                    (hasheq 'type "terminal"
                            'props (hasheq 'pty-id "repl")
                            'children (list)))))))

;; ─── Menu ───────────────────────────────────

(define menu
  (list
   (hasheq 'label "File"
           'children
           (list
            (hasheq 'label "New" 'action "new-file" 'shortcut "Cmd+N")
            (hasheq 'label "Open..." 'action "open-file" 'shortcut "Cmd+O")
            (hasheq 'label "Save" 'action "save-file" 'shortcut "Cmd+S")
            (hasheq 'type "separator")
            (hasheq 'label "Quit" 'action "quit" 'shortcut "Cmd+Q")))
   (hasheq 'label "Racket"
           'children
           (list
            (hasheq 'label "Run" 'action "run" 'shortcut "Cmd+R")))))

;; ─── Event Dispatch ─────────────────────────

(define (dispatch msg)
  (define type (message-type msg))
  (cond
    ;; Frontend events (button clicks, etc.)
    [(string=? type "event")
     (define name (message-ref msg 'name ""))
     (cond
       [(string=? name "run")
        (handle-run)]
       [(or (string=? name "editor:dirty")
            (string=? name "editor:save-request"))
        (handle-editor-event msg)]
       [else (void)])]

    ;; Menu actions
    [(string=? type "menu:action")
     (define action (message-ref msg 'action ""))
     (cond
       [(string=? action "quit") (exit 0)]
       [(string=? action "new-file") (new-file)]
       [(string=? action "open-file") (open-file)]
       [(string=? action "save-file")
        ;; TODO: get content from editor — for now, trigger save via frontend
        (void)]
       [(string=? action "run") (handle-run)]
       [else (void)])]

    ;; File operation results from Rust
    [(or (string=? type "file:read:result")
         (string=? type "file:write:result")
         (string=? type "file:read:error")
         (string=? type "file:write:error")
         (string=? type "file:open-dialog:cancelled")
         (string=? type "file:save-dialog:cancelled"))
     (handle-file-result msg)]

    ;; Frontend ready
    [(string=? type "frontend_ready")
     (void)]

    [else (void)]))

;; ─── Run Handler ────────────────────────────

(define (handle-run)
  (define path (current-file-path))
  (if (string=? path "")
      ;; No file open — nothing to run
      (void)
      (run-file path)))

;; ─── Startup ────────────────────────────────

(register-all-cells!)
(send-message! (make-message "menu:set" 'menu menu))
(send-message! (make-message "layout:set" 'layout layout))

;; Start REPL PTY
(start-repl)

;; Start with a blank file
(new-file)

(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
```

**Step 2: Verify Racket syntax**

Run: `cd racket/mrracket-core && racket -c main.rkt`
Expected: No syntax errors.

**Step 3: Commit**

```bash
git add racket/mrracket-core/main.rkt
git commit -m "feat: update Racket main with IDE layout and event handlers"
```

---

## Task 11: Integration Tests and Verification

**Files:**
- Modify: `test/test-bridge.rkt` (extend with Phase 2 tests)

**Step 1: Add tests for new Racket modules**

Add to test file:

```racket
;; ─── editor.rkt tests ─────────────────────

(require "../racket/mrracket-core/editor.rkt")

;; Test path->filename
(check-equal? (path->filename "/Users/foo/bar.rkt") "bar.rkt")
(check-equal? (path->filename "simple.rkt") "simple.rkt")

;; Test detect-language
(check-equal? (detect-language "test.rkt") "racket")
(check-equal? (detect-language "test.rhm") "racket")
(check-equal? (detect-language "test.js") "plaintext")

;; Test new-file sends correct messages
(let ([output (with-output-to-string
                (λ ()
                  (new-file)))])
  (define msgs (filter (λ (s) (not (string=? s "")))
                       (string-split output "\n")))
  ;; Should emit cell:update for current-file and file-dirty
  ;; and editor:open
  (check-true (> (length msgs) 0)))
```

**Step 2: Run all tests**

Run: `cd /Users/antony/Development/Linkuistics/MrRacket && raco test test/`
Expected: All tests pass.

**Step 3: End-to-end manual verification**

Run: `cargo tauri dev`

Verify:
1. App opens with toolbar (Run button + "untitled.rkt" label)
2. Monaco editor visible in top pane with Racket syntax highlighting
3. xterm.js terminal in bottom pane with Racket prompt (or connecting)
4. Drag handle between editor and terminal works
5. Type `#lang racket` in editor — syntax highlighting appears
6. File → Open → native dialog opens
7. File → New → editor clears
8. Click Run with a valid .rkt file loaded → output appears in terminal
9. No console errors

**Step 4: Commit**

```bash
git add test/
git commit -m "test: add Phase 2 integration tests"
```

---

## Troubleshooting Notes

**Monaco workers not loading:** If Monaco shows a blank editor or errors about workers, check that `monaco-esm` auto-registers workers. If not, manually configure `self.MonacoEnvironment = { getWorkerUrl: () => ... }` before creating the editor.

**xterm.js import errors:** If the vendored xterm ESM doesn't export `Terminal`, check the package's `package.json` for the correct `module` or `exports` field and adjust the import map path.

**PTY not connecting:** Check that `portable-pty` compiles on macOS. It requires system headers. Run `xcode-select --install` if build fails.

**Dialog not showing:** Ensure `dialog:default` permission is in capabilities. Check Tauri console for permission errors.

**Racket PTY `,enter` not working:** The `,enter` command is XREPL-specific. If using plain `racket`, use `(load "file.rkt")` instead. Alternatively, start the PTY with `racket -il xrepl` to enable XREPL commands.
