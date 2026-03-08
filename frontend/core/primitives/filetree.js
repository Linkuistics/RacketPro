// primitives/filetree.js — hm-filetree
//
// Zed-style file tree sidebar. Calls the Rust `list_dir` command
// directly (bypasses Racket, like the PTY) for minimal latency.
// Recursive expand/collapse with indent guidelines. File clicks
// dispatch a `file:tree-open` event to Racket.
//
// Folder expand/collapse uses chevron arrows (▸/▾).
// File icons are selected by extension.

import { LitElement, html, css, nothing, svg } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { dispatch, onMessage } from '../bridge.js';

// ── Chevron icons for folders ───────────────────────────────

const chevronRight = svg`<path d="M5.5 3L10.5 8L5.5 13" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>`;
const chevronDown = svg`<path d="M3 5.5L8 10.5L13 5.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>`;

// ── File-type icon library ──────────────────────────────────
//
// Inline SVGs for common file types, loosely matching the Seti/
// VS Code icon theme colors.  Falls back to a generic file icon.

/** @param {string} color  @param {Function} shape */
function fileIconTemplate(color, shape) {
  return (name) => html`<svg width="18" height="18" viewBox="0 0 16 16" style="color:${color}">${shape}</svg>`;
}

// Generic file icon (gray document)
const genericFileShape = svg`<path d="M4.5 1.5h4.8L13 5.2V13.5a1 1 0 01-1 1h-7a1 1 0 01-1-1v-11a1 1 0 011-1z" fill="currentColor" opacity="0.4"/><path d="M9.3 1.5V5.2H13" fill="currentColor" opacity="0.2"/>`;

// JavaScript — yellow
const jsShape = svg`<rect x="2" y="2" width="12" height="12" rx="1.5" fill="currentColor" opacity="0.15"/><text x="8" y="11.5" text-anchor="middle" fill="currentColor" font-size="8" font-weight="600" font-family="system-ui">JS</text>`;

// TypeScript — blue
const tsShape = svg`<rect x="2" y="2" width="12" height="12" rx="1.5" fill="currentColor" opacity="0.15"/><text x="8" y="11.5" text-anchor="middle" fill="currentColor" font-size="8" font-weight="600" font-family="system-ui">TS</text>`;

// Racket — red/purple parentheses
const rktShape = svg`<text x="8" y="12.5" text-anchor="middle" fill="currentColor" font-size="13" font-weight="700" font-family="system-ui">()</text>`;

// Rust — orange gear-like
const rsShape = svg`<text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="9" font-weight="700" font-family="system-ui">Rs</text>`;

// JSON — yellow braces
const jsonShape = svg`<text x="8" y="12.5" text-anchor="middle" fill="currentColor" font-size="11" font-weight="600" font-family="system-ui">{}</text>`;

// HTML — orange angle brackets
const htmlShape = svg`<text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="9" font-weight="600" font-family="system-ui">&lt;/&gt;</text>`;

// CSS — blue
const cssShape = svg`<text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="8" font-weight="700" font-family="system-ui">#</text>`;

// Markdown — teal
const mdShape = svg`<text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="8" font-weight="700" font-family="system-ui">M↓</text>`;

// TOML/YAML/Config — gray gear
const configShape = svg`<circle cx="8" cy="8" r="5" fill="none" stroke="currentColor" stroke-width="1.2" opacity="0.5"/><circle cx="8" cy="8" r="1.5" fill="currentColor" opacity="0.6"/>`;

// Lock file — gray padlock
const lockShape = svg`<rect x="4.5" y="7" width="7" height="5.5" rx="1" fill="currentColor" opacity="0.35"/><path d="M6 7V5a2 2 0 014 0v2" fill="none" stroke="currentColor" stroke-width="1.2" opacity="0.5"/>`;

// Git file
const gitShape = svg`<circle cx="5.5" cy="5" r="1.5" fill="currentColor" opacity="0.5"/><circle cx="10.5" cy="8" r="1.5" fill="currentColor" opacity="0.5"/><circle cx="5.5" cy="11" r="1.5" fill="currentColor" opacity="0.5"/><path d="M5.5 6.5v3M7 5.3l2 1.7" stroke="currentColor" stroke-width="1" opacity="0.5"/>`;

// Python — blue/yellow
const pyShape = svg`<text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="9" font-weight="700" font-family="system-ui">Py</text>`;

