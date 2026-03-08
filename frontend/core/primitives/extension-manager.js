// primitives/extension-manager.js — hm-extension-manager
//
// Displays the list of loaded extensions with Reload/Unload controls
// and a "Load Extension..." button. Subscribes to the `_extensions-list`
// cell which Racket populates via extension.rkt.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { dispatch } from '../bridge.js';

class HmExtensionManager extends LitElement {
  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      overflow-y: auto;
      background: var(--bg-panel, #F5F5F5);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 13px;
      color: var(--fg-primary, #333333);
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
      color: var(--fg-muted, #999999);
      border-bottom: 1px solid var(--border, #D4D4D4);
    }

    .ext-row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 6px 8px;
      border-bottom: 1px solid var(--border-light, #EEEEEE);
    }

    .ext-row:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .ext-status {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }

    .ext-status.active { background: #4CAF50; }
    .ext-status.error { background: #D32F2F; }

    .ext-name {
      flex: 1;
      font-weight: 500;
      color: var(--fg-primary, #333333);
    }

    .ext-btn {
      padding: 2px 8px;
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 3px;
      background: var(--bg-primary, #FFFFFF);
      color: var(--fg-primary, #333333);
      cursor: pointer;
      font-size: 12px;
      font-family: inherit;
    }

    .ext-btn:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .load-section {
      padding: 8px;
    }

    .load-btn {
      padding: 4px 12px;
    }

    .empty {
      padding: 8px;
      color: var(--fg-muted, #999999);
      font-style: italic;
    }
  `;

  constructor() {
    super();
    this._extensions = [];
    this._disposeEffects = [];
  }

  firstUpdated() {
    setTimeout(() => {
      const cell = getCell('_extensions-list');
      this._disposeEffects.push(effect(() => {
        this._extensions = cell.value || [];
        this.requestUpdate();
      }));
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const d of this._disposeEffects) d();
  }

  _reload(extId) {
    dispatch('extension:reload', { id: extId });
  }

  _unload(extId) {
    dispatch('extension:unload-request', { id: extId });
  }

  _loadNew() {
    dispatch('extension:load-dialog', {});
  }

  render() {
    const count = this._extensions.length;
    return html`
      <div class="header">
        <span>Extensions ${count > 0 ? `(${count})` : ''}</span>
      </div>
      ${count === 0
        ? html`<div class="empty">No extensions loaded.</div>`
        : this._extensions.map(ext => html`
            <div class="ext-row">
              <div class="ext-status ${ext.status || 'active'}"></div>
              <span class="ext-name">${ext.name}</span>
              <button class="ext-btn" @click=${() => this._reload(ext.id)}>Reload</button>
              <button class="ext-btn" @click=${() => this._unload(ext.id)}>Unload</button>
            </div>
          `)
      }
      <div class="load-section">
        <button class="ext-btn load-btn" @click=${this._loadNew}>Load Extension\u2026</button>
      </div>
    `;
  }
}

customElements.define('hm-extension-manager', HmExtensionManager);
