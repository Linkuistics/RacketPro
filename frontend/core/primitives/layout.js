// primitives/layout.js — hm-vbox, hm-hbox
//
// Flex-based layout containers.  Children are projected via <slot>.
// The Racket layout tree uses "vbox" and "hbox" types, which map to
// hm-vbox (flex-direction: column) and hm-hbox (flex-direction: row).
//
// Properties like flex, gap, and padding are applied to :host directly
// so the element participates correctly in the parent's flex context.

import { LitElement, html, css } from 'lit';

/** Append "px" to bare numbers, pass through strings like "8px" or "auto". */
function toPx(val) {
  if (val === undefined || val === null) return '0';
  const s = String(val);
  return /^\d+$/.test(s) ? `${s}px` : s;
}

// ── hm-vbox ──────────────────────────────────────────────────

class HmVbox extends LitElement {
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
      overflow: hidden;
    }
  `;

  constructor() {
    super();
    this.gap = '0';
    this.padding = '0';
    this.flex = '';
    this.align = '';
  }

  updated(changed) {
    // Apply layout properties directly to :host so this element
    // participates correctly in the parent's flex context.
    if (changed.has('flex'))    this.style.flex    = this.flex || '';
    if (changed.has('gap'))     this.style.gap     = toPx(this.gap);
    if (changed.has('padding')) this.style.padding = toPx(this.padding);
    if (changed.has('align'))   this.style.alignItems = this.align || '';
  }

  render() {
    return html`<slot></slot>`;
  }
}

customElements.define('hm-vbox', HmVbox);

// ── hm-hbox ──────────────────────────────────────────────────

class HmHbox extends LitElement {
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
      overflow: hidden;
    }
  `;

  constructor() {
    super();
    this.gap = '0';
    this.padding = '0';
    this.flex = '';
    this.align = '';
  }

  updated(changed) {
    if (changed.has('flex'))    this.style.flex    = this.flex || '';
    if (changed.has('gap'))     this.style.gap     = toPx(this.gap);
    if (changed.has('padding')) this.style.padding = toPx(this.padding);
    if (changed.has('align'))   this.style.alignItems = this.align || '';
  }

  render() {
    return html`<slot></slot>`;
  }
}

customElements.define('hm-hbox', HmHbox);