// Image file — purple
const imgShape = svg`<rect x="2" y="2.5" width="12" height="11" rx="1.5" fill="none" stroke="currentColor" stroke-width="1" opacity="0.5"/><circle cx="5.5" cy="5.5" r="1.5" fill="currentColor" opacity="0.4"/><path d="M2 10l3-3 2 2 3-3 4 4" stroke="currentColor" stroke-width="1" fill="none" opacity="0.5"/>`;

// Shell script
const shShape = svg`<text x="8" y="12" text-anchor="middle" fill="currentColor" font-size="8" font-weight="600" font-family="system-ui">$_</text>`;

/** Map of file extensions to {color, shape}. */
const FILE_ICONS = {
  // JavaScript/TypeScript
  'js':    { color: '#CBCB41', shape: jsShape },
  'mjs':   { color: '#CBCB41', shape: jsShape },
  'cjs':   { color: '#CBCB41', shape: jsShape },
  'jsx':   { color: '#61DAFB', shape: jsShape },
  'ts':    { color: '#3178C6', shape: tsShape },
  'tsx':   { color: '#3178C6', shape: tsShape },

  // Racket
  'rkt':   { color: '#9B2335', shape: rktShape },
  'rktl':  { color: '#9B2335', shape: rktShape },
  'scrbl': { color: '#9B2335', shape: rktShape },
  'rhm':   { color: '#9B2335', shape: rktShape },

  // Rust
  'rs':    { color: '#CE422B', shape: rsShape },
  'toml':  { color: '#808080', shape: configShape },

  // Data formats
  'json':  { color: '#CBCB41', shape: jsonShape },
  'jsonc': { color: '#CBCB41', shape: jsonShape },
  'yaml':  { color: '#808080', shape: configShape },
  'yml':   { color: '#808080', shape: configShape },

  // Web
  'html':  { color: '#E44D26', shape: htmlShape },
  'htm':   { color: '#E44D26', shape: htmlShape },
  'css':   { color: '#563D7C', shape: cssShape },
  'scss':  { color: '#CC6699', shape: cssShape },
  'less':  { color: '#1D365D', shape: cssShape },
  'svg':   { color: '#FFB13B', shape: imgShape },

  // Docs
  'md':    { color: '#519ABA', shape: mdShape },
  'txt':   { color: '#808080', shape: genericFileShape },

  // Python
  'py':    { color: '#3572A5', shape: pyShape },

  // Shell
  'sh':    { color: '#89E051', shape: shShape },
  'bash':  { color: '#89E051', shape: shShape },
  'zsh':   { color: '#89E051', shape: shShape },

  // Images
  'png':   { color: '#A074C4', shape: imgShape },
  'jpg':   { color: '#A074C4', shape: imgShape },
  'jpeg':  { color: '#A074C4', shape: imgShape },
  'gif':   { color: '#A074C4', shape: imgShape },
  'ico':   { color: '#A074C4', shape: imgShape },
  'webp':  { color: '#A074C4', shape: imgShape },

  // Lock files
  'lock':  { color: '#808080', shape: lockShape },
};

/** Special filename matches (exact name). */
const FILENAME_ICONS = {
  '.gitignore':     { color: '#F14E32', shape: gitShape },
  '.gitmodules':    { color: '#F14E32', shape: gitShape },
  '.gitattributes': { color: '#F14E32', shape: gitShape },
  'Cargo.toml':     { color: '#CE422B', shape: rsShape },
  'Cargo.lock':     { color: '#808080', shape: lockShape },
  'package.json':   { color: '#CBCB41', shape: jsonShape },
  'package-lock.json': { color: '#808080', shape: lockShape },
  'tsconfig.json':  { color: '#3178C6', shape: configShape },
  'Makefile':       { color: '#427819', shape: configShape },
  'Dockerfile':     { color: '#2496ED', shape: configShape },
  'LICENSE':        { color: '#808080', shape: genericFileShape },
  'README.md':      { color: '#519ABA', shape: mdShape },
  'info.rkt':       { color: '#9B2335', shape: configShape },
};

/**
 * Get the file icon for a given filename.
 * Returns an html TemplateResult for the SVG icon.
 */
function getFileIcon(name, ext) {
  // Check exact filename first
  const byName = FILENAME_ICONS[name];
  if (byName) {
    return html`<svg width="18" height="18" viewBox="0 0 16 16" style="color:${byName.color}">${byName.shape}</svg>`;
  }

  // Check extension
  const byExt = FILE_ICONS[ext];
  if (byExt) {
    return html`<svg width="18" height="18" viewBox="0 0 16 16" style="color:${byExt.color}">${byExt.shape}</svg>`;
  }

  // Generic file icon
  return html`<svg width="18" height="18" viewBox="0 0 16 16" style="color:#808080">${genericFileShape}</svg>`;
}

