// 03-editor.mjs — Editor open file, dirty state, save clears dirty.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Editor open + dirty state';

export async function run(h) {
  // Create a temp Racket file
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-'));
  const filePath = join(dir, 'test-edit.rkt');
  writeFileSync(filePath, '#lang racket\n(+ 1 2)\n');

  try {
    // Dispatch editor:open to open the file
    await h.dispatchEvent('file:tree-open', { path: filePath });

    // Wait for current-file cell to match
    await h.waitForCondition(`
      (async function() {
        const { getCell } = await import('/core/cells.js');
        return getCell('current-file').value === '${filePath.replace(/'/g, "\\'")}';
      })()
    `, 10_000);

    const currentFile = await h.getCellValue('current-file');
    h.assertEqual(currentFile, filePath, 'current-file matches opened file');

    // Dispatch editor:dirty → verify file-dirty becomes truthy
    await h.dispatchEvent('editor:dirty', { path: filePath, dirty: true });

    // Give Racket time to process and update the cell
    await new Promise(r => setTimeout(r, 2000));

    const dirty = await h.getCellValue('file-dirty');
    h.assertTruthy(dirty, 'file-dirty is true after editor:dirty');

    // Simulate save result → dirty should clear
    // file:write:result is a top-level message type, not an event
    await h.sendRawMessage({ type: 'file:write:result', path: filePath });

    await new Promise(r => setTimeout(r, 2000));

    const dirtyAfter = await h.getCellValue('file-dirty');
    h.assertFalsy(dirtyAfter, 'file-dirty is false after save');

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
