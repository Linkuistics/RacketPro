// primitives/layout.js — mr-vbox, mr-hbox
//
// Flex-based layout containers.  Children are projected via <slot>.
// The Racket layout tree uses "vbox" and "hbox" types, which map to
// mr-vbox (flex-direction: column) and mr-hbox (flex-direction: row).

import { LitElement, html, css } from 'lit';

// ── mr-vbox ──────────────────────────────────────────────────

class MrVbox extends LitElement {
  static properties = {
    gap:     { type: String },
    padding: { type: String },
    flex:    { type: String },
    align:   { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      box-sizing: border-box;
    }
  `;

  constructor() {
    super();
    this.gap = '0';
    this.padding = '0';
    this.flex = '';
    this.align = '';
  }

  render() {
    const s = {
      gap: this._px(this.gap),
      padding: this._px(this.padding),
    };
    if (this.flex)  s.flex = this.flex;
    if (this.align) s.alignItems = this.align;

    return html`<div style="${this._styleString(s)}"><slot></slot></div>`;
  }

  /** Append "px" to bare numbers, pass through strings like "8px" or "auto". */
  _px(val) {
    if (val === undefined || val === null) return '0';
    const s = String(val);
    return /^\d+$/.test(s) ? `${s}px` : s;
  }

  _styleString(obj) {
    return Object.entries(obj)
      .filter(([, v]) => v !== undefined && v !== '')
      .map(([k, v]) => `${k.replace(/[A-Z]/g, m => '-' + m.toLowerCase())}:${v}`)
      .join(';');
  }
}

customElements.define('mr-vbox', MrVbox);

// ── mr-hbox ──────────────────────────────────────────────────

class MrHbox extends LitElement {
  static properties = {
    gap:     { type: String },
    padding: { type: String },
    flex:    { type: String },
    align:   { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      flex-direction: row;
      box-sizing: border-box;
    }
  `;

  constructor() {
    super();
    this.gap = '0';
    this.padding = '0';
    this.flex = '';
    this.align = '';
  }

  render() {
    const s = {
      gap: this._px(this.gap),
      padding: this._px(this.padding),
    };
    if (this.flex)  s.flex = this.flex;
    if (this.align) s.alignItems = this.align;

    return html`<div style="${this._styleString(s)}"><slot></slot></div>`;
  }

  _px(val) {
    if (val === undefined || val === null) return '0';
    const s = String(val);
    return /^\d+$/.test(s) ? `${s}px` : s;
  }

  _styleString(obj) {
    return Object.entries(obj)
      .filter(([, v]) => v !== undefined && v !== '')
      .map(([k, v]) => `${k.replace(/[A-Z]/g, m => '-' + m.toLowerCase())}:${v}`)
      .join(';');
  }
}

customElements.define('mr-hbox', MrHbox);
