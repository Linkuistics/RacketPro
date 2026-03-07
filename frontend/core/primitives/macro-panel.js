// primitives/macro-panel.js — hm-macro-panel
//
// Displays macro expansion steps with two views:
// - Stepper: flat list of expansion steps with prev/next navigation
// - Tree: hierarchical view of expansion structure (added in Task 4)
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

    .toolbar button.active {
      background: var(--accent-bg, #E3F2FD);
      border-color: var(--accent, #007ACC);
      color: var(--accent, #007ACC);
    }

    .toolbar button:disabled {
      opacity: 0.4;
      cursor: default;
    }

    .step-counter {
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      margin-left: auto;
    }

    .content {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

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
      font-size: 12px;
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
      font-size: 11px;
      min-width: 24px;
    }

    .step-type {
      font-size: 10px;
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

    .detail-pane {
      flex: 1;
      overflow: auto;
      padding: 8px 12px;
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
      font-size: 12px;
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
      font-size: 12px;
    }

    .pattern-source {
      font-size: 11px;
      color: var(--fg-muted, #999999);
      margin-top: 4px;
    }
  `;

  constructor() {
    super();
    this._steps = [];
    this._currentIndex = -1;
    this._unsubs = [];
    this._error = null;
    this._filter = 'all'; // 'all' | 'macro'
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
        onMessage('macro:pattern', (msg) => {
          if (msg.stepId) {
            this._patterns.set(msg.stepId, msg);
          }
          this.requestUpdate();
        }),
        onMessage('macro:error', (msg) => {
          this._error = msg.error || 'Unknown error';
          this._steps = [];
          this._currentIndex = -1;
          this.requestUpdate();
        }),
        onMessage('macro:clear', () => {
          this._steps = [];
          this._currentIndex = -1;
          this._error = null;
          this._patterns.clear();
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
    // Scroll selected step into view
    const selected = this.shadowRoot?.querySelector('.step-item.selected');
    if (selected) {
      selected.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }

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

  _renderDetail() {
    const step = this._currentStep;
    if (!step) {
      return html`<div class="empty">Select a step to view details</div>`;
    }

    const pattern = this._patterns.get(step.id);

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
        <div class="code-block">${step.before || '(empty)'}</div>
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

  render() {
    if (this._error) {
      return html`
        <div class="toolbar">
          <button @click=${() => dispatch('macro:stop')}>Clear</button>
        </div>
        <div class="empty">Error: ${this._error}</div>
      `;
    }

    if (this._steps.length === 0) {
      return html`
        <div class="toolbar">
          <span style="color: var(--fg-muted, #999); font-size: 12px;">
            Use Expand Macros (Cmd+Shift+E) to view macro expansions
          </span>
        </div>
        <div class="empty">No expansion data. Open a Racket file and click Expand Macros.</div>
      `;
    }

    const steps = this._filteredSteps;
    const total = steps.length;
    const current = this._currentIndex + 1;

    return html`
      <div class="toolbar">
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
        <button @click=${() => dispatch('macro:stop')}>Clear</button>
      </div>
      <div class="content">
        <div class="step-list">
          ${steps.map((s, i) => this._renderStepItem(s, i))}
        </div>
        <div class="detail-pane">
          ${this._renderDetail()}
        </div>
      </div>
    `;
  }
}

customElements.define('hm-macro-panel', HmMacroPanel);
