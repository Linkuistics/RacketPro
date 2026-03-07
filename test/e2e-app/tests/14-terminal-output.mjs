// 14-terminal-output.mjs — Real PTY/REPL output verification.
// ENTIRELY NEW: impossible with Playwright mocks — exercises real Racket REPL.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'Real terminal/REPL output';

export async function run(h) {
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-term-'));
  const filePath = join(dir, 'run-me.rkt');
  // Use a unique marker to identify output from our test
  const marker = `e2e-output-${Date.now()}`;
  writeFileSync(filePath, `#lang racket\n(displayln "${marker}")\n`);

  try {
    // Restart REPL first to get a clean terminal state
    // (previous tests may have left errors in the buffer)
    await h.dispatchEvent('repl:restart', {});
    await new Promise(r => setTimeout(r, 3000));

    // Open the file
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await h.waitForCell('current-file',
      `v === '${filePath.replace(/'/g, "\\'")}'`, 10_000);
    await new Promise(r => setTimeout(r, 2000));

    // Ensure file is NOT dirty so handle-run won't request a save first
    await h.sendRawMessage({ type: 'file:write:result', path: filePath });
    await new Promise(r => setTimeout(r, 1000));

    // Run the program.
    // After dispatching run, the eval facility can sometimes become
    // temporarily unresponsive while check-syntax and PTY output are
    // being processed concurrently. We use a resilient polling loop.
    await h.dispatchEvent('run', {});

    // Wait for output to appear in terminal buffer
    let termContent = '';
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 2000));
      try {
        termContent = await h.getTerminalContent();
        if (termContent && termContent.includes(marker)) break;
      } catch {
        // Eval facility temporarily busy — retry
      }
    }

    h.assert(termContent, 'terminal has content after run');
    h.assertContains(termContent, marker,
      `terminal output contains marker "${marker}"`);

  } finally {
    // Clean up REPL first (before deleting file, so REPL isn't mid-load)
    try { await h.dispatchEvent('repl:restart', {}); } catch {}
    await new Promise(r => setTimeout(r, 2000));
    try { unlinkSync(filePath); } catch {}
  }
}
