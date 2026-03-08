// primitives/stepper.js — hm-stepper-toolbar + hm-bindings-panel
//
// Stepper UI components.  The toolbar provides Step Forward/Back/Continue/Stop
// buttons with a step counter.  The bindings panel shows before/after
// expressions and variable bindings from the current step.
//
// Visibility is controlled by the parent hm-tab-content via data-tab-id
// attributes, not by these components themselves.
// Effects are deferred with setTimeout to avoid WKWebView deadlock.

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
      font-size: var(--ui-fs);
      min-height: 28px;
      flex-shrink: 0;
    }

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
      font-size: var(--ui-fs-md);
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
    this._disposeStepEffect = null;
    this._unsubs = [];
  }

  firstUpdated() {
    setTimeout(() => {
      const stepCell = getCell('stepper-step');
      this._disposeStepEffect = effect(() => {
        const el = this.shadowRoot?.getElementById('step-num');
        if (el) el.textContent = String(stepCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeStepEffect) this._disposeStepEffect();
    for (const u of this._unsubs) u();
  }

  render() {
    return html`
      <button id="btn-back" @click=${() => dispatch('stepper:back')}>Back</button>
      <button id="btn-forward" @click=${() => dispatch('stepper:forward')}>Forward</button>
      <button id="btn-continue" @click=${() => dispatch('stepper:continue')}>Continue</button>
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
      font-size: var(--ui-fs);
      font-weight: var(--font-editor-weight, 300);
      background: var(--bg-primary, #FFFFFF);
      color: var(--fg-primary, #333333);
    }

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
      font-size: var(--ui-fs-sm);
      color: var(--fg-muted, #999999);
      margin-bottom: 4px;
    }

    .section-header {
      font-size: var(--ui-fs-sm);
      font-weight: 600;
      color: var(--fg-muted, #999999);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin: 8px 0 4px;
      padding-top: 6px;
      border-top: 1px solid var(--border-light, #F0F0F0);
    }

    .section-header:first-child {
      margin-top: 0;
      padding-top: 0;
      border-top: none;
    }
  `;

  constructor() {
    super();
    this._bindings = [];
    this._before = '';
    this._after = '';
    this._unsubs = [];
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
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const u of this._unsubs) u();
  }

  render() {
    const hasStep = this._before || this._after;
    return html`
      ${hasStep ? html`
        <div class="section-header">Reduction</div>` : ''}
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
      ${this._bindings.length > 0 ? html`
        <div class="section-header">Bindings</div>
        ${this._bindings.map(b => html`
            <div class="binding">
              <span class="name">${b.name}</span>
              <span class="value">${b.value}</span>
            </div>`)}
      ` : hasStep ? html`<div class="section-header">Bindings</div>
        <div class="empty">No variable bindings yet</div>` : ''}
    `;
  }
}

customElements.define('hm-bindings-panel', HmBindingsPanel);
