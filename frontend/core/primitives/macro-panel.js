// primitives/macro-panel.js — hm-macro-panel
//
// Displays a macro expansion tree with a detail view.
// Left pane: collapsible tree of macro applications.
// Right pane: before/after forms in read-only Monaco editors.

import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';

class HmMacroPanel extends LitElement {
  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      flex: 1;
      overflow: hidden;
      background: var(--bg-primary, #FFFFFF);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 13px;
    }

    .toolbar {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: var(--bg-toolbar, #F8F8F8);
      border-bottom: 1px solid var(--border, #D4D4D4);
      min-height: 28px;
      flex-shrink: 0;
    }

    .toolbar button {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 3px 8px;
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 3px;
      background: var(--bg-primary, #FFFFFF);
      color: var(--fg-primary, #333333);
      cursor: pointer;
      font-size: 12px;
      font-family: inherit;
    }

    .toolbar button:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .content {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

    .tree-pane {
      width: 40%;
      min-width: 200px;
      overflow: auto;
      border-right: 1px solid var(--border, #D4D4D4);
      padding: 8px;
    }

    .detail-pane {
      flex: 1;
      overflow: auto;
      padding: 8px 12px;
    }

    .tree-node {
      padding: 2px 0;
    }

    .tree-label {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 2px 4px;
      border-radius: 3px;
      cursor: pointer;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 12px;
      font-weight: var(--font-editor-weight, 300);
    }

    .tree-label:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .tree-label.selected {
      background: var(--accent-bg, #E3F2FD);
      color: var(--accent, #007ACC);
    }

    .tree-children {
      padding-left: 16px;
    }

    .toggle {
      width: 12px;
      text-align: center;
      color: var(--fg-muted, #999999);
      flex-shrink: 0;
    }

    .macro-name {
      color: var(--accent, #007ACC);
      font-weight: 500;
    }

    .arrow {
      color: var(--fg-muted, #999999);
    }

    .detail-section {
      margin-bottom: 12px;
    }

    .detail-label {
      font-size: 11px;
      font-weight: 600;
      color: var(--fg-muted, #999999);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 4px;
    }

    .code-block {
      padding: 8px;
      background: var(--bg-panel, #F5F5F5);
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 4px;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 12px;
      font-weight: var(--font-editor-weight, 300);
      white-space: pre-wrap;
      word-break: break-word;
      overflow: auto;
      max-height: 200px;
    }

    .info-row {
      display: flex;
      gap: 8px;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      margin-top: 8px;
    }

    .info-label {
      color: var(--fg-muted, #999999);
    }

    .empty {
      color: var(--fg-muted, #999999);
      font-style: italic;
      padding: 20px;
      text-align: center;
    }

    .pattern-placeholder {
      padding: 8px;
      background: #FFFDE7;
      border: 1px solid #FBC02D;
      border-radius: 4px;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      font-style: italic;
    }
  `;

  constructor() {
    super();
    this._forms = [];
    this._selectedNode = null;
    this._expandedNodes = new Set();
    this._unsubs = [];
    this._error = null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage('macro:tree', (msg) => {
          this._forms = msg.forms || [];
          this._selectedNode = null;
          this._error = null;
          // Auto-expand first level
          for (const f of this._forms) {
            if (f.macro) this._expandedNodes.add(f.id);
          }
          this.requestUpdate();
        }),
        onMessage('macro:error', (msg) => {
          this._error = msg.error || 'Unknown error';
          this._forms = [];
          this._selectedNode = null;
          this.requestUpdate();
        }),
        onMessage('macro:clear', () => {
          this._forms = [];
          this._selectedNode = null;
          this._error = null;
          this._expandedNodes.clear();
          this.requestUpdate();
        })
      );
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const u of this._unsubs) u();
  }

  _toggleNode(id) {
    if (this._expandedNodes.has(id)) {
      this._expandedNodes.delete(id);
    } else {
      this._expandedNodes.add(id);
    }
    this.requestUpdate();
  }

  _selectNode(node) {
    this._selectedNode = node;
    this.requestUpdate();
  }

  _collapseAll() {
    this._expandedNodes.clear();
    this.requestUpdate();
  }

  _expandAll() {
    const walk = (nodes) => {
      for (const n of nodes) {
        if (n.children && n.children.length > 0) {
          this._expandedNodes.add(n.id);
          walk(n.children);
        }
      }
    };
    walk(this._forms);
    this.requestUpdate();
  }

  _renderNode(node) {
    if (!node.macro && (!node.children || node.children.length === 0)) {
      return html``; // Skip leaf nodes with no macro
    }

    const hasChildren = node.children && node.children.length > 0;
    const isExpanded = this._expandedNodes.has(node.id);
    const isSelected = this._selectedNode?.id === node.id;

    // Truncate before string for tree display
    const summary = node.before?.length > 40
      ? node.before.substring(0, 40) + '...'
      : node.before || '';

    return html`
      <div class="tree-node">
        <div class="tree-label ${isSelected ? 'selected' : ''}"
             @click=${() => this._selectNode(node)}>
          ${hasChildren
            ? html`<span class="toggle" @click=${(e) => { e.stopPropagation(); this._toggleNode(node.id); }}>
                ${isExpanded ? '\u25BC' : '\u25B6'}
              </span>`
            : html`<span class="toggle"></span>`}
          ${node.macro
            ? html`<span class="macro-name">${node.macro}</span>
                   <span class="arrow">\u2192</span>`
            : ''}
          <span>${summary}</span>
        </div>
        ${hasChildren && isExpanded ? html`
          <div class="tree-children">
            ${node.children.map(c => this._renderNode(c))}
          </div>
        ` : ''}
      </div>
    `;
  }

  _renderDetail() {
    const node = this._selectedNode;
    if (!node) {
      return html`<div class="empty">Select a node in the expansion tree</div>`;
    }

    return html`
      ${node.macro ? html`
        <div class="info-row">
          <span class="info-label">Macro:</span>
          <span class="macro-name">${node.macro}</span>
        </div>
      ` : ''}

      <div class="detail-section">
        <div class="detail-label">Before</div>
        <div class="code-block">${node.before || '(empty)'}</div>
      </div>

      ${node.after ? html`
        <div class="detail-section">
          <div class="detail-label">After</div>
          <div class="code-block">${node.after}</div>
        </div>
      ` : ''}

      <div class="detail-section">
        <div class="detail-label">Pattern Match</div>
        <div class="pattern-placeholder">
          Pattern match highlighting not yet available.
          Will show SyntaxSpec pattern matches in a future update.
        </div>
      </div>
    `;
  }

  render() {
    if (this._error) {
      return html`
        <div class="toolbar">
          <button @click=${() => dispatch('macro:stop')}>Clear</button>
        </div>
        <div class="empty">Error: ${this._error}</div>
      `;
    }

    if (this._forms.length === 0) {
      return html`
        <div class="toolbar">
          <span style="color: var(--fg-muted, #999); font-size: 12px;">
            Use Expand Macros (Cmd+Shift+E) to view macro expansions
          </span>
        </div>
        <div class="empty">No expansion data. Open a Racket file and click Expand Macros.</div>
      `;
    }

    return html`
      <div class="toolbar">
        <button @click=${() => this._expandAll()}>Expand All</button>
        <button @click=${() => this._collapseAll()}>Collapse All</button>
        <button @click=${() => dispatch('macro:stop')}>Clear</button>
      </div>
      <div class="content">
        <div class="tree-pane">
          ${this._forms.map(f => this._renderNode(f))}
        </div>
        <div class="detail-pane">
          ${this._renderDetail()}
        </div>
      </div>
    `;
  }
}

customElements.define('hm-macro-panel', HmMacroPanel);
