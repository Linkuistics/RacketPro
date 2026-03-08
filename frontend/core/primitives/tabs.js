// primitives/tabs.js — hm-tabs
//
// Zed-style tab bar with scroll arrows for overflow navigation.
// Active tab blends into the editor (white bg). Tab titles are centered.
// Close button appears on hover at the far right of each tab.
// Supports: middle-click close, right-click context menu (Close / Close Others / Close All).
//
// NOTE: Bridge listener registration is deferred to firstUpdated()
// to avoid triggering ensureListener() during the synchronous
// layout:set render pass (which can deadlock WKWebView).

import { LitElement, html, css } from "lit";
import { onMessage, dispatch } from "../bridge.js";
import { effect } from "@preact/signals-core";
import { getCell } from "../cells.js";

/** Extract filename from a full path. */
function basename(path) {
  const parts = path.split(/[/\\]/);
  return parts[parts.length - 1] || path;
}

class HmTabs extends LitElement {
  static styles = css`
    :host {
      display: flex;
      align-items: stretch;
      position: relative;
      height: var(--tab-h, 32px);
      min-height: var(--tab-h, 32px);
      background: var(--bg-tab-bar, #eaeaea);
      border-bottom: 1px solid var(--border, #d4d4d4);
      font-family: var(
        --font-sans,
        -apple-system,
        BlinkMacSystemFont,
        "Segoe UI",
        system-ui,
        sans-serif
      );
      font-size: var(--ui-fs-lg);
      overflow: hidden;
      flex-shrink: 0;
      box-sizing: border-box;
    }

    :host([hidden]) {
      display: none;
    }

    .tabs-area {
      display: flex;
      align-items: stretch;
      flex: 1;
      overflow-x: auto;
      overflow-y: hidden;
    }

    .tabs-area::-webkit-scrollbar {
      height: 0;
    }

    .tab {
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      padding: 0 24px;
      cursor: pointer;
      color: var(--fg-tab-active, #333333);
      background: transparent;
      border-right: 1px solid var(--border, #d4d4d4);
      white-space: nowrap;
      user-select: none;
    }

    .tab:hover {
      background: var(--bg-tab-hover, #f0f0f0);
    }

    .tab.active {
      background: var(--bg-primary, #ffffff);
      margin-bottom: -1px;
      border-bottom: 1px solid var(--bg-primary, #ffffff);
    }

    .tab-label {
      text-align: center;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .tab-close {
      display: flex;
      align-items: center;
      justify-content: center;
      position: absolute;
      right: 4px;
      top: 50%;
      transform: translateY(-50%);
      width: 18px;
      height: 18px;
      border-radius: 4px;
      opacity: 0;
      cursor: pointer;
      color: var(--fg-primary, #333333);
    }

    .tab:hover .tab-close {
      opacity: 1;
      background: rgba(0, 0, 0, 0.08);
    }

    .tab-close:hover {
      background: rgba(0, 0, 0, 0.15);
    }

    .scroll-btn {
      display: flex;
      align-items: center;
      justify-content: center;
      width: 20px;
      cursor: pointer;
      color: var(--fg-muted, #999999);
      font-size: var(--ui-fs-xl);
      user-select: none;
      flex-shrink: 0;
    }

    .scroll-btn:hover {
      color: var(--fg-primary, #333333);
      background: var(--bg-tab-hover, #f0f0f0);
    }

    .context-menu {
      position: absolute;
      z-index: 1000;
      background: var(--bg-primary, #ffffff);
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 4px;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.15);
      padding: 4px 0;
      min-width: 120px;
    }

    .ctx-item {
      padding: 4px 12px;
      cursor: pointer;
      font-size: var(--ui-fs);
    }

    .ctx-item:hover {
      background: var(--bg-tab-hover, #f0f0f0);
    }
  `;

  constructor() {
    super();
    /** @type {{path: string, name: string}[]} */
    this._tabs = [];
    this._activePath = "";
    this._unsubs = [];
    this._disposeEffect = null;
    this._disposeDirty = null;
    this._dirtyPaths = new Set();
    /** @type {{x: number, y: number, path: string}|null} */
    this._contextMenu = null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage("editor:open", (msg) => {
          const { path } = msg;
          if (!path) return;
          const name = basename(path);
          if (!this._tabs.find((t) => t.path === path)) {
            this._tabs = [...this._tabs, { path, name }];
          }
          this._activePath = path;
          this.requestUpdate();
        }),
      );

