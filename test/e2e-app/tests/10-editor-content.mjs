// 10-editor-content.mjs — Editor content, language, and goto verification.
// Full roundtrip: Rust reads file → Racket processes → frontend displays.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Editor content and navigation';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-content-'));
  const filePath = join(dir, 'content-test.rkt');
  const content = '#lang racket\n(define greeting "hello")\n(displayln greeting)\n';
  writeFileSync(filePath, content);

  try {
    // Open the file
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await h.waitForCell('current-file',
      `v === '${filePath.replace(/'/g, "\\'")}'`, 10_000);

    // Wait for Monaco to receive content
    await new Promise(r => setTimeout(r, 2000));

    // Verify Monaco has the correct content (full roundtrip test)
    const editorContent = await h.getMonacoValue();
    h.assert(editorContent, 'editor has content');
    h.assertContains(editorContent, '#lang racket', 'editor contains #lang racket');
    h.assertContains(editorContent, 'define greeting', 'editor contains define greeting');
    h.assertContains(editorContent, 'displayln greeting', 'editor contains displayln');

    // Verify Monaco language is "racket"
    const lang = await h.getMonacoLanguage();
    h.assertEqual(lang, 'racket', 'Monaco language is racket');

    // Verify .monaco-editor container exists in shadow DOM
    const monacoExists = await h.evalInApp(`
      const ed = document.querySelector('hm-editor');
      return ed?.shadowRoot?.querySelector('.monaco-editor') !== null;
    `);
    h.assert(monacoExists, '.monaco-editor container exists in shadow DOM');

    // Send editor:goto and verify cursor moved
    await h.dispatchEvent('editor:goto', { line: 3, col: 1 });
    await new Promise(r => setTimeout(r, 1500));

    const pos = await h.getMonacoCursorPosition();
    h.assert(pos, 'cursor position returned');
    // Monaco is 1-based; Racket sends 0-based line, editor.js converts
    // The goto should place cursor on or near line 3
    h.assert(pos.lineNumber >= 2 && pos.lineNumber <= 4,
      `cursor line is near target (got ${pos.lineNumber})`);

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
