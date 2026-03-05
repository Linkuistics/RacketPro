// primitives/stepper.js — hm-stepper-toolbar + hm-bindings-panel
//
// Stepper UI components.  The toolbar provides Step Forward/Back/Continue/Stop
// buttons with a step counter.  The bindings panel shows before/after
// expressions and variable bindings from the current step.
//
// Both components toggle visibility based on the `stepper-active` cell.
// All effects are deferred with setTimeout to avoid WKWebView deadlock.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { onMessage, dispatch } from '../bridge.js';

// ── hm-stepper-toolbar ──────────────────────────────────────

class HmStepperToolbar extends LitElement {
  static styles = css`
    :host {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: var(--bg-toolbar, #F8F8F8);
      border-bottom: 1px solid var(--border, #D4D4D4);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 13px;
      min-height: 28px;
      flex-shrink: 0;
    }

    :host([hidden]) { display: none; }

    button {
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

    button:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .step-info {
      margin-left: auto;
      color: var(--fg-muted, #999999);
    }
  `;

  constructor() {
    super();
    this._disposeEffect = null;
    this._disposeStepEffect = null;
    this._unsubs = [];
  }

  firstUpdated() {
    setTimeout(() => {
      const activeCell = getCell('stepper-active');
      const stepCell = getCell('stepper-step');
      this._disposeEffect = effect(() => {
        this.toggleAttribute('hidden', !activeCell.value);
      });
      this._disposeStepEffect = effect(() => {
        const el = this.shadowRoot?.getElementById('step-num');
        if (el) el.textContent = String(stepCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
    if (this._disposeStepEffect) this._disposeStepEffect();
    for (const u of this._unsubs) u();
  }

  render() {
    // NOTE: The stepper currently runs to completion — interactive
    // forward/back stepping requires step-at-a-time execution (future work).
    return html`
      <button @click=${() => dispatch('stepper:stop')}>Stop</button>
      <span class="step-info">Step <span id="step-num">0</span></span>
    `;
  }
}

customElements.define('hm-stepper-toolbar', HmStepperToolbar);

// ── hm-bindings-panel ───────────────────────────────────────

class HmBindingsPanel extends LitElement {
  static styles = css`
    :host {
      display: block;
      overflow-y: auto;
      padding: 8px 12px;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 13px;
      font-weight: var(--font-editor-weight, 300);
      background: var(--bg-primary, #FFFFFF);
      color: var(--fg-primary, #333333);
    }

    :host([hidden]) { display: none; }

    .binding {
      display: flex;
      gap: 12px;
      padding: 2px 0;
      border-bottom: 1px solid var(--border-light, #F0F0F0);
    }

    .name {
      color: var(--accent, #007ACC);
      min-width: 80px;
    }

    .value {
      color: var(--fg-secondary, #616161);
    }

    .empty {
      color: var(--fg-muted, #999999);
      font-style: italic;
    }

    .step-expr {
      margin-bottom: 8px;
      padding: 6px 8px;
      background: #FFFDE7;
      border-left: 3px solid #FBC02D;
      border-radius: 2px;
    }

    .step-label {
      font-size: 11px;
      color: var(--fg-muted, #999999);
      margin-bottom: 4px;
    }
  `;

  constructor() {
    super();
    this._bindings = [];
    this._before = '';
    this._after = '';
    this._unsubs = [];
    this._disposeEffect = null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage('stepper:step', (msg) => {
          const data = msg.data || {};
          this._bindings = data.bindings || [];
          this._before = (data.before || []).join(' ');
          this._after = (data.after || []).join(' ');
          this.requestUpdate();
        })
      );

      const activeCell = getCell('stepper-active');
      this._disposeEffect = effect(() => {
        this.toggleAttribute('hidden', !activeCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
    for (const u of this._unsubs) u();
  }

  render() {
    return html`
      ${this._before ? html`
        <div class="step-expr">
          <div class="step-label">Before:</div>
          <code>${this._before}</code>
        </div>` : ''}
      ${this._after ? html`
        <div class="step-expr">
          <div class="step-label">After:</div>
          <code>${this._after}</code>
        </div>` : ''}
      ${this._bindings.length > 0
        ? this._bindings.map(b => html`
            <div class="binding">
              <span class="name">${b.name}</span>
              <span class="value">${b.value}</span>
            </div>`)
        : html`<div class="empty">No bindings</div>`}
    `;
  }
}

customElements.define('hm-bindings-panel', HmBindingsPanel);
