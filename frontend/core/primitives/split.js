// primitives/split.js — hm-split
//
// Resizable split pane component.  Divides its area into two panes with
// a draggable sash (VS Code-style).  Children are assigned to named
// slots "first" and "second" by the renderer.
//
// Properties:
//   direction  — "vertical" (top/bottom) or "horizontal" (left/right)
//   ratio      — 0.0–1.0 split position (default 0.5)
//   min-size   — minimum pane size in px (default 50)

import { LitElement, html, css } from 'lit';

class HmSplit extends LitElement {
  static properties = {
    direction: { type: String, reflect: true },
    ratio:     { type: Number },
    minSize:   { type: Number, attribute: 'min-size' },
  };

  static styles = css`
    :host {
      display: flex;
      width: 100%;
      height: 100%;
      overflow: hidden;
    }
    :host([direction='horizontal']) { flex-direction: row; }
    :host([direction='vertical'])   { flex-direction: column; }

    .pane {
      overflow: hidden;
      position: relative;
    }

    /* ── VS Code-style sash ─────────────────────────────── */
    .sash {
      flex-shrink: 0;
      position: relative;
      z-index: 10;
      background: transparent;
    }

    /* Thin border line at rest */
    .sash::before {
      content: '';
      position: absolute;
      transition: background 0.15s ease;
      background: var(--border, #E5E5E5);
    }

    /* On hover: reveal the colored bar */
    .sash:hover::before {
      background: var(--divider-hover, #007ACC);
    }

    /* Vertical split: horizontal sash */
    :host([direction='vertical']) .sash {
      height: 5px;
      cursor: row-resize;
      margin: -2px 0;
    }
    :host([direction='vertical']) .sash::before {
      left: 0;
      right: 0;
      top: 2px;
      height: 1px;
    }
    :host([direction='vertical']) .sash:hover::before {
      top: 1px;
      height: 3px;
    }

    /* Horizontal split: vertical sash */
    :host([direction='horizontal']) .sash {
      width: 5px;
      cursor: col-resize;
      margin: 0 -2px;
    }
    :host([direction='horizontal']) .sash::before {
      top: 0;
      bottom: 0;
      left: 2px;
      width: 1px;
    }
    :host([direction='horizontal']) .sash:hover::before {
      left: 1px;
      width: 3px;
    }

    /* During drag: keep sash highlighted */
    .sash.dragging::before {
      background: var(--divider-hover, #007ACC);
    }
    :host([direction='vertical']) .sash.dragging::before {
      top: 1px;
      height: 3px;
    }
    :host([direction='horizontal']) .sash.dragging::before {
      left: 1px;
      width: 3px;
    }
  `;

  constructor() {
    super();
    this.direction = 'vertical';
    this.ratio = 0.5;
    this.minSize = 50;
  }

  render() {
    const isVert = this.direction === 'vertical';
    const firstSize  = `${this.ratio * 100}%`;
    const secondSize = `${(1 - this.ratio) * 100}%`;
    const firstStyle  = isVert
      ? `height:${firstSize};width:100%`
      : `width:${firstSize};height:100%`;
    const secondStyle = isVert
      ? `height:${secondSize};width:100%`
      : `width:${secondSize};height:100%`;

    return html`
      <div class="pane" style="${firstStyle}"><slot name="first"></slot></div>
      <div class="sash" @mousedown=${this._startDrag}></div>
      <div class="pane" style="${secondStyle}"><slot name="second"></slot></div>
    `;
  }

  _startDrag(e) {
    e.preventDefault();
    const rect = this.getBoundingClientRect();
    const isVert = this.direction === 'vertical';
    const sash = this.shadowRoot.querySelector('.sash');
    sash?.classList.add('dragging');

    const onMove = (ev) => {
      const pos   = isVert ? ev.clientY - rect.top : ev.clientX - rect.left;
      const total = isVert ? rect.height : rect.width;
      const minRatio = this.minSize / total;
      this.ratio = Math.max(minRatio, Math.min(1 - minRatio, pos / total));
    };

    const onUp = () => {
      sash?.classList.remove('dragging');
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }
}

customElements.define('hm-split', HmSplit);