/** Extract the last segment of a path for the project name. */
function projectName(path) {
  const parts = path.replace(/\/+$/, '').split(/[/\\]/);
  return parts[parts.length - 1] || path;
}

class HmFiletree extends LitElement {
  static properties = {
    rootPath: { type: String, attribute: 'root-path' },
  };

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      min-width: 140px;
      background: var(--bg-sidebar, #F8F8F8);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: var(--ui-fs-lg);
      color: var(--fg-sidebar, #333333);
      overflow-y: auto;
      overflow-x: hidden;
      box-sizing: border-box;
      user-select: none;
    }

    .tree {
      flex: 1;
      overflow-y: auto;
      padding: 4px 0;
    }

    .item {
      display: flex;
      align-items: center;
      height: var(--sidebar-item-h, 26px);
      padding-right: 8px;
      cursor: pointer;
      white-space: nowrap;
      position: relative;
    }

    .item:hover {
      background: var(--bg-sidebar-hover, #E8E8E8);
    }

    .item.active {
      background: var(--bg-sidebar-active, #D6EBFF);
    }

    .chevron {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 18px;
      height: 18px;
      flex-shrink: 0;
      margin-right: 2px;
      position: relative;
      top: 1px;
      color: var(--fg-muted, #999999);
    }

    .icon {
      display: flex;
      align-items: center;
      margin-right: 7px;
      flex-shrink: 0;
    }

    .name {
      overflow: hidden;
      text-overflow: ellipsis;
    }

    /* Vertical indent guidelines */
    .guide {
      position: absolute;
      top: 0;
      bottom: 0;
      width: 1px;
      background: var(--border, #D4D4D4);
    }

    .loading {
      padding: 12px;
      color: var(--fg-muted, #999999);
      font-size: var(--ui-fs-md);
    }
  `;

  constructor() {
    super();
    this.rootPath = '';
    /** @type {Map<string, object[]>} Cached dir listings keyed by path. */
    this._cache = new Map();
    /** @type {Set<string>} Expanded directory paths. */
    this._expanded = new Set();
    /** @type {string|null} Currently active (clicked) file. */
    this._activeFile = null;
    this._disposeEffect = null;
    this._disposeActiveSync = null;
    this._unsubWriteResult = null;
    this._resolvedRoot = '';
    this._rootExpanded = true;
  }

  firstUpdated() {
    setTimeout(() => this._resolveRootPath(), 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) {
      this._disposeEffect();
      this._disposeEffect = null;
    }
    if (this._disposeActiveSync) {
      this._disposeActiveSync();
      this._disposeActiveSync = null;
    }
    if (this._unsubWriteResult) {
      this._unsubWriteResult();
      this._unsubWriteResult = null;
    }
  }

  _resolveRootPath() {
    if (typeof this.rootPath === 'string' && this.rootPath.startsWith('cell:')) {
      const cellName = this.rootPath.slice(5);
      getCell(cellName);
      this._disposeEffect = effect(() => {
        const val = getCell(cellName).value;
        if (val && val !== this._resolvedRoot) {
          this._resolvedRoot = val;
          this._cache.clear();
          this._expanded.clear();
          this._rootExpanded = true;
          this._loadDir(val);
        }
      });
    } else if (this.rootPath) {
      this._resolvedRoot = this.rootPath;
      this._loadDir(this.rootPath);
    }

    // Sync active file with current-file cell
    const currentFileCell = getCell('current-file');
    this._disposeActiveSync = effect(() => {
      const filePath = currentFileCell.value;
      if (filePath && filePath !== this._activeFile) {
        this._activeFile = filePath;
        this._autoReveal(filePath);
        this.requestUpdate();
        // Scroll into view after render
        this.updateComplete.then(() => {
          const active = this.shadowRoot.querySelector('.item.active');
          if (active) active.scrollIntoView({ block: 'nearest' });
        });
      }
    });

    // Invalidate cache when a file is written (e.g. save-as creates a new file)
    this._unsubWriteResult = onMessage('file:write:result', (msg) => {
      const filePath = msg.path;
      if (!filePath) return;
      const lastSlash = filePath.lastIndexOf('/');
      if (lastSlash < 0) return;
      const parentDir = filePath.substring(0, lastSlash);
      this._cache.delete(parentDir);
      if (this._expanded.has(parentDir) || parentDir === this._resolvedRoot) {
        this._loadDir(parentDir);
      }
      this.requestUpdate();
    });
  }

  async _loadDir(path) {
    if (this._cache.has(path)) return;
    try {
      const entries = await window.__TAURI__.core.invoke('list_dir', {
        path,
        showHidden: false,
      });
      this._cache.set(path, entries);
      this.requestUpdate();
    } catch (err) {
      console.error('[hm-filetree] list_dir failed:', err);
    }
  }

  _toggleRoot() {
    this._rootExpanded = !this._rootExpanded;
    this.requestUpdate();
  }

  _toggleDir(dirPath) {
    if (this._expanded.has(dirPath)) {
      this._expanded.delete(dirPath);
    } else {
      this._expanded.add(dirPath);
      this._loadDir(dirPath);
    }
    this.requestUpdate();
  }

  _clickFile(filePath) {
    this._activeFile = filePath;
    this.requestUpdate();
    dispatch('file:tree-open', { path: filePath });
  }

  /**
   * Expand all ancestor directories of the given file path.
   * Computes parent paths relative to the resolved root and adds
   * them to _expanded, triggering lazy loads as needed.
   */
  _autoReveal(filePath) {
    if (!this._resolvedRoot || !filePath.startsWith(this._resolvedRoot)) return;

    const rel = filePath.slice(this._resolvedRoot.length);
    const segments = rel.split('/').filter(Boolean);

    // Build up ancestor paths and expand each
    let current = this._resolvedRoot;
    for (let i = 0; i < segments.length - 1; i++) {
      current = current + '/' + segments[i];
      if (!this._expanded.has(current)) {
        this._expanded.add(current);
        this._loadDir(current);
      }
    }

    // Ensure root is expanded
    this._rootExpanded = true;
  }

  /**
   * Render indent guidelines. Each ancestor depth gets a vertical line.
   * @param {number} depth — nesting depth (0 = root children)
   * @param {number} baseIndent — the px offset for depth 0
   * @param {number} step — px per indent level
   */
  _renderGuides(depth, baseIndent, step) {
    const guides = [];
    for (let d = 0; d < depth; d++) {
      const left = baseIndent + d * step + 7;
      guides.push(html`<span class="guide" style="left:${left}px"></span>`);
    }
    return guides;
  }

  _renderChevron(isExpanded) {
    return html`<span class="chevron">
      <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
        ${isExpanded ? chevronDown : chevronRight}
      </svg>
    </span>`;
  }

  _renderEntries(parentPath, depth = 0) {
    const entries = this._cache.get(parentPath);
    if (!entries) return nothing;

    // Chevron of child aligns under the name of its parent folder.
    // Root: padding-left 8px + chevron 20px (18+2mr) = name at 28px.
    // Depth 0 children start chevron at 28px (under root name).
    // Each deeper level adds 20px (chevron width + margin).
    const baseIndent = 28;
    const step = 20;
    const indent = baseIndent + depth * step;

    return entries.map(entry => {
      const fullPath = `${parentPath}/${entry.name}`;

      if (entry.kind === 'dir') {
        const isExpanded = this._expanded.has(fullPath);
        return html`
          <div class="item" style="padding-left:${indent}px" @click=${() => this._toggleDir(fullPath)}>
            ${this._renderGuides(depth, baseIndent, step)}
            ${this._renderChevron(isExpanded)}
            <span class="name">${entry.name}</span>
          </div>
          ${isExpanded ? this._renderEntries(fullPath, depth + 1) : nothing}
        `;
      }

      return html`
        <div
          class="item ${fullPath === this._activeFile ? 'active' : ''}"
          style="padding-left:${indent}px"
          @click=${() => this._clickFile(fullPath)}
        >
          ${this._renderGuides(depth, baseIndent, step)}
          <span class="icon">${getFileIcon(entry.name, entry.ext || '')}</span>
          <span class="name">${entry.name}</span>
        </div>
      `;
    });
  }

  render() {
    if (!this._resolvedRoot) {
      return html`<div class="loading">No project open</div>`;
    }

    return html`
      <div class="tree">
        <div class="item" style="padding-left:8px" @click=${() => this._toggleRoot()}>
          ${this._renderChevron(this._rootExpanded)}
          <span class="name">${projectName(this._resolvedRoot)}</span>
        </div>
        ${this._rootExpanded ? this._renderEntries(this._resolvedRoot) : nothing}
      </div>
    `;
  }
}

customElements.define('hm-filetree', HmFiletree);
