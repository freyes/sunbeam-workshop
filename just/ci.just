# Copyright 2026 Canonical Ltd. All rights reserved.
# Local twins of the GitHub Actions lint and test workflows.

# Lint shell scripts, just recipes, workflows, and config
lint:
    exec bash scripts/lint.sh

# Run every bash and python test suite
test:
    exec bash scripts/tests/run.sh
