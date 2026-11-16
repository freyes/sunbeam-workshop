(remove-a-sdk-locally)=

# Remove an SDK locally

This guide removes an SDK from a workshop instance's chain through a user
vars layer, without editing the tracked profile definition. Removal is
deliberately narrow: only profile `extra_sdks` entries and SDKs you added
yourself can be removed; the shared base chain is protected.

## Prerequisites

- A host checkout of this repository, and the workshop name (`sunbeam`,
  `charmed`, `packaging`, or a suffixed instance such as `packaging-foo`).
- The exact SDK name as it appears in the chain - `just layers <name>`
  shows the effective chain diff.

## Choose the scope

`sdks.remove` entries from every applicable layer are unioned, in the same
scope order as every other user vars key (`all`, then profile, then
instance):

| Layer file | Applies to | Use it when |
| --- | --- | --- |
| `config/local/vars/all.yaml` | Every workshop rendered from this checkout | Remove the SDK everywhere |
| `config/local/vars/profile/<profile>.yaml` | Every instance of one profile | Remove the SDK for that profile's instances |
| `config/local/vars/instance/<name>.yaml` | Exactly one named instance | Remove the SDK from one workshop only |

Each slot may be `.json` or `.yaml`, never both - the loader fails the
render naming both paths when they coexist.

## Remove the SDK

Drop `orange-dev-tools` from a single packaging instance:

```yaml
# config/local/vars/instance/packaging-foo.yaml
sdks:
  remove:
    - orange-dev-tools
```

The same layer as JSON (`config/local/vars/instance/packaging-foo.json`):

```json
{
  "sdks": {
    "remove": ["orange-dev-tools"]
  }
}
```

## What can and cannot be removed

Removable names are exactly:

- the profile's `extra_sdks` entries (for packaging, `orange-dev-tools`),
- SDKs added through `sdks.add` (yours, from any layer in scope).

Everything else is **protected** and refusing to remove it is a hard
error, because the base chain is load-bearing:

| Protected SDK | Why it cannot be removed |
| --- | --- |
| `opencode` | The agent the workshop exists to run |
| `openchamber` | Serves the workshop UI on port 3000 |
| `gh-cli` | Delivers your host-keyring GitHub credentials through the `github-token` secret plug |
| `uv` | Provisioning depends on it: Python interpreters and the hash-locked tox venv are installed through the uv SDK |
| `project-<profile>-tools` | Owns this repo's provisioning and health-gate hooks |

Naming an SDK that is in neither the removable nor the protected set - a
typo, or an SDK the chain never had - is also a hard error
(`unknown SDK`), so a removal can never silently no-op.

## Apply and verify

```sh
just setup <name>
just layers <name>
```

The layers report lists the removed SDK under "SDK chain diff" as
`removed`, and flags drift when the persisted vars doc predates your edit.
`workshop info <name>` confirms the instance's health after the re-launch.

## Troubleshooting

**`sdks.remove: 'uv' is protected`**
By design - see the table above. There is no override; customize around
the base chain instead of removing from it.

**`sdks.remove: unknown SDK '...'`**
The name is not in the chain this instance renders. Check the spelling
against `just layers <name>`, and remember the removable set includes
user-added SDKs - an SDK added only in another instance's scope is not
removable here.

**The SDK is still present after setup.**
Another layer in scope re-adds it through `sdks.add`, or the layer was
edited after the last setup run. `just layers <name>` shows every applied
layer with its digest; remove the adding entry or re-run
`just setup <name>`.
