Commands:
- Run tests: `for f in test/test-*.rkt; do racket "$f"; done`
- Verify UI changes with `cargo tauri dev`

Constraints:
- Racket message types use colon-separated namespaces (cell:update, intel:diagnostics, etc.)
- Web Components are prefixed `hm-` in frontend/core/primitives/
- No build step — native ES modules with import map
- Tests are Racket-only (rackunit)
- Racket provides are explicit — every exported function must be in the provide list
- Title separator is em-dash, not hyphen
