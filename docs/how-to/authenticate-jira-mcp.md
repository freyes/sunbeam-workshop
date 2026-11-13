(authenticate-jira-mcp)=

# Authenticate the Jira MCP server

Every profile seeds the Atlassian (Jira) MCP server into the opencode
configuration at provisioning time. What remains is the OAuth consent -
an interactive, human gate - which this guide walks through.

## What is already seeded

The `setup-project` provisioning hook merges the Atlassian server entry
into the global opencode configuration
(`~/.config/opencode/opencode.jsonc` inside the workshop), idempotently:

```json
{
  "mcp": {
    "servers": {
      "atlassian": { "type": "remote", "url": "https://mcp.atlassian.com/v2/mcp" }
    }
  }
}
```

You can confirm the seed at any time from inside the workshop:

```sh
opencode mcp list
```

The `atlassian` server appears in the list. If it does not, the
`setup-project` hook did not complete - check the instance's health with
`workshop info <name>` on the host and re-run `just setup <name>`.

## Prerequisites

- **Atlassian Cloud access** (<https://id.atlassian.com>) for the Jira site
  you want to query. Access is an entitlement, not something the workshop
  can provision.
- A browser on the host - the consent flow opens one.

## Run the OAuth consent

Inside the workshop (`just shell <name>`), start the authentication flow:

```sh
opencode mcp auth atlassian
```

opencode prints a consent URL to open in your browser and listens for the
OAuth callback on **localhost:19876**. That loopback endpoint reaches the
workshop through a tunnel: the rendered workshop definition declares a
system `mcp-oauth-callback` tunnel plug with endpoint `localhost:19876`,
connected to the opencode SDK's `opencode-mcp-oauth-callback` slot, so the
browser's redirect on your host is forwarded into the container.

Approve the consent in the browser. opencode receives the callback and
stores the resulting token in its data directory.

## Token persistence and re-authentication

The token persists in the opencode data directory, which lives on a mount -
so it survives container stops and restarts, and you do not need to repeat
the consent for an ordinary `just stop` / `workshop start` cycle.

After a workshop **refresh** or **restore**, re-check the server:
`opencode mcp list` shows whether the Atlassian server is still
authenticated. If it is not, re-run `opencode mcp auth atlassian`.

## Troubleshooting

**The browser shows the consent page but nothing reaches opencode.**
The callback travels through the tunnel connection. Verify it on the host:

```sh
workshop connections <name>
```

You should see `system:mcp-oauth-callback` connected to
`opencode:opencode-mcp-oauth-callback`. The connection is part of the
rendered definition, so a missing entry means the definition predates it -
re-render with `just render <name>` and relaunch.

**`opencode mcp list` does not show the `atlassian` server.**
The seed step merges the entry into `~/.config/opencode/opencode.jsonc`
during provisioning. A common cause is a hand-edited config that is no
longer parseable: the hook reports "not jq-parseable" and asks you to seed
the entry by hand. Fix the JSON, then re-add the entry shown above.

**The consent succeeds but Jira queries return nothing.**
That is an Atlassian-side authorization or site-access question, not a
workshop one - check that your Atlassian account can see the Jira site you
approved access for.
