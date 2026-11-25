# Copyright 2026 Canonical Ltd. All rights reserved.
# Multi-forge repository management (GitHub, opendev/Gerrit, Launchpad).

# Clone or update the per-profile repository checkouts (guarded).
# Extra arguments pass through to the repo manager, e.g.
#   just repos packaging --filter 'neutron*'
#   just repos sunbeam --filter 'snap-*' --filter 'sunbeam*'
# set -f keeps glob patterns in --filter values literal instead of letting
# the shell expand them against the recipe's working directory.
repos profile="" *args: assert-host
    #!/bin/bash -e
    set -f
    profile="{{profile}}"
    cd "{{justfile_directory()}}/scripts"
    if [ -n "$profile" ]; then
        exec uv run --frozen python -m openstack_workshop repos apply "$profile" {{args}}
    fi
    exec uv run --frozen python -m openstack_workshop repos apply {{args}}
