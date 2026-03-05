// arrows.js — SVG overlay for Check Syntax binding arrows
//
// Draws Bezier curves between binding sites and references
// on a transparent SVG layer over the Monaco editor.
//
// Arrows are hidden by default. When the user hovers over a symbol
// that is at one end of an arrow, only the arrows connected to that
// symbol are shown (matching DrRacket's behavior).

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
    this._visibleArrows = [];
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

    // Show arrows on hover.
    // We intentionally do NOT use Monaco's onMouseLeave — WKWebView fires
    // spurious mouseLeave events when SVG paths render (even with the SVG
    // outside Monaco's DOM tree), and once mouseLeave fires, Monaco stops
    // sending mouseMove, so there's nothing to cancel the hide timer.
    // Instead, arrows clear naturally when onMouseMove reports a position
    // with no matching arrows.  If the mouse leaves the editor entirely,
    // arrows persist until the next hover — matching DrRacket's behavior.
    this._disposables.push(
      editor.onMouseMove((e) => this._onMouseMove(e))
    );

    // Listen for arrow updates from lang-intel
    onArrowsUpdated((uri, arrows) => {
      console.log(`[arrows] update received: ${arrows.length} arrows for ${uri}`);
      this._arrows = arrows;
      this._visibleArrows = [];
      this._render();
    });

    this._updateSize();
  }

  _createSvg(shadowRoot) {
    this._svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this._svg.classList.add('hm-arrow-overlay');
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

    // Place SVG directly in shadow root as a sibling of #editor-container,
    // NOT inside it.  This keeps the SVG entirely outside Monaco's DOM
    // tree, preventing WKWebView reflows (triggered by rendering SVG paths)
    // from firing Monaco's onMouseLeave — which was causing arrows to
    // disappear immediately after appearing.
    //
    // The :host element has position:relative, so the SVG's position:absolute
    // is relative to the host and overlays the editor container exactly.
    shadowRoot.appendChild(this._svg);
  }

  _updateSize() {
    const layout = this._editor.getLayoutInfo();
    this._svg.setAttribute('width', layout.width);
    this._svg.setAttribute('height', layout.height);
  }

  /**
   * Check if a position (line, column) falls within a range.
   * Ranges use Racket's 0-based columns; Monaco positions are 1-based.
   */
  _posInRange(line, col1based, range) {
    const col = col1based - 1; // convert to 0-based for range comparison
    if (line < range.startLine || line > range.endLine) return false;
    if (line === range.startLine && col < range.startCol) return false;
    if (line === range.endLine && col >= range.endCol) return false;
    return true;
  }

  /**
   * Find all arrows where the given position touches either endpoint.
   */
  _arrowsAtPosition(line, col) {
    return this._arrows.filter((arrow) =>
      this._posInRange(line, col, arrow.from) ||
      this._posInRange(line, col, arrow.to)
    );
  }

  _onMouseMove(e) {
    if (!e.target?.position) {
      // Mouse is over non-content area (scrollbar, margin, minimap).
      // Don't clear arrows — the user may still be near the symbol.
      return;
    }

    const { lineNumber, column } = e.target.position;
    const matched = this._arrowsAtPosition(lineNumber, column);

    if (matched.length > 0) {
      console.log(`[arrows] hover match: ${matched.length} arrows at L${lineNumber}:${column}, total arrows: ${this._arrows.length}`);
    }

    // Avoid re-rendering if the same arrows are already visible
    if (matched.length === this._visibleArrows.length &&
        matched.every((a, i) => a === this._visibleArrows[i])) {
      return;
    }

    this._visibleArrows = matched;
    this._render();
  }

  _render() {
    // Clear existing arrows
    const existing = this._svg.querySelectorAll('.hm-arrow');
    existing.forEach((el) => el.remove());

    // One-shot diagnostic: dump the stacking context the first time
    // we actually render visible arrows (editor must be on-screen).
    if (this._visibleArrows.length > 0 && !this._diagDone) {
      this._diagDone = true;
      let el = this._svg;
      const chain = [];
      while (el && chain.length < 12) {
        const cs = getComputedStyle(el);
        chain.push(
          `${el.tagName}${el.id ? '#'+el.id : ''}.${(el.className?.baseVal || el.className || '').substring(0,50).trim()}` +
          ` | pos=${cs.position} z=${cs.zIndex} overflow=${cs.overflow}` +
          ` opacity=${cs.opacity} contain=${cs.contain || 'none'} isolation=${cs.isolation}`
        );
        el = el.parentElement;
      }
      console.log('[arrows] STACKING CONTEXT:\n' + chain.join('\n'));
    }

    const layout = this._editor.getLayoutInfo();
    const svgW = this._svg.getAttribute('width');
    const svgH = this._svg.getAttribute('height');
    const parent = this._svg.parentNode;
    console.log(`[arrows] _render: ${this._visibleArrows.length} visible, svg=${svgW}x${svgH}, parent=${parent?.id || parent?.tagName || 'NONE'}, inDOM=${this._svg.isConnected}`);

    for (const arrow of this._visibleArrows) {
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
      if (!fromPos || !toPos) {
        console.log(`[arrows]   skipped (off-screen): from=${JSON.stringify(fromPos)}, to=${JSON.stringify(toPos)}`);
        continue;
      }

      // getScrolledVisiblePosition().left already includes the gutter
      // offset (glyphMarginWidth + lineNumbersWidth + decorationsWidth),
      // so we must NOT add layout.contentLeft — that double-counts.
      const x1 = fromPos.left;
      const y1 = fromPos.top + fromPos.height / 2;
      const x2 = toPos.left;
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
      console.log(`[arrows]   path: ${kind} (${x1.toFixed(0)},${y1.toFixed(0)})→(${x2.toFixed(0)},${y2.toFixed(0)}) d="${path.getAttribute('d')}"`);
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
