# Copyright 2026 Canonical Ltd. All rights reserved.
# Credentials: host keyring storage plus per-instance secret-plug wiring.

# Store the GitHub token and OpenRouter key in the host keyring and wire their secret plugs (guarded)
secret-setup name="": assert-host
    #!/bin/bash -e
    name="{{name}}"
    if [ -n "$name" ]; then
        exec bash scripts/secret-setup.sh "$name"
    fi
    exec bash scripts/secret-setup.sh
