# Vendored Frontend Dependencies

This directory contains vendored ES module bundles so MrRacket works fully
offline without CDN access.

## Contents

| Library | Version | File | Source |
|---------|---------|------|--------|
| Lit | 3.3.2 | `lit/lit-core.min.js` | [lit](https://www.npmjs.com/package/lit) |
| @preact/signals-core | 1.13.0 | `signals/signals-core.mjs` | [@preact/signals-core](https://www.npmjs.com/package/@preact/signals-core) |

## Lit Bundle Exports

The Lit bundle re-exports the following from `lit` and its directives:

- `LitElement`, `html`, `css`, `svg`, `nothing`, `noChange` from `lit`
- `classMap` from `lit/directives/class-map.js`
- `styleMap` from `lit/directives/style-map.js`
- `repeat` from `lit/directives/repeat.js`
- `when` from `lit/directives/when.js`

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

After updating, remember to update the version numbers in this README.
