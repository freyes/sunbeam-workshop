(add-a-sdk-locally)=

# Add an SDK locally

This guide adds an SDK to a workshop instance through a user vars layer - a
gitignored file under `config/local/vars/` - without touching the tracked
profile definition. Use it when a store SDK (or your own in-project SDK)
should exist in one workshop, one profile, or every workshop you launch,
but not in the shared profile data.

## Prerequisites

- A host checkout of this repository with the instance rendered or launched
  (`just setup <name>` has run, or you are about to run it).
- The workshop name you are customizing: a profile (`sunbeam`, `charmed`,
  `packaging`) or a suffixed instance such as `packaging-foo`.
- For a store SDK: its name on the Snap Store, and optionally the channel
  to track.

## Choose the scope

User vars layers apply in scope order - `all`, then the profile layer, then
the instance layer - and `sdks.add` entries concatenate across them in that
order:

| Layer file | Applies to | Use it when |
| --- | --- | --- |
| `config/local/vars/all.yaml` | Every workshop rendered from this checkout | The SDK belongs in every workshop you launch |
| `config/local/vars/profile/<profile>.yaml` | Every instance of one profile, suffixed instances included | The SDK supports that profile's work only |
| `config/local/vars/instance/<name>.yaml` | Exactly one named instance | A one-off experiment on a single workshop |

Every slot also accepts a `.json` file with the same content - but never
both formats for the same slot. When `<base>.json` and `<base>.yaml`
coexist, the loader refuses to guess and names both paths in a hard error
(`.yml` is never read).

## Add the SDK

Create the layer file. YAML (comments allowed), adding the
`orange-dev-tools` store SDK to every workshop:

```yaml
# config/local/vars/all.yaml
sdks:
  add:
    # channel is optional; omit it to track the store default.
    - name: orange-dev-tools
      channel: latest/edge
```

The same layer as JSON (`config/local/vars/all.json`):

```json
{
  "sdks": {
    "add": [
      { "name": "orange-dev-tools", "channel": "latest/edge" }
    ]
  }
}
```

An entry carries `name` (required), `channel` (optional), and optional
`plugs` / `slots` interface lists - and nothing else. The layer schema is
strict: an unknown key, a missing `name`, or a wrong value type fails the
render with an error naming the file and the offending key.

## Where the entry lands

User-added SDKs are inserted after the profile's `extra_sdks` and before
the in-project `project-<profile>-tools` SDK:

```text
system -> opencode -> openchamber -> gh-cli -> uv
       -> [profile extra_sdks] -> [your sdks.add entries]
       -> project-<profile>-tools
```

Hook order follows SDK order, so your SDK is installed - and any plugs and
slots it declares are auto-connected - before the repo's provisioning hooks
run. Declared interfaces auto-connect by name at launch; there is no user
`connections:` seam in the rendered definition, so a manual connection
(such as the `gh-cli:github-token` secret wiring) stays the tracked
templates' business.

## Apply and verify

Layers are read at render time. Re-run the guided setup - it is idempotent:
it re-renders the definition, re-persists the merged vars doc, and brings
the instance back to Ready:

```sh
just setup <name>
```

Then verify:

```sh
just layers <name>     # the applied layer, its digest, and the chain diff
workshop info <name>   # the instance's health state
```

`just layers <name>` lists the layer file under "User vars layers" and the
SDK under "SDK chain diff" as `added`. It also compares the layer digests
against the persisted vars doc, so an edited layer that has not been
re-applied is named as drift - re-run `just setup <name>` to apply it.

## When you need your own hooks: the user-SDK pattern

A store SDK cannot run your provisioning code. When you need lifecycle
hooks of your own, carry an in-project SDK the same way the repo carries
`project-<profile>-tools`:

1. Create `.workshop/<my-sdk>-user-tools/` - the `-user-tools` suffix marks
   it as yours; the directory is gitignored and must never be committed.
2. Give it an `sdk.yaml` whose `name:` exactly equals the directory name,
   plus a `base:` (the repo's SDKs use `ubuntu@26.04`).
3. Ship hooks as **real files**, not symlinks: the Workshop snap copies
   symlinks verbatim and they dangle inside the workshop. The directory
   must be owned by the user who runs the launch.
4. Reference it from a layer with the `project-` prefix - an in-project SDK
   named `project-<my-sdk>-user-tools` resolves to
   `.workshop/<my-sdk>-user-tools/` purely by path:

   ```yaml
   sdks:
     add:
       - name: project-<my-sdk>-user-tools
   ```

5. Re-run `just setup <name>`.

The full hook contract - and the lighter fragment alternative, which needs
no SDK at all - is in {doc}`customize-with-hooks`.

## Troubleshooting

**The render fails naming both a `.json` and a `.yaml` path.**
One slot, one format: delete or rename one of the two files.

**`sdks chain: duplicate SDK name '...'`**
Your `sdks.add` entry clashes with the base chain or a profile
`extra_sdks` entry. Remove the duplicate from your layer; to replace a
removable entry instead, see {doc}`remove-a-sdk-locally`.

**The instance launched but the SDK is missing.**
The layer was edited after the last setup run. Check
`just layers <name>` for drift, then re-run `just setup <name>`.
