// primitives/error-panel.js — hm-error-panel
//
// Displays a list of diagnostics (errors, warnings) from check-syntax.
// Click a row to jump to the location in the editor.

import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';

class HmErrorPanel extends LitElement {
  static properties = {
    items: { type: Array, state: true },
    visible: { type: Boolean, reflect: true },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      overflow: auto;
      background: var(--bg-panel, #F5F5F5);
      font-family: 'SF Mono', 'Fira Code', Menlo, monospace;
      font-size: 12px;
    }

    :host([hidden]) {
      display: none;
    }

    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 4px 8px;
      background: var(--bg-panel-header, #E8E8E8);
      font-weight: 600;
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: #555;
      border-bottom: 1px solid #DDD;
    }

    .row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 3px 8px;
      cursor: pointer;
      border-bottom: 1px solid #EEE;
    }

    .row:hover {
      background: #E3F2FD;
    }

    .icon {
      flex-shrink: 0;
      width: 14px;
      text-align: center;
    }

    .icon.error { color: #D32F2F; }
    .icon.warning { color: #F57F17; }
    .icon.info { color: #1565C0; }

    .message {
      flex: 1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: #333;
    }

    .location {
      flex-shrink: 0;
      color: #888;
      font-size: 11px;
    }

    .empty {
      padding: 8px;
      color: #999;
      font-style: italic;
    }
  `;

  constructor() {
    super();
    this.items = [];
    this.visible = true;
    this._unsubs = [];
  }

  connectedCallback() {
    super.connectedCallback();
    this._unsubs.push(
      onMessage('intel:diagnostics', (msg) => {
        this.items = msg.items || [];
      })
    );
    this._unsubs.push(
      onMessage('intel:clear', () => {
        this.items = [];
      })
    );
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const unsub of this._unsubs) unsub();
    this._unsubs = [];
  }

  _severityIcon(severity) {
    switch (severity) {
      case 'error': return '\u2297';   // circled times
      case 'warning': return '\u26A0'; // warning sign
      case 'info': return '\u2139';    // information source
      default: return '\u2022';        // bullet
    }
  }

  _handleClick(item) {
    dispatch('editor:goto', {
      line: item.range.startLine,
      col: item.range.startCol,
    });
  }

  render() {
    const count = this.items.length;
    return html`
      <div class="header">
        <span>Problems ${count > 0 ? `(${count})` : ''}</span>
      </div>
      ${count === 0
        ? html`<div class="empty">No problems detected.</div>`
        : this.items.map((item) => html`
            <div class="row" @click=${() => this._handleClick(item)}>
              <span class="icon ${item.severity}">
                ${this._severityIcon(item.severity)}
              </span>
              <span class="message">${item.message}</span>
              <span class="location">
                ${item.range.startLine}:${item.range.startCol}
              </span>
            </div>
          `)
      }
    `;
  }
}

customElements.define('hm-error-panel', HmErrorPanel);
