// settings-panel.js — Visual settings editor
import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';
import { getKeymap, startRecording, cancelRecording } from '../keybindings.js';

export class HmSettingsPanel extends LitElement {
  static properties = {
    activeSection: { type: String },
    settings: { type: Object },
    themes: { type: Array },
    keybindings: { type: Object },
    recordingAction: { type: String },
    keybindingFilter: { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      height: 100%;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      font-family: var(--font-sans);
      font-size: 13px;
    }
    nav {
      width: 180px;
      border-right: 1px solid var(--border, #d4d4d4);
      background: var(--bg-secondary, #f3f3f3);
      padding: 12px 0;
    }
    nav button {
      display: block;
      width: 100%;
      padding: 6px 16px;
      border: none;
      background: transparent;
      color: var(--fg-primary, #333);
      text-align: left;
      cursor: pointer;
      font-size: 13px;
      font-family: var(--font-sans);
    }
    nav button:hover {
      background: var(--bg-sidebar-hover, #e8e8e8);
    }
    nav button.active {
      background: var(--bg-sidebar-active, #d6ebff);
      font-weight: 600;
    }
    .content {
      flex: 1;
      padding: 16px 24px;
      overflow-y: auto;
    }
    h2 {
      font-size: 18px;
      margin-bottom: 16px;
      font-weight: 600;
    }
    .setting-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 0;
      border-bottom: 1px solid var(--border, #d4d4d4);
    }
    .setting-label {
      font-weight: 500;
    }
    .setting-desc {
      font-size: 11px;
      color: var(--fg-muted, #999);
      margin-top: 2px;
    }
    select, input[type="number"], input[type="text"] {
      padding: 4px 8px;
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 3px;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      font-size: 13px;
      font-family: var(--font-sans);
    }
    .toggle {
      position: relative;
      width: 36px;
      height: 20px;
      background: var(--border, #d4d4d4);
      border-radius: 10px;
      cursor: pointer;
      transition: background 0.2s;
    }
    .toggle.on {
      background: var(--accent, #007acc);
    }
    .toggle::after {
      content: '';
      position: absolute;
      top: 2px;
      left: 2px;
      width: 16px;
      height: 16px;
      background: white;
      border-radius: 50%;
      transition: transform 0.2s;
    }
    .toggle.on::after {
      transform: translateX(16px);
    }
    /* Keybinding editor styles */
    .kb-filter {
      width: 100%;
      margin-bottom: 12px;
      padding: 6px 8px;
    }
    .kb-table {
      width: 100%;
      border-collapse: collapse;
    }
    .kb-table th {
      text-align: left;
      padding: 6px 8px;
      border-bottom: 2px solid var(--border, #d4d4d4);
      font-weight: 600;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
    }
    .kb-table td {
      padding: 4px 8px;
      border-bottom: 1px solid var(--border, #d4d4d4);
    }
    .kb-shortcut {
      cursor: pointer;
      padding: 2px 8px;
      border-radius: 3px;
      font-family: var(--font-mono);
      font-size: 12px;
      background: var(--bg-secondary, #f3f3f3);
      display: inline-block;
    }
    .kb-shortcut:hover {
      background: var(--bg-sidebar-hover, #e8e8e8);
    }
    .kb-shortcut.recording {
      background: var(--accent, #007acc);
      color: #fff;
      animation: pulse 1s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.7; }
    }
    .kb-reset {
      border: none;
      background: transparent;
      color: var(--fg-muted, #999);
      cursor: pointer;
      font-size: 11px;
    }
    .kb-reset:hover {
      color: var(--danger, #d32f2f);
    }
  `;

  constructor() {
    super();
    this.activeSection = 'appearance';
    this.settings = {};
    this.themes = ['Light', 'Dark'];
    this.keybindings = {};
    this.recordingAction = null;
    this.keybindingFilter = '';

    // Listen for settings updates
    onMessage('settings:current', (msg) => {
      this.settings = msg.settings || {};
    });
    // Listen for theme list
    onMessage('theme:list', (msg) => {
      this.themes = msg.themes || ['Light', 'Dark'];
    });
  }

  _setSection(section) {
    this.activeSection = section;
  }

  _changeSetting(key, subKey, value) {
    if (subKey) {
      dispatch('settings:change', { key, subKey, value });
    } else {
      dispatch('settings:change', { key, value });
    }
  }

  _changeTheme(e) {
    const theme = e.target.value;
    dispatch('theme:switch', { theme });
  }

  _startRecordKeybinding(action) {
    this.recordingAction = action;
    startRecording((shortcut) => {
      this.recordingAction = null;
      dispatch('keybinding:update', { action, shortcut });
    });
  }

  _cancelRecording() {
    this.recordingAction = null;
    cancelRecording();
  }

  _resetKeybinding(action) {
    dispatch('keybinding:reset', { action });
  }

  _renderAppearance() {
    const theme = this.settings.theme || 'Light';
    const editor = this.settings.editor || {};

    return html`
      <h2>Appearance</h2>
      <div class="setting-row">
        <div>
          <div class="setting-label">Theme</div>
          <div class="setting-desc">Choose your color theme</div>
        </div>
        <select @change=${this._changeTheme}>
          ${this.themes.map(t => html`
            <option value=${t} ?selected=${t === theme}>${t}</option>
          `)}
        </select>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Font Family</div>
          <div class="setting-desc">Editor font family</div>
        </div>
        <input type="text" .value=${editor.fontFamily || 'SF Mono'}
          @change=${(e) => this._changeSetting('editor', 'fontFamily', e.target.value)} />
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Font Size</div>
          <div class="setting-desc">Editor font size in pixels</div>
        </div>
        <input type="number" min="8" max="32" .value=${String(editor.fontSize || 13)}
          @change=${(e) => this._changeSetting('editor', 'fontSize', Number(e.target.value))} />
      </div>
    `;
  }

  _renderEditor() {
    const editor = this.settings.editor || {};

    return html`
      <h2>Editor</h2>
      <div class="setting-row">
        <div>
          <div class="setting-label">Vim Mode</div>
          <div class="setting-desc">Enable vim keybindings in the editor</div>
        </div>
        <div class="toggle ${editor.vimMode ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'vimMode', !editor.vimMode)}></div>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Tab Size</div>
        </div>
        <input type="number" min="1" max="8" .value=${String(editor.tabSize || 2)}
          @change=${(e) => this._changeSetting('editor', 'tabSize', Number(e.target.value))} />
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Word Wrap</div>
        </div>
        <div class="toggle ${editor.wordWrap ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'wordWrap', !editor.wordWrap)}></div>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Minimap</div>
        </div>
        <div class="toggle ${editor.minimap ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'minimap', !editor.minimap)}></div>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Line Numbers</div>
        </div>
        <div class="toggle ${editor.lineNumbers !== false ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'lineNumbers', !(editor.lineNumbers !== false))}></div>
      </div>
    `;
  }

  _renderKeybindings() {
    const km = getKeymap();
    const entries = [...km.entries()]
      .filter(([shortcut, action]) => {
        if (!this.keybindingFilter) return true;
        const filter = this.keybindingFilter.toLowerCase();
        return action.toLowerCase().includes(filter) ||
               shortcut.toLowerCase().includes(filter);
      })
      .sort((a, b) => a[1].localeCompare(b[1]));

    return html`
      <h2>Keybindings</h2>
      <input class="kb-filter" type="text" placeholder="Filter keybindings..."
        .value=${this.keybindingFilter}
        @input=${(e) => { this.keybindingFilter = e.target.value; }} />
      <table class="kb-table">
        <thead>
          <tr><th>Action</th><th>Shortcut</th><th></th></tr>
        </thead>
        <tbody>
          ${entries.map(([shortcut, action]) => html`
            <tr>
              <td>${action}</td>
              <td>
                <span class="kb-shortcut ${this.recordingAction === action ? 'recording' : ''}"
                  @click=${() => this.recordingAction === action
                    ? this._cancelRecording()
                    : this._startRecordKeybinding(action)}>
                  ${this.recordingAction === action ? 'Press keys...' : shortcut}
                </span>
              </td>
              <td>
                <button class="kb-reset" @click=${() => this._resetKeybinding(action)}
                  title="Reset to default">Reset</button>
              </td>
            </tr>
          `)}
        </tbody>
      </table>
    `;
  }

  render() {
    const sections = [
      { id: 'appearance', label: 'Appearance' },
      { id: 'editor', label: 'Editor' },
      { id: 'keybindings', label: 'Keybindings' },
    ];

    return html`
      <nav>
        ${sections.map(s => html`
          <button class=${s.id === this.activeSection ? 'active' : ''}
            @click=${() => this._setSection(s.id)}>${s.label}</button>
        `)}
      </nav>
      <div class="content">
        ${this.activeSection === 'appearance' ? this._renderAppearance() : ''}
        ${this.activeSection === 'editor' ? this._renderEditor() : ''}
        ${this.activeSection === 'keybindings' ? this._renderKeybindings() : ''}
      </div>
    `;
  }
}

customElements.define('hm-settings-panel', HmSettingsPanel);
