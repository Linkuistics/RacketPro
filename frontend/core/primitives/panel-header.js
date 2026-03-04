// primitives/panel-header.js — hm-panel-header
//
// Compact section header (28px) used above panels like the terminal.
// Displays an uppercase label with subtle borders.

import { LitElement, html, css } from 'lit';

class HmPanelHeader extends LitElement {
  static properties = {
    label: { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      height: var(--panel-header-h, 28px);
      min-height: var(--panel-header-h, 28px);
      padding: 0 12px;
      background: var(--bg-panel-header, #F3F3F3);
      border-top: 1px solid var(--border, #E5E5E5);
      border-bottom: 1px solid var(--border, #E5E5E5);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 11px;
      font-weight: 600;
      letter-spacing: 0.5px;
      text-transform: uppercase;
      color: var(--fg-panel-header, #616161);
      flex-shrink: 0;
      box-sizing: border-box;
    }
  `;

  constructor() {
    super();
    this.label = '';
  }

  render() {
    return html`${this.label}`;
  }
}

customElements.define('hm-panel-header', HmPanelHeader);
