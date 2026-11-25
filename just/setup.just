# Copyright 2026 Canonical Ltd. All rights reserved.
# Workshop instance lifecycle: guided setup, render, CLI passthroughs, and
# the on-demand MCP OAuth callback tunnel wiring.

# Guided end-to-end setup of a named workshop instance (guarded)
setup name: assert-host
    exec bash scripts/setup.sh "{{name}}"

# Render .workshop/<name>.yaml from the profile template and merged vars
render name:
    exec bash scripts/render.sh "{{name}}"

# Launch a rendered workshop instance
launch name:
    exec workshop launch --verbose "{{name}}"

# Open an interactive shell in a running workshop instance
shell name:
    exec workshop shell "{{name}}"

# Stop a running workshop instance
stop name:
    exec workshop stop "{{name}}"

# Remove a workshop instance and its container (an unlaunched instance's
# rendered definition is removed too)
remove name:
    exec bash scripts/remove.sh "{{name}}"

# Connect the MCP OAuth callback tunnel plug to the opencode SDK slot on
# demand (the rendered definition deliberately does not auto-connect it)
connect name:
    exec bash scripts/oauth-tunnel.sh connect "{{name}}"

# Disconnect the MCP OAuth callback tunnel plug again
disconnect name:
    exec bash scripts/oauth-tunnel.sh disconnect "{{name}}"
