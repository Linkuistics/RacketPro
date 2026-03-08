// primitives/input.js — hm-button
//
// Button primitive.  The `onClick` property is a string naming an event
// that will be dispatched to the Racket process via the bridge when the
// button is clicked.

import { LitElement, html, css } from 'lit';
import { dispatch } from '../bridge.js';

/** Map icon names to inline SVG templates. */
const ICONS = {
  play: html`<svg width="14" height="14" viewBox="0 0 16 16"><path d="M4 2l10 6-10 6z" fill="currentColor"/></svg>`,
  'new-file': html`<svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M4 1h5.5L13 4.5V14a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1z" stroke="currentColor" stroke-width="1.2"/><path d="M9 1v4h4" stroke="currentColor" stroke-width="1.2"/><path d="M8 7v5M5.5 9.5h5" stroke="currentColor" stroke-width="1.2"/></svg>`,
  'open-file': html`<svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M1.5 3.5h5l1 1.5h7v8h-13z" stroke="currentColor" stroke-width="1.2"/></svg>`,
  save: html`<svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M2 1h9.5L14 3.5V14a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1z" stroke="currentColor" stroke-width="1.2"/><rect x="5" y="1" width="5" height="4" rx="0.5" stroke="currentColor" stroke-width="1"/><rect x="4" y="9" width="7" height="4" rx="0.5" stroke="currentColor" stroke-width="1"/></svg>`,
};

class HmButton extends LitElement {
  static properties = {
    label:    { type: String },
    icon:     { type: String },
    onClick:  { type: String },
    variant:  { type: String },
    disabled: { type: Boolean },
  };

  static styles = css`
    :host {
      display: inline-block;
    }

    button {
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: var(--ui-fs);
      padding: 4px 12px;
      border: 1px solid var(--border, #E5E5E5);
      border-radius: 4px;
      cursor: pointer;
      background: #FFFFFF;
      color: var(--fg-primary, #333333);
      transition: background 0.1s ease, border-color 0.1s ease;
    }

    button:hover:not(:disabled) {
      background: #F0F0F0;
      border-color: var(--border-strong, #D4D4D4);
    }

    button:active:not(:disabled) {
      background: #E8E8E8;
    }

    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    button.primary {
      background: var(--accent, #007ACC);
      color: #FFFFFF;
      border-color: var(--accent, #007ACC);
    }

    button.primary:hover:not(:disabled) {
      background: var(--accent-hover, #0062A3);
      border-color: var(--accent-hover, #0062A3);
    }

    button.danger {
      background: var(--danger, #D32F2F);
      color: #FFFFFF;
      border-color: var(--danger, #D32F2F);
    }

    button.danger:hover:not(:disabled) {
      background: #B71C1C;
      border-color: #B71C1C;
    }

    .btn-icon {
      display: flex;
      align-items: center;
    }

    button.has-icon {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      padding: 4px 10px;
    }

    /* Icon-only button (icon set but no label) */
    button.icon-only {
      padding: 4px 8px;
    }
  `;

  constructor() {
    super();
    this.label = '';
    this.icon = '';
    this.onClick = '';
    this.variant = '';
    this.disabled = false;
  }

  _handleClick() {
    if (this.disabled || !this.onClick) return;
    dispatch(this.onClick);
  }

  render() {
    const iconTpl = this.icon ? ICONS[this.icon] : null;
    const hasIcon = !!iconTpl;
    const hasLabel = !!this.label;
    const classes = [
      this.variant || '',
      hasIcon ? 'has-icon' : '',
      hasIcon && !hasLabel ? 'icon-only' : '',
    ].filter(Boolean).join(' ');

    return html`
      <button
        class="${classes}"
        ?disabled="${this.disabled}"
        @click="${this._handleClick}"
        title="${this.label || ''}"
      >${hasIcon ? html`<span class="btn-icon">${iconTpl}</span>` : ''}${hasLabel ? this.label : ''}</button>
    `;
  }
}

customElements.define('hm-button', HmButton);
