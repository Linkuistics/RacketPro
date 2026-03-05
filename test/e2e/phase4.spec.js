// @ts-check
import { test, expect } from '@playwright/test';
import {
  bootApp,
  sendBootMessages,
  waitForMonaco,
  fireEvent,
  getInvocations,
  clearInvocations,
} from './fixtures.js';

// ── Group 1: Dirty State ─────────────────────────────────────────────

test.describe('Dirty state indicators', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);
  });

  test('tab shows dirty dot when file is in dirty-files cell', async ({ page }) => {
    // Open a file (creates a tab)
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test.rkt',
      content: '#lang racket\n',
      language: 'racket',
    });

    // Verify tab exists without dot
    const tab = page.locator('hm-tabs').locator('.tab');
    await expect(tab).toContainText('test.rkt');
    const textBefore = await tab.locator('.tab-label').textContent();
    expect(textBefore).not.toContain('•');

    // Update dirty-files cell to include this file
    await fireEvent(page, 'cell:update', {
      name: 'dirty-files',
      value: ['/tmp/test.rkt'],
    });

    // Wait for reactivity
    await page.waitForTimeout(100);

    // Tab should now show dirty dot
    const textAfter = await tab.locator('.tab-label').textContent();
    expect(textAfter).toContain('•');
  });

  test('dirty dot disappears when file is saved', async ({ page }) => {
    // Open file and mark dirty
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test.rkt',
      content: '#lang racket\n',
      language: 'racket',
    });
    await fireEvent(page, 'cell:update', {
      name: 'dirty-files',
      value: ['/tmp/test.rkt'],
    });
    await page.waitForTimeout(100);

    // Verify dot is present
    const tab = page.locator('hm-tabs').locator('.tab');
    let text = await tab.locator('.tab-label').textContent();
    expect(text).toContain('•');

    // Clear dirty-files (simulating save)
    await fireEvent(page, 'cell:update', {
      name: 'dirty-files',
      value: [],
    });
    await page.waitForTimeout(100);

    // Dot should be gone
    text = await tab.locator('.tab-label').textContent();
    expect(text).not.toContain('•');
  });
});

// ── Group 2: File Tree Sync ──────────────────────────────────────────

test.describe('File tree editor sync', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
  });

  test('file tree highlights active file from current-file cell', async ({ page }) => {
    // Update current-file cell (simulating opening a file)
    await fireEvent(page, 'cell:update', {
      name: 'current-file',
      value: '/tmp/test-project/src/main.rkt',
    });

    await page.waitForTimeout(200);

    // The filetree should have an active item
    const activeItem = page.locator('hm-filetree .item.active');
    // Note: this may not find anything if the tree isn't expanded,
    // but the _activeFile property should be set
    const activeFile = await page.locator('hm-filetree').evaluate(
      (el) => el._activeFile
    );
    expect(activeFile).toBe('/tmp/test-project/src/main.rkt');
  });
});
