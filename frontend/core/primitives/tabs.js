// primitives/tabs.js — hm-tabs
//
// Zed-style tab bar. Always shows ← → navigation arrows on the left.
// Active tab blends into the editor (white bg). Tab titles are centered.
// Close button appears on hover at the far right of each tab.
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
      font-size: 14px;
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
    this._tabs = this._tabs.filter((t) => t.path !== path);
    if (this._activePath === path) {
      if (this._tabs.length > 0) {
        const newActive = this._tabs[this._tabs.length - 1].path;
        this._activePath = newActive;
        dispatch("tab:select", { path: newActive });
      } else {
        this._activePath = "";
        dispatch("tab:close-all");
      }
    }
    this.requestUpdate();
  }

  render() {
    return html`
      <div class="tabs-area">
        ${this._tabs.map(
          (tab) => {
            const isDirty = this._dirtyPaths.has(tab.path);
            return html`
            <div
              class="tab ${tab.path === this._activePath ? "active" : ""}"
              @click=${() => this._selectTab(tab.path)}
            >
              <span class="tab-label">${isDirty ? '• ' : ''}${tab.name}</span>
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
    `;
  }
}

customElements.define("hm-tabs", HmTabs);
