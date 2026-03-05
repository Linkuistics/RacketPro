// @ts-check
import { defineConfig } from '@playwright/test';

/**
 * Playwright config for HeavyMental UI tests.
 *
 * These tests verify DOM structure and component rendering.
 * They run against the frontend served by a static HTTP server
 * (the frontend is plain HTML/JS with no build step).
 *
 * Usage:
 *   cd test/e2e
 *   npm install
 *   npx playwright test
 *
 * The tests will automatically start a local server on port 3333
 * serving the frontend/ directory.
 */
export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.js',
  timeout: 30_000,
  retries: 0,
  use: {
    baseURL: 'http://localhost:3333',
    // No real Tauri backend — frontend handles missing APIs gracefully
    headless: true,
  },
  webServer: {
    command: 'npx serve ../../frontend -l 3333 --no-clipboard',
    port: 3333,
    reuseExistingServer: true,
    timeout: 10_000,
  },
  projects: [
    {
      name: 'chromium',
      use: { browserName: 'chromium' },
    },
  ],
});
