// primitives/content.js — mr-heading, mr-text
//
// Text content primitives.  Both support a `content` property that can
// be a plain string or a cell reference (e.g. "cell:title").  When the
// content is a cell reference, an effect() is set up to re-render the
// component whenever the underlying signal changes.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell, resolveValue } from '../cells.js';

// ── mr-heading ───────────────────────────────────────────────

class MrHeading extends LitElement {
  static properties = {
    content: { type: String },
    level:   { type: Number },
  };

  static styles = css`
    :host { display: block; }
    h1, h2, h3 {
      margin: 0;
      color: var(--fg-primary, #e0e0e0);
      font-family: var(--font-sans, system-ui, sans-serif);
    }
    h1 { font-size: 1.75rem; }
    h2 { font-size: 1.35rem; }
    h3 { font-size: 1.1rem; }
  `;

  constructor() {
    super();
    this.content = '';
    this.level = 1;
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
    if (changed.has('content')) {
      this._teardownEffect();
      this._setupCellEffect();
    }
  }

  _setupCellEffect() {
    if (typeof this.content === 'string' && this.content.startsWith('cell:')) {
      const cellName = this.content.slice(5);
      // Eagerly ensure the cell signal exists
      getCell(cellName);
      this._disposeEffect = effect(() => {
        // Reading .value subscribes this effect to the signal
        getCell(cellName).value;
        this.requestUpdate();
      });
    }
  }

  _teardownEffect() {
    if (this._disposeEffect) {
      this._disposeEffect();
      this._disposeEffect = null;
    }
  }

  get displayContent() {
    return resolveValue(this.content);
  }

  render() {
    const text = this.displayContent ?? '';
    switch (this.level) {
      case 2:  return html`<h2>${text}</h2>`;
      case 3:  return html`<h3>${text}</h3>`;
      default: return html`<h1>${text}</h1>`;
    }
  }
}

customElements.define('mr-heading', MrHeading);

// ── mr-text ──────────────────────────────────────────────────

class MrText extends LitElement {
  static properties = {
    content:   { type: String },
    textStyle: { type: String },
  };

  static styles = css`
    :host { display: block; }
    .text {
      margin: 0;
      color: var(--fg-primary, #e0e0e0);
      font-family: var(--font-sans, system-ui, sans-serif);
      font-size: 0.95rem;
      line-height: 1.5;
    }
    .muted {
      color: var(--fg-muted, #888);
    }
    .mono {
      font-family: var(--font-mono, 'SF Mono', 'Fira Code', monospace);
      font-size: 1.1rem;
    }
  `;

  constructor() {
    super();
    this.content = '';
    // The Racket layout tree sends { style: "mono" }, but the renderer
    // maps it to `textStyle` to avoid colliding with HTMLElement.style.
    this.textStyle = '';
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
    if (changed.has('content')) {
      this._teardownEffect();
      this._setupCellEffect();
    }
  }

  _setupCellEffect() {
    if (typeof this.content === 'string' && this.content.startsWith('cell:')) {
      const cellName = this.content.slice(5);
      getCell(cellName);
      this._disposeEffect = effect(() => {
        getCell(cellName).value;
        this.requestUpdate();
      });
    }
  }

  _teardownEffect() {
    if (this._disposeEffect) {
      this._disposeEffect();
      this._disposeEffect = null;
    }
  }

  get displayContent() {
    return resolveValue(this.content);
  }

  render() {
    const text = this.displayContent ?? '';
    const classes = ['text'];
    if (this.textStyle) classes.push(this.textStyle);

    return html`<span class="${classes.join(' ')}">${text}</span>`;
  }
}

customElements.define('mr-text', MrText);
