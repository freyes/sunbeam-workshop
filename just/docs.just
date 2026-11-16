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

# Create a release note fragment for the current change (reno) and print
# its path; edit the file and commit it with the change it describes
note slug:
    make -C docs install
    docs/.venv/bin/reno new {{slug}}

# Print the accumulated release notes as RST, e.g. for announcements
notes:
    make -C docs install
    docs/.venv/bin/reno report
