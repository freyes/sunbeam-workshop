# Copyright 2026 Canonical Ltd. All rights reserved.
# Optional sunbeam sidecar LXD VM for heavy builds and deployment testing.

# Create the sidecar dev VM (guarded)
vm-create: assert-host
    exec bash scripts/vm/create.sh

# Destroy the sidecar dev VM (guarded; .state preserved unless PURGE=1)
vm-destroy: assert-host
    exec bash scripts/vm/destroy.sh

# Open an ssh shell on the sidecar dev VM
vm-shell:
    exec bash scripts/vm/shell.sh
