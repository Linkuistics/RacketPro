// primitives/macro-panel.js — hm-macro-panel
//
// Displays macro expansion data with two views:
// - Stepper: flat list of expansion steps with prev/next navigation
// - Tree: hierarchical view of macro applications
// Right pane: before/after with foci highlighting, pattern section.

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
      font-size: var(--ui-fs);
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
      font-size: var(--ui-fs-md);
      font-family: inherit;
    }

    .toolbar button:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .toolbar button.active {
      background: var(--accent-bg, #E3F2FD);
      border-color: var(--accent, #007ACC);
      color: var(--accent, #007ACC);
    }

    .toolbar button:disabled {
      opacity: 0.4;
      cursor: default;
    }

    .toolbar .separator {
      width: 1px;
      height: 16px;
      background: var(--border, #D4D4D4);
    }

    .step-counter {
      font-size: var(--ui-fs-md);
      color: var(--fg-secondary, #616161);
      margin-left: auto;
    }

    .content {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

    /* ── Stepper view (left pane) ── */

    .step-list {
      width: 40%;
      min-width: 200px;
      overflow: auto;
      border-right: 1px solid var(--border, #D4D4D4);
    }

    .step-item {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      cursor: pointer;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: var(--ui-fs-md);
      font-weight: var(--font-editor-weight, 300);
      border-bottom: 1px solid var(--border-light, #EEEEEE);
    }

    .step-item:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .step-item.selected {
      background: var(--accent-bg, #E3F2FD);
      color: var(--accent, #007ACC);
    }

    .step-num {
      color: var(--fg-muted, #999999);
      font-size: var(--ui-fs-sm);
      min-width: 24px;
    }

    .step-type {
      font-size: var(--ui-fs-xs);
      padding: 1px 4px;
      border-radius: 2px;
      background: var(--bg-panel, #F5F5F5);
      color: var(--fg-muted, #999999);
    }

    .step-type.macro {
      background: #E3F2FD;
      color: #1565C0;
    }

    .step-macro {
      color: var(--accent, #007ACC);
      font-weight: 500;
    }

    /* ── Tree view (left pane) ── */

    .tree-pane {
      width: 40%;
      min-width: 200px;
      overflow: auto;
      border-right: 1px solid var(--border, #D4D4D4);
      padding: 8px;
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
      font-size: var(--ui-fs-md);
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

    .arrow {
      color: var(--fg-muted, #999999);
    }

    /* ── Detail pane (right) ── */

    .detail-pane {
      flex: 1;
      overflow: auto;
      padding: 8px 12px;
    }

    .detail-section {
      margin-bottom: 12px;
    }

    .detail-label {
      font-size: var(--ui-fs-sm);
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
      font-size: var(--ui-fs-md);
      font-weight: var(--font-editor-weight, 300);
      white-space: pre-wrap;
      word-break: break-word;
      overflow: auto;
      max-height: 200px;
    }

    .info-row {
      display: flex;
      gap: 8px;
      font-size: var(--ui-fs-md);
      color: var(--fg-secondary, #616161);
      margin-bottom: 8px;
    }

    .info-label {
      color: var(--fg-muted, #999999);
    }

    .macro-name {
      color: var(--accent, #007ACC);
      font-weight: 500;
    }

    .empty {
      color: var(--fg-muted, #999999);
      font-style: italic;
      padding: 20px;
      text-align: center;
    }

    .focus-highlight {
      background: #FFF9C4;
      border-radius: 2px;
      padding: 0 1px;
    }

    .focus-after-highlight {
      background: #C8E6C9;
      border-radius: 2px;
      padding: 0 1px;
    }

    .filter-select {
      font-size: var(--ui-fs-md);
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 3px;
      padding: 2px 4px;
      background: var(--bg-primary, #FFFFFF);
      font-family: inherit;
    }

    .pattern-section {
      padding: 8px;
      background: #E8F5E9;
      border: 1px solid #A5D6A7;
      border-radius: 4px;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: var(--ui-fs-md);
    }

    .pattern-source {
      font-size: var(--ui-fs-sm);
      color: var(--fg-muted, #999999);
      margin-top: 4px;
    }
  `;

  constructor() {
    super();
    // Stepper state
    this._steps = [];
    this._currentIndex = -1;
    this._filter = 'all'; // 'all' | 'macro'

    // Tree state
    this._treeNodes = [];
    this._expandedNodes = new Set();
    this._selectedTreeNode = null;

    // View toggle
    this._view = 'stepper'; // 'stepper' | 'tree'

    // Shared state
    this._unsubs = [];
    this._error = null;
    this._patterns = new Map(); // stepId -> pattern data
  }

  get _filteredSteps() {
    if (this._filter === 'macro') {
      return this._steps.filter(s => s.type === 'macro');
    }
    return this._steps;
  }

  get _currentStep() {
    const steps = this._filteredSteps;
    if (this._currentIndex >= 0 && this._currentIndex < steps.length) {
      return steps[this._currentIndex];
    }
    return null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage('macro:steps', (msg) => {
          this._steps = msg.steps || [];
          this._currentIndex = this._steps.length > 0 ? 0 : -1;
          this._error = null;
          this._patterns.clear();
          this.requestUpdate();
        }),
        onMessage('macro:tree', (msg) => {
          this._treeNodes = msg.forms || [];
          this._selectedTreeNode = null;
          // Auto-expand first level
          for (const f of this._treeNodes) {
            if (f.children && f.children.length > 0) {
              this._expandedNodes.add(f.id);
            }
          }
          this.requestUpdate();
        }),
        onMessage('macro:pattern', (msg) => {
          if (msg.stepId) {
            this._patterns.set(msg.stepId, msg);
          }
          this.requestUpdate();
        }),
        onMessage('macro:error', (msg) => {
          this._error = msg.error || 'Unknown error';
          this._steps = [];
          this._treeNodes = [];
          this._currentIndex = -1;
          this._selectedTreeNode = null;
          this.requestUpdate();
        }),
        onMessage('macro:clear', () => {
          this._steps = [];
          this._treeNodes = [];
          this._currentIndex = -1;
          this._selectedTreeNode = null;
          this._error = null;
          this._patterns.clear();
          this._expandedNodes.clear();
          this.requestUpdate();
        })
      );
    }, 0);

    // Keyboard navigation
    this.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
        e.preventDefault();
        this._prevStep();
      } else if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
        e.preventDefault();
        this._nextStep();
      } else if (e.key === 'Escape') {
        e.preventDefault();
        dispatch('macro:stop');
      } else if (e.key === 'Tab' && !e.ctrlKey && !e.metaKey) {
        // Tab toggles view (only within the panel)
        if (this._steps.length > 0 || this._treeNodes.length > 0) {
          e.preventDefault();
          this._toggleView();
        }
      }
    });

    // Make focusable for keyboard events
    if (!this.hasAttribute('tabindex')) {
      this.setAttribute('tabindex', '0');
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const u of this._unsubs) u();
  }

  updated() {
    // Scroll selected item into view
    const selected = this.shadowRoot?.querySelector('.step-item.selected, .tree-label.selected');
    if (selected) {
      selected.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }

  // ── View toggle ──

  _toggleView() {
    this._view = this._view === 'stepper' ? 'tree' : 'stepper';
    this.requestUpdate();
  }

  // ── Stepper navigation ──

  _prevStep() {
    if (this._currentIndex > 0) {
      this._currentIndex--;
      this.requestUpdate();
    }
  }

  _nextStep() {
    const steps = this._filteredSteps;
    if (this._currentIndex < steps.length - 1) {
      this._currentIndex++;
      this.requestUpdate();
    }
  }

  _selectStep(index) {
    this._currentIndex = index;
    this.requestUpdate();
  }

  _setFilter(filter) {
    this._filter = filter;
    this._currentIndex = this._filteredSteps.length > 0 ? 0 : -1;
    this.requestUpdate();
  }

  // ── Tree navigation ──

  _toggleTreeNode(id) {
    if (this._expandedNodes.has(id)) {
      this._expandedNodes.delete(id);
    } else {
      this._expandedNodes.add(id);
    }
    this.requestUpdate();
  }

  _selectTreeNode(node) {
    this._selectedTreeNode = node;
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
    walk(this._treeNodes);
    this.requestUpdate();
  }

  _collapseAll() {
    this._expandedNodes.clear();
    this.requestUpdate();
  }

  // ── Stepper rendering ──

  _renderStepItem(step, index) {
    const isSelected = index === this._currentIndex;
    const isMacro = step.type === 'macro';

    return html`
      <div class="step-item ${isSelected ? 'selected' : ''}"
           @click=${() => this._selectStep(index)}>
        <span class="step-num">${index + 1}</span>
        <span class="step-type ${isMacro ? 'macro' : ''}">${step.type}</span>
        ${step.macro ? html`<span class="step-macro">${step.macro}</span>` : ''}
      </div>
    `;
  }

  // ── Tree rendering ──

  _renderTreeNode(node) {
    if (!node) return html``;
    // Skip anonymous nodes with no macro and no children
    if (!node.macro && (!node.children || node.children.length === 0)) {
      return html``;
    }

    const hasChildren = node.children && node.children.length > 0;
    const isExpanded = this._expandedNodes.has(node.id);
    const isSelected = this._selectedTreeNode?.id === node.id;

    // Truncate label for display
    const label = node.label?.length > 40
      ? node.label.substring(0, 40) + '...'
      : node.label || '';

    return html`
      <div class="tree-node">
        <div class="tree-label ${isSelected ? 'selected' : ''}"
             @click=${() => this._selectTreeNode(node)}>
          ${hasChildren
            ? html`<span class="toggle" @click=${(e) => { e.stopPropagation(); this._toggleTreeNode(node.id); }}>
                ${isExpanded ? '\u25BC' : '\u25B6'}
              </span>`
            : html`<span class="toggle"></span>`}
          ${node.macro
            ? html`<span class="macro-name">${node.macro}</span>
                   <span class="arrow">\u2192</span>`
            : ''}
          <span>${label}</span>
        </div>
        ${hasChildren && isExpanded ? html`
          <div class="tree-children">
            ${node.children.map(c => this._renderTreeNode(c))}
          </div>
        ` : ''}
      </div>
    `;
  }

  // ── Detail pane (shared by both views) ──

  _renderDetail() {
    // In tree view, show the selected tree node's data
    if (this._view === 'tree') {
      return this._renderTreeDetail();
    }
    // In stepper view, show the current step
    return this._renderStepDetail();
  }

  // Render text with highlighted foci spans
  _renderCodeWithFoci(text, foci, highlightClass) {
    if (!text || !foci || foci.length === 0) {
      return html`<div class="code-block">${text || '(empty)'}</div>`;
    }

    // Sort foci by offset ascending, filter valid ones
    const sorted = [...foci]
      .filter(f => f.offset != null && f.span != null && f.offset >= 0)
      .sort((a, b) => a.offset - b.offset);

    if (sorted.length === 0) {
      return html`<div class="code-block">${text}</div>`;
    }

    // Build segments: alternating plain text and highlighted spans
    const parts = [];
    let pos = 0;
    for (const f of sorted) {
      const start = f.offset;
      const end = Math.min(f.offset + f.span, text.length);
      if (start > pos) {
        parts.push(text.substring(pos, start));
      }
      if (start < text.length) {
        parts.push(html`<span class="${highlightClass}">${text.substring(start, end)}</span>`);
      }
      pos = end;
    }
    if (pos < text.length) {
      parts.push(text.substring(pos));
    }

    return html`<div class="code-block">${parts}</div>`;
  }

  _renderStepDetail() {
    const step = this._currentStep;
    if (!step) {
      return html`<div class="empty">Select a step to view details</div>`;
    }

    const pattern = this._patterns.get(step.id);
    // Use original source text for before (with foci highlighting),
    // fall back to pretty-printed if unavailable
    const beforeText = step.originalBefore || step.before;

    return html`
      <div class="info-row">
        <span class="info-label">Step:</span>
        <span>${step.typeLabel || step.type}</span>
        ${step.macro ? html`
          <span class="info-label" style="margin-left: 8px">Macro:</span>
          <span class="macro-name">${step.macro}</span>
        ` : ''}
      </div>

      <div class="detail-section">
        <div class="detail-label">Before</div>
        ${this._renderCodeWithFoci(beforeText, step.foci, 'focus-highlight')}
      </div>

      <div class="detail-section">
        <div class="detail-label">After</div>
        <div class="code-block">${step.after || '(empty)'}</div>
      </div>

      ${pattern ? html`
        <div class="detail-section">
          <div class="detail-label">Pattern</div>
          <div class="pattern-section">
            <div>${pattern.pattern}</div>
            ${pattern.source ? html`
              <div class="pattern-source">from: ${pattern.source}</div>
            ` : ''}
          </div>
        </div>
      ` : ''}
    `;
  }

  _renderTreeDetail() {
    const node = this._selectedTreeNode;
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
        <div class="detail-label">Expression</div>
        <div class="code-block">${node.label || '(empty)'}</div>
      </div>

      ${node.children && node.children.length > 0 ? html`
        <div class="detail-section">
          <div class="detail-label">Children</div>
          <div style="font-size: var(--ui-fs-md); color: var(--fg-secondary, #616161);">
            ${node.children.length} sub-expansion${node.children.length > 1 ? 's' : ''}
          </div>
        </div>
      ` : ''}
    `;
  }

  // ── Main render ──

  render() {
    if (this._error) {
      return html`
        <div class="toolbar">
          <button @click=${() => dispatch('macro:stop')}>Clear</button>
        </div>
        <div class="empty">Error: ${this._error}</div>
      `;
    }

    const hasData = this._steps.length > 0 || this._treeNodes.length > 0;

    if (!hasData) {
      return html`
        <div class="toolbar">
          <span style="color: var(--fg-muted, #999); font-size: var(--ui-fs-md);">
            Use Expand Macros (Cmd+Shift+E) to view macro expansions
          </span>
        </div>
        <div class="empty">No expansion data. Open a Racket file and click Expand Macros.</div>
      `;
    }

    const steps = this._filteredSteps;
    const total = steps.length;
    const current = this._currentIndex + 1;
    const isStepper = this._view === 'stepper';

    return html`
      <div class="toolbar">
        <button class="${isStepper ? 'active' : ''}"
                @click=${() => { this._view = 'stepper'; this.requestUpdate(); }}>Stepper</button>
        <button class="${!isStepper ? 'active' : ''}"
                @click=${() => { this._view = 'tree'; this.requestUpdate(); }}>Tree</button>
        <div class="separator"></div>
        ${isStepper ? html`
          <button @click=${() => this._prevStep()}
                  ?disabled=${this._currentIndex <= 0}>\u25C0 Prev</button>
          <button @click=${() => this._nextStep()}
                  ?disabled=${this._currentIndex >= total - 1}>Next \u25B6</button>
          <select class="filter-select"
                  @change=${(e) => this._setFilter(e.target.value)}>
            <option value="all" ?selected=${this._filter === 'all'}>All steps</option>
            <option value="macro" ?selected=${this._filter === 'macro'}>Macro only</option>
          </select>
          <span class="step-counter">Step ${current} of ${total}</span>
        ` : html`
          <button @click=${() => this._expandAll()}>Expand All</button>
          <button @click=${() => this._collapseAll()}>Collapse All</button>
        `}
        <button @click=${() => dispatch('macro:stop')}>Clear</button>
      </div>
      <div class="content">
        ${isStepper ? html`
          <div class="step-list">
            ${steps.map((s, i) => this._renderStepItem(s, i))}
          </div>
        ` : html`
          <div class="tree-pane">
            ${this._treeNodes.map(f => this._renderTreeNode(f))}
          </div>
        `}
        <div class="detail-pane">
          ${this._renderDetail()}
        </div>
      </div>
    `;
  }
}

customElements.define('hm-macro-panel', HmMacroPanel);