      const cell = getCell("current-file");
      this._disposeEffect = effect(() => {
        const val = cell.value;
        if (val) {
          this._activePath = val;
          this.requestUpdate();
        }
      });

      // Watch dirty-files cell for dirty indicators
      const dirtyCell = getCell("dirty-files");
      this._disposeDirty = effect(() => {
        this._dirtyPaths = new Set(dirtyCell.value || []);
        this.requestUpdate();
      });

      // Listen for tab:close from Racket (after dirty-check dialog)
      this._unsubs.push(
        onMessage('tab:close', (msg) => {
          const { path } = msg;
          this._tabs = this._tabs.filter(t => t.path !== path);
          if (this._activePath === path) {
            if (this._tabs.length > 0) {
              const newActive = this._tabs[this._tabs.length - 1].path;
              this._activePath = newActive;
              dispatch('tab:select', { path: newActive });
            } else {
              this._activePath = '';
              dispatch('tab:close-all');
            }
          }
          this.requestUpdate();
        })
      );
    }, 0);
  }

  updated() {
    this.toggleAttribute("hidden", this._tabs.length === 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const unsub of this._unsubs) unsub();
    this._unsubs = [];
    if (this._disposeEffect) {
      this._disposeEffect();
      this._disposeEffect = null;
    }
    if (this._disposeDirty) {
      this._disposeDirty();
      this._disposeDirty = null;
    }
  }

  _selectTab(path) {
    this._activePath = path;
    this.requestUpdate();
    dispatch("tab:select", { path });
  }

  _closeTab(e, path) {
    e.stopPropagation();
    dispatch('tab:close-request', { path });
  }

  _showContextMenu(e, path) {
    e.preventDefault();
    const rect = this.getBoundingClientRect();
    this._contextMenu = {
      x: e.clientX - rect.left,
      y: e.clientY - rect.top,
      path,
    };
    this.requestUpdate();

    // Close on next click anywhere
    const close = () => {
      this._contextMenu = null;
      this.requestUpdate();
      document.removeEventListener('click', close);
    };
    setTimeout(() => document.addEventListener('click', close), 0);
  }

  _contextClose() {
    dispatch('tab:close-request', { path: this._contextMenu.path });
    this._contextMenu = null;
  }

  _contextCloseOthers() {
    const keep = this._contextMenu.path;
    for (const tab of this._tabs) {
      if (tab.path !== keep) dispatch('tab:close-request', { path: tab.path });
    }
    this._contextMenu = null;
  }

  _contextCloseAll() {
    for (const tab of this._tabs) {
      dispatch('tab:close-request', { path: tab.path });
    }
    this._contextMenu = null;
  }

  _scrollTabs(direction) {
    const area = this.shadowRoot.querySelector('.tabs-area');
    if (area) area.scrollBy({ left: direction * 120, behavior: 'smooth' });
  }

  render() {
    return html`
      <div class="scroll-btn left" @click=${() => this._scrollTabs(-1)}>\u2039</div>
      <div class="tabs-area">
        ${this._tabs.map(
          (tab) => {
            const isDirty = this._dirtyPaths.has(tab.path);
            return html`
            <div
              class="tab ${tab.path === this._activePath ? "active" : ""}"
              @click=${() => this._selectTab(tab.path)}
              @auxclick=${(e) => { if (e.button === 1) { e.preventDefault(); dispatch('tab:close-request', { path: tab.path }); } }}
              @contextmenu=${(e) => this._showContextMenu(e, tab.path)}
            >
              <span class="tab-label">${isDirty ? '\u2022 ' : ''}${tab.name}</span>
              <span
                class="tab-close"
                @click=${(e) => this._closeTab(e, tab.path)}
              >
                <svg width="9" height="9" viewBox="0 0 12 12">
                  <path
                    d="M2 2l8 8M10 2l-8 8"
                    stroke="currentColor"
                    stroke-width="1.6"
                    stroke-linecap="round"
                  />
                </svg>
              </span>
            </div>
          `;
          },
        )}
      </div>
      <div class="scroll-btn right" @click=${() => this._scrollTabs(1)}>\u203A</div>
      ${this._contextMenu ? html`
        <div class="context-menu" style="left:${this._contextMenu.x}px;top:${this._contextMenu.y}px">
          <div class="ctx-item" @click=${() => this._contextClose()}>Close</div>
          <div class="ctx-item" @click=${() => this._contextCloseOthers()}>Close Others</div>
          <div class="ctx-item" @click=${() => this._contextCloseAll()}>Close All</div>
        </div>
      ` : ''}
    `;
  }
}

customElements.define("hm-tabs", HmTabs);
