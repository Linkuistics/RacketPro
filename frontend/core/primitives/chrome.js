// primitives/chrome.js — hm-toolbar, hm-breadcrumb, hm-statusbar
//
// Chrome components for the IDE shell.  hm-toolbar is a horizontal
// container for action buttons; hm-breadcrumb shows the active file's
// path below the tab bar with action buttons on the right;
// hm-statusbar shows status text at the bottom of the window.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell, resolveValue } from '../cells.js';
import { dispatch } from '../bridge.js';

// ── hm-toolbar ─────────────────────────────────────────────

class HmToolbar extends LitElement {
  static styles = css`
    :host {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 8px;
      background: var(--bg-toolbar, #F8F8F8);
      border-bottom: 1px solid var(--border, #E5E5E5);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      flex-shrink: 0;
      min-height: 36px;
    }
  `;

  render() {
    return html`<slot></slot>`;
  }
}

customElements.define('hm-toolbar', HmToolbar);

// ── hm-breadcrumb ─────────────────────────────────────────

class HmBreadcrumb extends LitElement {
  static properties = {
    file:    { type: String },
    root:    { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 1px 10px;
      height: 30px;
      min-height: 30px;
      background: var(--bg-primary, #FFFFFF);
      border-bottom: 1px solid var(--border, #D4D4D4);
      font-family: var(--font-editor, "OperatorMonoSSm Nerd Font Mono", "SF Mono", Menlo, monospace);
      font-size: 13px;
      font-weight: var(--font-editor-weight, 300);
      color: var(--fg-secondary, #616161);
      flex-shrink: 0;
      box-sizing: border-box;
      overflow: hidden;
      white-space: nowrap;
    }

    .path {
      display: flex;
      align-items: center;
      overflow: hidden;
      min-width: 0;
    }

    .actions {
      display: flex;
      align-items: center;
      gap: 4px;
      flex-shrink: 0;
      margin-left: 12px;
    }

    .action-btn {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 22px;
      height: 22px;
      border-radius: 3px;
      cursor: pointer;
      color: var(--fg-muted, #999999);
    }

    .action-btn:hover {
      background: rgba(0, 0, 0, 0.06);
      color: var(--fg-secondary, #616161);
    }

    .action-btn.run:hover {
      background: rgba(0, 122, 204, 0.1);
      color: var(--accent, #007ACC);
    }

    .action-btn.stop:hover {
      background: rgba(204, 0, 0, 0.1);
      color: #CC0000;
    }

    .action-btn.step:hover {
      background: rgba(156, 39, 176, 0.1);
      color: #9C27B0;
    }

    :host([hidden]) {
      display: none;
    }
  `;

  constructor() {
    super();
    this.file = '';
    this.root = '';
    this._disposeEffect = null;
  }

  firstUpdated() {
    setTimeout(() => this._setupEffect(), 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) {
      this._disposeEffect();
      this._disposeEffect = null;
    }
  }

  _setupEffect() {
    const cellNames = [];
    if (this.file?.startsWith('cell:')) cellNames.push(this.file.slice(5));
    if (this.root?.startsWith('cell:')) cellNames.push(this.root.slice(5));
    cellNames.push('repl-running');
    cellNames.push('stepper-active');

    for (const name of cellNames) getCell(name);
    this._disposeEffect = effect(() => {
      for (const name of cellNames) getCell(name).value;
      this.requestUpdate();
    });
  }

  _dispatch(action) {
    dispatch(action);
  }

  updated() {
    const filePath = resolveValue(this.file) || '';
    this.toggleAttribute('hidden', !filePath);
  }

  render() {
    const filePath = resolveValue(this.file) || '';
    const rootPath = resolveValue(this.root) || '';

    // Make path relative to project root
    let relPath = filePath;
    if (rootPath && filePath.startsWith(rootPath)) {
      relPath = filePath.slice(rootPath.length);
      if (relPath.startsWith('/')) relPath = relPath.slice(1);
    }

    const segments = relPath ? relPath.split(/[/\\]/).filter(Boolean) : [];

    const isRunning = resolveValue('cell:repl-running') || false;
    const isStepping = resolveValue('cell:stepper-active') || false;

    return html`
      <div class="path">
        ${segments.length > 0
          ? relPath
          : filePath || ''}
      </div>
      <div class="actions">
        ${isRunning
          ? html`<span class="action-btn stop" title="Stop (restart REPL)" @click=${() => this._dispatch('repl:restart')}>
              <svg width="14" height="14" viewBox="0 0 16 16"><rect x="3" y="3" width="10" height="10" rx="1" fill="currentColor"/></svg>
            </span>`
          : html`<span class="action-btn run" title="Run (Cmd+R)" @click=${() => this._dispatch('run')}>
              <svg width="14" height="14" viewBox="0 0 16 16"><path d="M4 2l10 6-10 6z" fill="currentColor"/></svg>
            </span>`
        }
        ${!isStepping && !isRunning
          ? html`<span class="action-btn step" title="Step Through (Cmd+Shift+R)" @click=${() => dispatch('stepper:start', { path: filePath })}>
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                <path d="M4 2l6 4-6 4z" fill="currentColor" opacity="0.6"/>
                <line x1="12" y1="2" x2="12" y2="14" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
              </svg>
            </span>`
          : ''}
        ${!isStepping && !isRunning
          ? html`<span class="action-btn expand" title="Expand Macros (Cmd+Shift+E)" @click=${() => dispatch('macro:expand', { path: filePath })}>
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                <path d="M2 4h12M2 8h8M2 12h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                <circle cx="13" cy="10" r="2.5" stroke="currentColor" stroke-width="1.2" fill="none"/>
              </svg>
            </span>`
          : ''}
      </div>
    `;
  }
}

customElements.define('hm-breadcrumb', HmBreadcrumb);

// ── hm-statusbar ───────────────────────────────────────────

class HmStatusbar extends LitElement {
  static properties = {
    content:  { type: String },
    language: { type: String },
    position: { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 3px 17px 5px;
      background: var(--bg-statusbar, #E8E8E8);
      border-top: 1px solid var(--border, #D4D4D4);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 14px;
      color: var(--fg-statusbar, #616161);
      flex-shrink: 0;
      min-height: var(--statusbar-h, 28px);
      box-sizing: border-box;
    }

    .left {
      display: flex;
      align-items: center;
      gap: 4px;
      overflow: hidden;
      white-space: nowrap;
    }

    .sidebar-icons {
      display: flex;
      align-items: center;
      gap: 2px;
      margin-right: 8px;
      padding-right: 8px;
      border-right: 1px solid var(--border, #D4D4D4);
    }

    .sb-icon {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 20px;
      height: 20px;
      border-radius: 3px;
      cursor: pointer;
      color: var(--fg-muted, #999999);
    }

    .sb-icon:hover {
      background: rgba(0, 0, 0, 0.06);
      color: var(--fg-secondary, #616161);
    }

    .sb-icon.active {
      color: var(--accent, #007ACC);
    }

    .status-text {
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .right {
      display: flex;
      align-items: center;
      gap: 16px;
      flex-shrink: 0;
    }
  `;

  constructor() {
    super();
    this.content = '';
    this.language = '';
    this.position = '';
    this._disposeEffect = null;
  }

  connectedCallback() {
    super.connectedCallback();
    this._setupCellEffect();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this._teardownEffect();
  }

  updated(changed) {
    if (changed.has('content') || changed.has('language') || changed.has('position')) {
      this._teardownEffect();
      this._setupCellEffect();
    }
  }

  _setupCellEffect() {
    const cellProps = [this.content, this.language, this.position];
    const cellNames = cellProps
      .filter(v => typeof v === 'string' && v.startsWith('cell:'))
      .map(v => v.slice(5));

    if (cellNames.length === 0) return;
    for (const name of cellNames) getCell(name);

    this._disposeEffect = effect(() => {
      for (const name of cellNames) getCell(name).value;
      this.requestUpdate();
    });
  }

  _teardownEffect() {
    if (this._disposeEffect) {
      this._disposeEffect();
      this._disposeEffect = null;
    }
  }

  /** Convert "Ln 3, Col 12" → "3:12" */
  _formatPosition(raw) {
    if (!raw) return '';
    const m = raw.match(/Ln\s*(\d+),?\s*Col\s*(\d+)/i);
    return m ? `${m[1]}:${m[2]}` : raw;
  }

  render() {
    const statusText = resolveValue(this.content) || '';
    const langText = resolveValue(this.language) || '';
    const posText = resolveValue(this.position) || '';
    const posFormatted = this._formatPosition(posText);
    const langFormatted = langText.toLowerCase();

    return html`
      <div class="left">
        <div class="sidebar-icons">
          <span class="sb-icon active" title="File Tree">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M1 2h14M1 6h10M1 10h12M1 14h8" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>
          </span>
          <span class="sb-icon" title="Search">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="7" cy="7" r="4.5" stroke="currentColor" stroke-width="1.3"/><path d="M10.5 10.5L14 14" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>
          </span>
          <span class="sb-icon" title="Source Control">
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="5" cy="4" r="2" stroke="currentColor" stroke-width="1.2"/><circle cx="11" cy="8" r="2" stroke="currentColor" stroke-width="1.2"/><circle cx="5" cy="12" r="2" stroke="currentColor" stroke-width="1.2"/><path d="M5 6v4M7 4.5l2.5 2" stroke="currentColor" stroke-width="1.2"/></svg>
          </span>
        </div>
        <span class="status-text">${statusText}</span>
      </div>
      <div class="right">
        ${posFormatted ? html`<span>${posFormatted}</span>` : ''}
        ${langFormatted ? html`<span>${langFormatted}</span>` : ''}
      </div>
    `;
  }
}

customElements.define('hm-statusbar', HmStatusbar);
