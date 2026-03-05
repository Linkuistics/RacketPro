// @ts-check
import { test, expect } from '@playwright/test';

/**
 * HeavyMental UI structure tests (Tier 2).
 *
 * These verify that the frontend HTML/JS loads correctly and
 * renders the expected Web Component structure. Without the Tauri
 * backend, the app won't receive Racket messages, so we only test
 * initial DOM structure and component registration.
 */

test.describe('App launch', () => {
  test('page loads with #app element', async ({ page }) => {
    await page.goto('/');
    const app = page.locator('#app');
    await expect(app).toBeVisible();
  });

  test('page title is HeavyMental', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('HeavyMental');
  });
});

test.describe('Layout structure', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    // Give modules time to load and register custom elements
    await page.waitForTimeout(2000);
  });

  test('hm-vbox element present', async ({ page }) => {
    const vbox = page.locator('hm-vbox');
    // Layout is rendered by Racket messages — without backend,
    // the renderer may not create these. Check if custom element is defined.
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-vbox') !== undefined
    );
    expect(isDefined).toBe(true);
  });

  test('hm-split element is defined', async ({ page }) => {
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-split') !== undefined
    );
    expect(isDefined).toBe(true);
  });

  test('hm-statusbar element is defined', async ({ page }) => {
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-statusbar') !== undefined
    );
    expect(isDefined).toBe(true);
  });
});

test.describe('Editor container', () => {
  test('hm-editor custom element is defined', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-editor') !== undefined
    );
    expect(isDefined).toBe(true);
  });
});

test.describe('Terminal container', () => {
  test('hm-terminal custom element is defined', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-terminal') !== undefined
    );
    expect(isDefined).toBe(true);
  });
});

test.describe('File tree', () => {
  test('hm-filetree custom element is defined', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-filetree') !== undefined
    );
    expect(isDefined).toBe(true);
  });
});

test.describe('Tab bar', () => {
  test('hm-tabs custom element is defined', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-tabs') !== undefined
    );
    expect(isDefined).toBe(true);
  });
});

test.describe('Status bar', () => {
  test('hm-statusbar custom element is defined', async ({ page }) => {
    await page.goto('/');
    await page.waitForTimeout(2000);
    const isDefined = await page.evaluate(() =>
      customElements.get('hm-statusbar') !== undefined
    );
    expect(isDefined).toBe(true);
  });
});
