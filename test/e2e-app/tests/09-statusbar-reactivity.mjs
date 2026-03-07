// 09-statusbar-reactivity.mjs — Cell reactivity: status bar, language, cursor.
// Ports phase3.spec.js status bar + phase4.spec.js reactivity tests.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Statusbar cell reactivity';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-status-'));
  const filePath = join(dir, 'status-test.rkt');
  writeFileSync(filePath, '#lang racket\n(define x 42)\n(+ x 1)\n');

  try {
    // Open a Racket file → language cell should update
    await h.dispatchEvent('file:tree-open', { path: filePath });

    // Wait for file to load
    await h.waitForCell('current-file',
      `v === '${filePath.replace(/'/g, "\\'")}'`, 10_000);

    // Language cell should reflect "Racket"
    await new Promise(r => setTimeout(r, 2000));
    const lang = await h.getCellValue('language');
    h.assert(lang, 'language cell is set');
    h.assertContains(lang.toLowerCase(), 'racket', 'language cell shows racket');

    // Status cell should reflect file was opened
    const status = await h.getCellValue('status');
    h.assert(typeof status === 'string' && status.length > 0,
      'status cell has text after open');

    // Send editor:goto → verify Monaco cursor moves (cursor-pos cell
    // is not yet wired from frontend→Racket, so we check Monaco directly)
    await h.dispatchEvent('editor:goto', { line: 2, col: 5 });
    await new Promise(r => setTimeout(r, 2000));

    const pos = await h.getMonacoCursorPosition();
    h.assert(pos, 'Monaco cursor position returned after goto');
    h.assert(pos.lineNumber >= 2 && pos.lineNumber <= 3,
      `cursor moved near target line (got ${pos.lineNumber})`);

    // Verify statusbar renders the language (it's cell-reactive)
    const sbLanguage = await h.queryShadow('hm-statusbar', '.language');
    if (sbLanguage) {
      h.assertContains(sbLanguage.toLowerCase(), 'racket',
        'statusbar shows language name');
    }

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
