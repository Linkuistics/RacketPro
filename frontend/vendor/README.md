# Vendored Frontend Dependencies

This directory contains vendored ES module bundles so MrRacket works fully
offline without CDN access.

## Contents

| Library | Version | File | Source |
|---------|---------|------|--------|
| Lit | 3.3.2 | `lit/lit-core.min.js` | [lit](https://www.npmjs.com/package/lit) |
| @preact/signals-core | 1.13.0 | `signals/signals-core.mjs` | [@preact/signals-core](https://www.npmjs.com/package/@preact/signals-core) |
| Monaco Editor | 0.55.1 | `monaco/monaco-editor.mjs` + `.css` | [monaco-editor](https://www.npmjs.com/package/monaco-editor) via [monaco-esm](https://www.npmjs.com/package/monaco-esm) 2.0.1 |
| @xterm/xterm | 6.0.0 | `xterm/xterm.mjs` + `.css` | [@xterm/xterm](https://www.npmjs.com/package/@xterm/xterm) |
| @xterm/addon-fit | 0.11.0 | `xterm/addon-fit.mjs` | [@xterm/addon-fit](https://www.npmjs.com/package/@xterm/addon-fit) |

## Lit Bundle Exports

The Lit bundle re-exports the following from `lit` and its directives:

- `LitElement`, `html`, `css`, `svg`, `nothing`, `noChange` from `lit`
- `classMap` from `lit/directives/class-map.js`
- `styleMap` from `lit/directives/style-map.js`
- `repeat` from `lit/directives/repeat.js`
- `when` from `lit/directives/when.js`

## Monaco Editor Bundle

The Monaco bundle is built from `monaco-esm` + `monaco-editor` using esbuild. It includes:

- Full Monaco Editor API (`monaco` namespace)
- `initMonaco()` and `loadCss()` from `monaco-esm`
- Editor worker (bundled inline)
- All basic language grammars (syntax highlighting for 80+ languages)
- Codicon font (base64-embedded in the CSS file)

The bundle does NOT include heavy language service workers (TypeScript, HTML, CSS, JSON).
These can be added later if needed by rebuilding with additional worker imports.

**Exports:** `monaco`, `initMonaco`, `loadCss`, `editorWorker`

**Import map entry:** `"monaco-editor"` maps to `./vendor/monaco/monaco-editor.mjs`

**CSS:** Load via `<link>` tag — the CSS file includes the codicon font as an inline data URL.
Do NOT rely on `loadCss()` for vendored usage (the embedded CSS references a relative TTF path
that does not exist in the vendor layout).

## xterm.js Bundle

Pre-built ESM modules copied directly from `@xterm/xterm` and `@xterm/addon-fit` npm packages.

- `xterm.mjs` — self-contained Terminal class, no external imports
- `addon-fit.mjs` — FitAddon for auto-sizing terminal to container
- `xterm.css` — terminal styles

**Import map entries:** `"@xterm/xterm"` and `"@xterm/addon-fit"`

## How to Update

### Lit

```bash
mkdir /tmp/lit-bundle && cd /tmp/lit-bundle
npm init -y
npm install lit@3
cat > bundle.js << 'JS'
export { LitElement, html, css, svg, nothing, noChange } from 'lit';
export { classMap } from 'lit/directives/class-map.js';
export { styleMap } from 'lit/directives/style-map.js';
export { repeat } from 'lit/directives/repeat.js';
export { when } from 'lit/directives/when.js';
JS
npx esbuild bundle.js --bundle --format=esm --minify --outfile=lit-core.min.js
cp lit-core.min.js /path/to/MrRacket/frontend/vendor/lit/
rm -rf /tmp/lit-bundle
```

### @preact/signals-core

```bash
cd /tmp && npm pack @preact/signals-core@1 --pack-destination .
tar xzf preact-signals-core-*.tgz
cp package/dist/signals-core.mjs /path/to/MrRacket/frontend/vendor/signals/
rm -rf /tmp/package /tmp/preact-signals-core-*.tgz
```

### Monaco Editor

```bash
mkdir /tmp/mr-monaco && cd /tmp/mr-monaco
npm init -y
npm install monaco-esm monaco-editor esbuild
cat > bundle-monaco.js << 'JS'
export { initMonaco, loadCss } from 'monaco-esm/core';
export { editorWorker } from 'monaco-esm/workers/editor';
export * as monaco from 'monaco-editor';
JS
npx esbuild bundle-monaco.js --bundle --format=esm --minify --target=es2022 \
  --loader:.ttf=dataurl --outfile=monaco-editor.mjs
cp monaco-editor.mjs /path/to/MrRacket/frontend/vendor/monaco/
cp monaco-editor.css /path/to/MrRacket/frontend/vendor/monaco/
rm -rf /tmp/mr-monaco
```

### @xterm/xterm and @xterm/addon-fit

```bash
cd /tmp && mkdir mr-xterm && cd mr-xterm
npm init -y
npm install @xterm/xterm @xterm/addon-fit
cp node_modules/@xterm/xterm/lib/xterm.mjs /path/to/MrRacket/frontend/vendor/xterm/
cp node_modules/@xterm/xterm/css/xterm.css /path/to/MrRacket/frontend/vendor/xterm/
cp node_modules/@xterm/addon-fit/lib/addon-fit.mjs /path/to/MrRacket/frontend/vendor/xterm/
rm -rf /tmp/mr-xterm
```

After updating, remember to update the version numbers in this README.
