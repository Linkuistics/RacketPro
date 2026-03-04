// primitives/input.js — mr-button
//
// Button primitive.  The `onClick` property is a string naming an event
// that will be dispatched to the Racket process via the bridge when the
// button is clicked.

import { LitElement, html, css } from 'lit';
import { dispatch } from '../bridge.js';

class MrButton extends LitElement {
  static properties = {
    label:    { type: String },
    onClick:  { type: String },
    variant:  { type: String },
    disabled: { type: Boolean },
  };

  static styles = css`
    :host {
      display: inline-block;
    }

    button {
      font-family: var(--font-sans, system-ui, sans-serif);
      font-size: 0.9rem;
      padding: 6px 16px;
      border: 1px solid var(--border, #444);
      border-radius: 6px;
      cursor: pointer;
      background: var(--bg-primary, #2a2a2a);
      color: var(--fg-primary, #e0e0e0);
      transition: background 0.15s ease, border-color 0.15s ease;
    }

    button:hover:not(:disabled) {
      background: var(--bg-hover, #333);
      border-color: var(--accent, #569cd6);
    }

    button:active:not(:disabled) {
      background: var(--bg-active, #3a3a3a);
    }

    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
    }

    button.primary {
      background: var(--accent, #569cd6);
      color: var(--fg-on-accent, #fff);
      border-color: var(--accent, #569cd6);
    }

    button.primary:hover:not(:disabled) {
      background: var(--accent-hover, #4a8ac4);
    }

    button.danger {
      background: var(--danger, #d64545);
      color: var(--fg-on-accent, #fff);
      border-color: var(--danger, #d64545);
    }

    button.danger:hover:not(:disabled) {
      background: var(--danger-hover, #c43c3c);
    }
  `;

  constructor() {
    super();
    this.label = '';
    this.onClick = '';
    this.variant = '';
    this.disabled = false;
  }

  _handleClick() {
    if (this.disabled || !this.onClick) return;
    dispatch(this.onClick);
  }

  render() {
    return html`
      <button
        class="${this.variant || ''}"
        ?disabled="${this.disabled}"
        @click="${this._handleClick}"
      >${this.label}</button>
    `;
  }
}

customElements.define('mr-button', MrButton);
