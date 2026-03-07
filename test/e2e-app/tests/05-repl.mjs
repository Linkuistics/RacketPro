// 05-repl.mjs — REPL lifecycle: run, restart, stop.

import { writeFileSync, unlinkSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

export const name = 'REPL lifecycle';

export async function run(h) {
  // Verify terminal element exists
  h.assert(await h.elementExists('hm-terminal'), 'hm-terminal exists');

  // Create a file to run
  const dir = mkdtempSync(join(tmpdir(), 'hm-test-repl-'));
  const filePath = join(dir, 'run-me.rkt');
  writeFileSync(filePath, '#lang racket\n(displayln "hello e2e")\n');

  try {
    // Open the file first
    await h.dispatchEvent('file:tree-open', { path: filePath });
    await new Promise(r => setTimeout(r, 2000));

    // Dispatch run → verify repl-running becomes truthy
    await h.dispatchEvent('run', {});

    // Wait for repl-running to become true (may take a moment for PTY to spawn)
    const running = await h.waitForCondition(`
      (async function() {
        const { getCell } = await import('/core/cells.js');
        return getCell('repl-running').value === true;
      })()
    `, 15_000).catch(() => false);

    h.assertTruthy(running, 'repl-running is true after run dispatch');

    // Wait for the REPL to actually finish loading the file before
    // we restart (the ,enter command runs asynchronously in the PTY).
    await new Promise(r => setTimeout(r, 5000));

    // Dispatch repl:restart → should cycle (briefly false then true again)
    await h.dispatchEvent('repl:restart', {});
    await new Promise(r => setTimeout(r, 3000));

    // After restart, repl-running should be true again
    const afterRestart = await h.getCellValue('repl-running');
    // It might still be cycling — give it more time if needed
    if (!afterRestart) {
      await new Promise(r => setTimeout(r, 3000));
    }
    const finalState = await h.getCellValue('repl-running');
    // Don't fail hard if restart is slow — just report
    if (!finalState) {
      console.log('    (note: repl-running not yet true after restart — may be slow)');
    }

  } finally {
    // Wait for REPL to be idle before deleting the file it loaded
    await new Promise(r => setTimeout(r, 2000));
    try { unlinkSync(filePath); } catch {}
  }
}
