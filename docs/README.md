# Documentation

This directory contains the `sphinx-stack` documentation site for
sunbeam-workshop. The site is built and checked only - it is never
published.

## Build and check locally

Use the just recipes from the repository root. Each recipe calls the stack's
own Makefile targets, never custom commands:

- `just docs-build` - strict build: `make -C docs html SPHINXOPTS="-W"`
- `just docs-serve` - build and serve the site locally
- `just docs-check` - the full check battery: strict build, `spelling`,
  `linkcheck`, `woke`, `vale`, and `lint-md`

The same six Makefile targets run in CI as the `docs` workflow
(`.github/workflows/docs.yaml`), triggered by every change under `docs/` or
to the workflow itself.

## Accessibility check: `pa11y` is local-only

The `pa11y` accessibility check (WCAG 2.2 AA) is not part of CI. This
matches the stack's own design: its GitHub workflows do not run it. Run it
locally:

```sh
npm install pa11y && make -C docs pa11y
```

`npm` must be installed first. The Makefile installs `pa11y` into
`docs/_dev/` on first use and then checks every built HTML page.
