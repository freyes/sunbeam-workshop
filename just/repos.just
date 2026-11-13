# Copyright 2026 Canonical Ltd. All rights reserved.
# Multi-forge repository management (GitHub, opendev/Gerrit, Launchpad).

# Clone or update the per-profile repository checkouts (guarded)
repos profile="": assert-host
    #!/bin/bash -e
    profile="{{profile}}"
    cd "{{justfile_directory()}}/scripts"
    if [ -n "$profile" ]; then
        exec uv run --frozen python -m sunbeam_workshop repos apply "$profile"
    fi
    exec uv run --frozen python -m sunbeam_workshop repos apply
