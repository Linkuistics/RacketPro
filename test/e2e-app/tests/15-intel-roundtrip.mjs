// 15-intel-roundtrip.mjs — Full language intelligence roundtrip.
// ENTIRELY NEW: real check-syntax → arrows, hovers, colors in one test.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Language intelligence full roundtrip';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-intel-'));
  const filePath = join(dir, 'intel-test.rkt');
  // File with define + usage → check-syntax should produce arrows, hovers, colors
  writeFileSync(filePath,
    '#lang racket\n(define x 42)\n(define y (+ x 1))\n(displayln y)\n');

  try {
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await h.waitForCell('current-file',
      `v === '${filePath.replace(/'/g, "\\'")}'`, 10_000);

    // Wait for intel data to arrive. We check arrows cache as the signal
    // that check-syntax has completed and results are cached.
    let arrows = [];
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 1000));
      arrows = await h.evalInApp(`
        const { getArrows } = await import('/core/lang-intel.js');
        const arr = getArrows('${filePath.replace(/'/g, "\\'")}');
        return JSON.parse(JSON.stringify(arr));
      `);
      if (arrows && arrows.length > 0) break;
    }

    h.assert(arrows.length > 0,
      `arrows cache has entries (got ${arrows.length})`);

    // Verify at least one binding arrow (from define x to use of x)
    const bindingArrow = arrows.find(a =>
      a.kind === 'binding' || a.kind === 'lexical'
    );
    // Soft check: arrow kind names may vary
    if (bindingArrow) {
      h.assert(bindingArrow.from, 'binding arrow has "from" range');
      h.assert(bindingArrow.to, 'binding arrow has "to" range');
    } else {
      console.log(`  note: no "binding" kind arrow; kinds: ${[...new Set(arrows.map(a => a.kind))].join(', ')}`);
    }

    // Verify hovers data exists for identifiers
    const hovers = await h.evalInApp(`
      const { getHovers } = await import('/core/lang-intel.js');
      const hvs = getHovers('${filePath.replace(/'/g, "\\'")}');
      return JSON.parse(JSON.stringify(hvs));
    `);
    h.assert(hovers.length > 0,
      `hovers cache has entries (got ${hovers.length})`);

    // Verify colors (semantic decorations) exist
    const decorations = await h.getMonacoDecorations('hm-cs');
    h.assert(decorations.length > 0,
      `semantic color decorations present (got ${decorations.length})`);

    // Verify definitions data (for go-to-definition)
    const defs = await h.evalInApp(`
      const { getDefinitions } = await import('/core/lang-intel.js');
      const d = getDefinitions('${filePath.replace(/'/g, "\\'")}');
      return JSON.parse(JSON.stringify(d));
    `);
    // definitions has {defs: [], jumps: []}
    h.assert(defs, 'definitions data exists');
    const totalDefs = (defs.defs?.length || 0) + (defs.jumps?.length || 0);
    h.assert(totalDefs > 0,
      `definitions cache has entries (defs=${defs.defs?.length}, jumps=${defs.jumps?.length})`);

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
