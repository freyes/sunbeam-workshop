# Copyright 2026 Canonical Ltd. All rights reserved.
# Documentation site (sphinx-stack; build and check only, never published).

# Build the docs site (strict: warnings are errors)
docs-build:
    make -C docs html SPHINXOPTS="-W"

# Build and serve the docs site locally
docs-serve:
    make -C docs run

# Run the full docs check battery (build, spelling, links, style)
docs-check:
    make -C docs html SPHINXOPTS="-W"
    make -C docs spelling
    make -C docs linkcheck
    make -C docs woke
    make -C docs vale
