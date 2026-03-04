// primitives/chrome.js — mr-toolbar, mr-statusbar
//
// Chrome components for the IDE shell.  mr-toolbar is a horizontal
// container for action buttons; mr-statusbar shows status text at the
// bottom of the window.  Both support CSS custom properties for theming.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell, resolveValue } from '../cells.js';

// ── mr-toolbar ─────────────────────────────────────────────

class MrToolbar extends LitElement {
  static styles = css`
    :host {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 12px;
      background: var(--mr-toolbar-bg, #f5f5f5);
      border-bottom: 1px solid var(--mr-border, #e0e0e0);
      flex-shrink: 0;
      min-height: 36px;
    }
  `;

  render() {
    return html`<slot></slot>`;
  }
}

customElements.define('mr-toolbar', MrToolbar);

// ── mr-statusbar ───────────────────────────────────────────

class MrStatusbar extends LitElement {
  static properties = {
    content: { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      padding: 2px 12px;
      background: var(--mr-statusbar-bg, #f0f0f0);
      border-top: 1px solid var(--mr-border, #e0e0e0);
      font-size: 12px;
      color: var(--mr-statusbar-fg, #666);
      flex-shrink: 0;
      min-height: 24px;
    }
  `;

  constructor() {
    super();
    this.content = '';
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

  render() {
    return html`${resolveValue(this.content)}`;
  }
}

customElements.define('mr-statusbar', MrStatusbar);
