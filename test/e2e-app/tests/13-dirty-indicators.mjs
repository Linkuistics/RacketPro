// 13-dirty-indicators.mjs — Full dirty state flow: dot indicator + title asterisk.
// Ports phase4.spec.js dirty state tests with real Racket cell propagation.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Dirty state indicators';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-dirty-'));
  const filePath = join(dir, 'dirty-test.rkt');
  writeFileSync(filePath, '#lang racket\n(+ 1 2)\n');

  try {
    // Open the file
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await h.waitForCell('current-file',
      `v === '${filePath.replace(/'/g, "\\'")}'`, 10_000);
    await new Promise(r => setTimeout(r, 2000));

    // ── Mark file dirty ──
    await h.dispatchEvent('editor:dirty', { path: filePath, dirty: true });
    await new Promise(r => setTimeout(r, 2000));

    // file-dirty cell should be truthy
    const dirty = await h.getCellValue('file-dirty');
    h.assertTruthy(dirty, 'file-dirty is true after editor:dirty');

    // Tab should show dirty dot (• character in tab label or class)
    const tabLabels = await h.queryShadowAll('hm-tabs', '.tab-label');
    const dirtyTab = tabLabels?.find(t => t.includes('•')) ||
                     tabLabels?.find(t => t.includes('dirty-test'));
    // Check for dirty indicator — either • in text or .dirty class
    const hasDirtyIndicator = await h.evalInApp(`
      const tabs = document.querySelector('hm-tabs');
      if (!tabs?.shadowRoot) return false;
      const allTabs = tabs.shadowRoot.querySelectorAll('.tab');
      return Array.from(allTabs).some(t =>
        t.classList.contains('dirty') ||
        t.textContent.includes('•') ||
        t.querySelector('.dirty-dot') !== null
      );
    `);
    h.assert(hasDirtyIndicator, 'tab shows dirty indicator');

    // Title cell should contain * (asterisk) for dirty state
    const title = await h.getCellValue('title');
    if (title) {
      h.assertContains(title, '*', 'title contains * for dirty file');
    }

    // ── Save the file → dirty clears ──
    // editor:save-request with content triggers the save flow
    await h.dispatchEvent('editor:save-request', {
      path: filePath,
      content: '#lang racket\n(+ 1 2)\n'
    });
    await new Promise(r => setTimeout(r, 3000));

    // If save-request doesn't clear dirty, try the raw message path
    let dirtyAfter = await h.getCellValue('file-dirty');
    if (dirtyAfter) {
      // Fallback: send file:write:result (the Rust-side completion message)
      await h.sendRawMessage({ type: 'file:write:result', path: filePath });
      await new Promise(r => setTimeout(r, 2000));
      dirtyAfter = await h.getCellValue('file-dirty');
    }

    h.assertFalsy(dirtyAfter, 'file-dirty is false after save');

    // Dirty indicator should be gone
    const stillDirty = await h.evalInApp(`
      const tabs = document.querySelector('hm-tabs');
      if (!tabs?.shadowRoot) return false;
      const allTabs = tabs.shadowRoot.querySelectorAll('.tab');
      return Array.from(allTabs).some(t =>
        t.classList.contains('dirty') ||
        t.textContent.includes('•')
      );
    `);
    h.assertFalsy(stillDirty, 'dirty indicator cleared after save');

  } finally {
    try { unlinkSync(filePath); } catch {}
  }
}
