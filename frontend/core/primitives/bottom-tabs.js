// primitives/bottom-tabs.js — hm-bottom-tabs
//
// Horizontal tab bar for the bottom panel. Fixed tabs (no close/dirty).
// Active tab controlled by `current-bottom-tab` cell.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { dispatch, onMessage } from '../bridge.js';

class HmBottomTabs extends LitElement {
  static properties = {
    tabs: { type: Array },
    _activeTab: { type: String, state: true },
    _problemsCount: { type: Number, state: true },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      height: 28px;
      min-height: 28px;
      background: var(--bg-toolbar, #F8F8F8);
      border-top: 1px solid var(--border, #D4D4D4);
      border-bottom: 1px solid var(--border, #D4D4D4);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: var(--ui-fs-sm);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      flex-shrink: 0;
      user-select: none;
    }

    .tab {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 0 12px;
      height: 100%;
      cursor: pointer;
      color: var(--fg-muted, #999999);
      border-bottom: 2px solid transparent;
      transition: color 0.1s;
    }

    .tab:hover {
      color: var(--fg-secondary, #616161);
    }

    .tab.active {
      color: var(--fg-primary, #333333);
      border-bottom-color: var(--accent, #007ACC);
    }

    .badge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 16px;
      height: 16px;
      padding: 0 4px;
      border-radius: 8px;
      background: var(--accent, #007ACC);
      color: white;
      font-size: var(--ui-fs-xs);
      line-height: 1;
    }
  `;

  constructor() {
    super();
    this.tabs = [];
    this._activeTab = 'terminal';
    this._problemsCount = 0;
    this._disposeEffects = [];
    this._unsubs = [];
  }

  firstUpdated() {
    setTimeout(() => {
      const tabCell = getCell('current-bottom-tab');
      this._disposeEffects.push(effect(() => {
        this._activeTab = tabCell.value;
      }));

      this._unsubs.push(
        onMessage('intel:diagnostics', (msg) => {
          this._problemsCount = (msg.items || []).length;
        }),
        onMessage('intel:clear', () => {
          this._problemsCount = 0;
        })
      );
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const d of this._disposeEffects) d();
    for (const u of this._unsubs) u();
  }

  _selectTab(id) {
    dispatch('bottom-tab:select', { tab: id });
  }

  render() {
    return html`
      ${(this.tabs || []).map(t => html`
        <div class="tab ${this._activeTab === t.id ? 'active' : ''}"
             @click=${() => this._selectTab(t.id)}>
          ${t.label}
          ${t.id === 'problems' && this._problemsCount > 0
            ? html`<span class="badge">${this._problemsCount}</span>`
            : ''}
        </div>
      `)}
    `;
  }
}

customElements.define('hm-bottom-tabs', HmBottomTabs);
