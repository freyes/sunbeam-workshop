# Copyright 2026 Canonical Ltd. All rights reserved.
# Workshop instance lifecycle: guided setup, render, and CLI passthroughs.

# Guided end-to-end setup of a named workshop instance (guarded)
setup name: assert-host
    exec bash scripts/setup.sh "{{name}}"

# Render .workshop/<name>.yaml from the profile template and merged vars
render name:
    exec bash scripts/render.sh "{{name}}"

# Launch a rendered workshop instance
launch name:
    exec workshop launch "{{name}}"

# Open an interactive shell in a running workshop instance
shell name:
    exec workshop shell "{{name}}"

# Run one or more actions (merged from profile vars + user layers) in a
# running workshop instance: `just run <name> <action> [more-actions...]`
run name +actions:
    #!/usr/bin/env bash
    # Word splitting of the variadic action list is intended.
    # shellcheck disable=SC2086
    exec workshop run "{{name}}" {{actions}}

# Stop a running workshop instance
stop name:
    exec workshop stop "{{name}}"

# Remove a workshop instance and its container
remove name:
    exec workshop remove "{{name}}"

# Show the user-customization layers report for a workshop instance
# (read-only: applied layers, chain diff, actions, fragments, user SDKs,
# drift vs the persisted vars doc)
layers name:
    cd scripts && exec uv run --frozen python -m sunbeam_workshop layers "{{name}}"
