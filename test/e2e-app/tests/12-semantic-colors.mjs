// 12-semantic-colors.mjs — Semantic highlighting via real check-syntax.
// Verifies intel:colors → Monaco hm-cs-* inline decorations.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Semantic highlighting colors';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-colors-'));
  const filePath = join(dir, 'colors-test.rkt');
  // File with bindings that check-syntax will categorize
  writeFileSync(filePath,
    '#lang racket\n(define x 42)\n(define y (+ x 1))\n(displayln y)\n');

  try {
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await h.waitForCell('current-file',
      `v === '${filePath.replace(/'/g, "\\'")}'`, 10_000);

    // Wait for intel:colors to arrive and Monaco to apply decorations.
    // check-syntax must complete → colors message → editor applies decorations.
    let decorations = [];
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 1000));
      decorations = await h.getMonacoDecorations('hm-cs');
      if (decorations.length > 0) break;
    }

    h.assert(decorations.length > 0,
      `Monaco has hm-cs-* decorations (got ${decorations.length})`);

    // Verify at least one decoration has a recognizable class
    const classNames = decorations.map(d => d.className).filter(Boolean);
    h.assert(classNames.length > 0, 'decorations have inlineClassName values');

    // hm-cs- classes typically include: hm-cs-lexically-bound, hm-cs-imported, etc.
    const hasKnownClass = classNames.some(c =>
      c.includes('hm-cs-lexically-bound') ||
      c.includes('hm-cs-imported') ||
      c.includes('hm-cs-free')
    );
    // Soft check — classes may vary by Racket version
    if (!hasKnownClass) {
      console.log(`  note: no standard hm-cs class found; classes: ${classNames.slice(0, 5).join(', ')}`);
    }

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
