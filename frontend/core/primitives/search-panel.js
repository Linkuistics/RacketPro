// search-panel.js — Find-in-project search results panel
import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';

export class HmSearchPanel extends LitElement {
  static properties = {
    results: { type: Array },
    query: { type: String },
    searching: { type: Boolean },
    truncated: { type: Boolean },
    useRegex: { type: Boolean },
    caseSensitive: { type: Boolean },
  };

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      height: 100%;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      font-family: var(--font-sans);
      font-size: var(--ui-fs);
    }
    .search-bar {
      display: flex;
      gap: 4px;
      padding: 6px 8px;
      border-bottom: 1px solid var(--border, #d4d4d4);
      background: var(--bg-toolbar, #f8f8f8);
      align-items: center;
    }
    .search-bar input {
      flex: 1;
      padding: 3px 6px;
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 3px;
      font-family: var(--font-mono);
      font-size: var(--ui-fs-md);
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      outline: none;
    }
    .search-bar input:focus {
      border-color: var(--accent, #007acc);
    }
    .search-bar button {
      padding: 2px 6px;
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 3px;
      background: var(--bg-primary, #fff);
      color: var(--fg-secondary, #616161);
      cursor: pointer;
      font-size: var(--ui-fs-sm);
    }
    .search-bar button.active {
      background: var(--accent, #007acc);
      color: #fff;
      border-color: var(--accent, #007acc);
    }
    .results {
      flex: 1;
      overflow-y: auto;
      padding: 0;
    }
    .file-group {
      margin: 0;
    }
    .file-header {
      padding: 3px 8px;
      font-weight: 600;
      font-size: var(--ui-fs-md);
      color: var(--fg-secondary, #616161);
      background: var(--bg-secondary, #f3f3f3);
      border-bottom: 1px solid var(--border, #d4d4d4);
      cursor: default;
    }
    .match-row {
      display: flex;
      gap: 8px;
      padding: 2px 8px 2px 20px;
      cursor: pointer;
      border-bottom: 1px solid transparent;
    }
    .match-row:hover {
      background: var(--bg-sidebar-hover, #e8e8e8);
    }
    .line-num {
      color: var(--fg-muted, #999);
      min-width: 40px;
      text-align: right;
      font-family: var(--font-mono);
      font-size: var(--ui-fs-md);
    }
    .match-text {
      font-family: var(--font-mono);
      font-size: var(--ui-fs-md);
      white-space: pre;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .status {
      padding: 4px 8px;
      font-size: var(--ui-fs-sm);
      color: var(--fg-muted, #999);
      border-top: 1px solid var(--border, #d4d4d4);
    }
    .empty {
      padding: 20px;
      text-align: center;
      color: var(--fg-muted, #999);
    }
  `;

  constructor() {
    super();
    this.results = [];
    this.query = '';
    this.searching = false;
    this.truncated = false;
    this.useRegex = false;
    this.caseSensitive = false;

    onMessage('project:search:results', (msg) => {
      this.results = msg.results || [];
      this.truncated = msg.truncated || false;
      this.searching = false;
    });

    // Focus the search input when requested
    onMessage('project:search-focus', () => {
      this._focusInput();
    });
  }

  _focusInput() {
    requestAnimationFrame(() => {
      const input = this.shadowRoot?.querySelector('input');
      if (input) input.focus();
    });
  }

  _onKeyDown(e) {
    if (e.key === 'Enter') {
      this._doSearch();
    }
  }

  _onInput(e) {
    this.query = e.target.value;
  }

  _doSearch() {
    if (!this.query.trim()) return;
    this.searching = true;
    this.results = [];
    dispatch('project:search', {
      query: this.query,
      regex: this.useRegex,
      caseSensitive: this.caseSensitive,
    });
  }

  _toggleRegex() {
    this.useRegex = !this.useRegex;
  }

  _toggleCase() {
    this.caseSensitive = !this.caseSensitive;
  }

  _gotoResult(result) {
    dispatch('editor:goto-file', {
      path: result.file,
      line: result.line,
      col: result.col,
    });
  }

  _groupByFile() {
    const groups = new Map();
    for (const r of this.results) {
      if (!groups.has(r.file)) groups.set(r.file, []);
      groups.get(r.file).push(r);
    }
    return groups;
  }

  render() {
    const groups = this._groupByFile();

    return html`
      <div class="search-bar">
        <input
          type="text"
          placeholder="Search in project..."
          .value=${this.query}
          @input=${this._onInput}
          @keydown=${this._onKeyDown}
        />
        <button
          class=${this.useRegex ? 'active' : ''}
          @click=${this._toggleRegex}
          title="Use Regular Expression"
        >.*</button>
        <button
          class=${this.caseSensitive ? 'active' : ''}
          @click=${this._toggleCase}
          title="Match Case"
        >Aa</button>
      </div>
      <div class="results">
        ${this.searching ? html`<div class="empty">Searching...</div>` : ''}
        ${!this.searching && this.results.length === 0 && this.query
          ? html`<div class="empty">No results found</div>`
          : ''}
        ${[...groups.entries()].map(([file, matches]) => html`
          <div class="file-group">
            <div class="file-header">${file.split('/').pop()} — ${file}</div>
            ${matches.map(m => html`
              <div class="match-row" @click=${() => this._gotoResult(m)}>
                <span class="line-num">${m.line}</span>
                <span class="match-text">${m.text}</span>
              </div>
            `)}
          </div>
        `)}
      </div>
      ${this.results.length > 0 ? html`
        <div class="status">
          ${this.results.length} results${this.truncated ? ' (truncated)' : ''}
        </div>
      ` : ''}
    `;
  }
}

customElements.define('hm-search-panel', HmSearchPanel);
