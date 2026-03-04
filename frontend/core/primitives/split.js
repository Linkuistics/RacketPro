// primitives/split.js — mr-split
//
// Resizable split pane component.  Divides its area into two panes with
// a draggable divider.  Children are assigned to named slots "first" and
// "second" by the renderer.
//
// Properties:
//   direction  — "vertical" (top/bottom) or "horizontal" (left/right)
//   ratio      — 0.0–1.0 split position (default 0.5)
//   min-size   — minimum pane size in px (default 50)

import { LitElement, html, css } from 'lit';

class MrSplit extends LitElement {
  static properties = {
    direction: { type: String },
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
    .divider {
      flex-shrink: 0;
      background: var(--mr-divider-color, #e0e0e0);
      z-index: 10;
    }
    :host([direction='vertical']) .divider   { height: 4px; cursor: row-resize; }
    :host([direction='horizontal']) .divider { width: 4px; cursor: col-resize; }
    .divider:hover {
      background: var(--mr-divider-hover, #90caf9);
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
      <div class="divider" @mousedown=${this._startDrag}></div>
      <div class="pane" style="${secondStyle}"><slot name="second"></slot></div>
    `;
  }

  _startDrag(e) {
    e.preventDefault();
    const rect = this.getBoundingClientRect();
    const isVert = this.direction === 'vertical';

    const onMove = (ev) => {
      const pos   = isVert ? ev.clientY - rect.top : ev.clientX - rect.left;
      const total = isVert ? rect.height : rect.width;
      const minRatio = this.minSize / total;
      this.ratio = Math.max(minRatio, Math.min(1 - minRatio, pos / total));
    };

    const onUp = () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };

    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
  }
}

customElements.define('mr-split', MrSplit);
