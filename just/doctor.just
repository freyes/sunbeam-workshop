# Copyright 2026 Canonical Ltd. All rights reserved.
# Read-only host diagnostics.

# Check host prerequisites (read-only; safe to run anywhere)
doctor name="":
    #!/bin/bash -e
    name="{{name}}"
    if [ -n "$name" ]; then
        exec bash scripts/doctor.sh "$name"
    fi
    exec bash scripts/doctor.sh
