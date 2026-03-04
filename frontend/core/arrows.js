// arrows.js — SVG overlay for Check Syntax binding arrows
//
// Draws Bezier curves between binding sites and references
// on a transparent SVG layer over the Monaco editor.

import { onArrowsUpdated, getArrows } from './lang-intel.js';

const ARROW_COLORS = {
  binding: '#4488ff',
  require: '#44aa44',
  tail: '#aa44ff',
};

export class ArrowOverlay {
  constructor(editor, monaco, shadowRoot) {
    this._editor = editor;
    this._monaco = monaco;
    this._arrows = [];
    this._svg = null;
    this._disposables = [];

    this._createSvg(shadowRoot);

    // Re-render on scroll and layout changes
    this._disposables.push(
      editor.onDidScrollChange(() => this._render())
    );
    this._disposables.push(
      editor.onDidLayoutChange(() => {
        this._updateSize();
        this._render();
      })
    );

    // Listen for arrow updates from lang-intel
    onArrowsUpdated((uri, arrows) => {
      this._arrows = arrows;
      this._render();
    });

    this._updateSize();
  }

  _createSvg(shadowRoot) {
    this._svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this._svg.style.position = 'absolute';
    this._svg.style.top = '0';
    this._svg.style.left = '0';
    this._svg.style.pointerEvents = 'none';
    this._svg.style.zIndex = '10';
    this._svg.style.overflow = 'visible';

    // Arrowhead markers
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    for (const [kind, color] of Object.entries(ARROW_COLORS)) {
      const marker = document.createElementNS('http://www.w3.org/2000/svg', 'marker');
      marker.setAttribute('id', `hm-arrow-${kind}`);
      marker.setAttribute('markerWidth', '8');
      marker.setAttribute('markerHeight', '6');
      marker.setAttribute('refX', '8');
      marker.setAttribute('refY', '3');
      marker.setAttribute('orient', 'auto');
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', '0 0, 8 3, 0 6');
      polygon.setAttribute('fill', color);
      marker.appendChild(polygon);
      defs.appendChild(marker);
    }
    this._svg.appendChild(defs);

    // Insert SVG into the editor's container within the shadow root
    const editorContainer = shadowRoot.getElementById('editor-container');
    if (editorContainer) {
      editorContainer.style.position = 'relative';
      editorContainer.appendChild(this._svg);
    }
  }

  _updateSize() {
    const layout = this._editor.getLayoutInfo();
    this._svg.setAttribute('width', layout.width);
    this._svg.setAttribute('height', layout.height);
  }

  _render() {
    // Clear existing arrows
    const existing = this._svg.querySelectorAll('.hm-arrow');
    existing.forEach((el) => el.remove());

    const layout = this._editor.getLayoutInfo();

    for (const arrow of this._arrows) {
      const fromRange = arrow.from;
      const toRange = arrow.to;
      const kind = arrow.kind || 'binding';
      const color = ARROW_COLORS[kind] || ARROW_COLORS.binding;

      // Get pixel positions for arrow endpoints
      const fromPos = this._editor.getScrolledVisiblePosition({
        lineNumber: fromRange.startLine,
        column: fromRange.startCol + 1,
      });
      const toPos = this._editor.getScrolledVisiblePosition({
        lineNumber: toRange.startLine,
        column: toRange.startCol + 1,
      });

      // Skip if either endpoint is off-screen
      if (!fromPos || !toPos) continue;

      const x1 = fromPos.left + layout.contentLeft;
      const y1 = fromPos.top + fromPos.height / 2;
      const x2 = toPos.left + layout.contentLeft;
      const y2 = toPos.top + toPos.height / 2;

      // Bezier curve (arches above for same-line, to the side for multi-line)
      const dy = Math.abs(y2 - y1);
      const curveOffset = dy < 5 ? -30 : -Math.min(dy * 0.3, 50);
      const midX = (x1 + x2) / 2;
      const midY = Math.min(y1, y2) + curveOffset;

      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', `M ${x1} ${y1} Q ${midX} ${midY} ${x2} ${y2}`);
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke', color);
      path.setAttribute('stroke-width', '1.5');
      path.setAttribute('opacity', '0.6');
      path.setAttribute('marker-end', `url(#hm-arrow-${kind})`);
      path.setAttribute('class', 'hm-arrow');

      if (kind === 'tail') {
        path.setAttribute('stroke-dasharray', '4 2');
      }

      this._svg.appendChild(path);
    }
  }

  dispose() {
    for (const d of this._disposables) d.dispose();
    this._disposables = [];
    if (this._svg && this._svg.parentNode) {
      this._svg.parentNode.removeChild(this._svg);
    }
  }
}
