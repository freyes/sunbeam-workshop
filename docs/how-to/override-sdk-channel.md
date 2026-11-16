(override-sdk-channel)=

# Override an SDK channel

This guide changes the store channel an existing SDK tracks, through the
`sdks.set` key of a user vars layer. It is channel-only, store SDKs only,
and deliberately narrow - everything else is a hard error.

## Prerequisites

- A host checkout of this repository, and the workshop name to customize.
- The SDK name as it appears in the chain (`just layers <name>` shows the
  effective diff) and the channel you want it to track.

## Set the channel

Pick the layer scope as for any user vars key (`all`, profile, or
instance - later layers win when two layers set the same SDK). YAML:

```yaml
# config/local/vars/instance/sunbeam-x.yaml
sdks:
  set:
    uv:
      channel: latest/edge
```

The same layer as JSON (`config/local/vars/instance/sunbeam-x.json`):

```json
{
  "sdks": {
    "set": {
      "uv": { "channel": "latest/edge" }
    }
  }
}
```

`channel` is the only key an `sdks.set` entry may carry - there is no
mechanism to rewrite plugs, slots, or any other SDK property from a user
layer.

## What you can set

Only **store SDKs already in the final chain**:

- `channel` is schema-inert on `project-*`, `try-*`, and `system` SDKs (it
  only applies to SDKs from the Snap Store), so setting one of those is a
  hard error - remove the entry;
- setting a name that is absent from the chain is a hard error, so a typo
  fails loudly instead of no-op'ing;
- setting `gh-cli` or `openchamber` is allowed but prints a **load-bearing
  warning** on every render: the gh-cli SDK delivers your host-keyring
  credentials through the `github-token` secret plug, and the openchamber
  SDK serves the workshop UI on port 3000. A channel change on either can
  break authentication or the UI - apply it, then verify both still work
  before keeping the layer.

## Apply and verify

```sh
just setup <name>
just layers <name>
```

The layers report shows the channel change under "SDK chain diff" as
`overridden`, plus any load-bearing warning under "Warnings". Drift
between the layer digests and the persisted vars doc is named in the
report; re-run `just setup <name>` to apply an edited layer.

## Troubleshooting

**`sdks.set.<name>: channel is schema-inert on project-, try-, and system SDKs`**
The entry targets an SDK that does not come from the Snap Store. Delete
it - there is nothing to override.

**`sdks.set.<name>: no SDK named '<name>' in the final chain`**
The SDK is not in this profile's chain. Check the name with
`just layers <name>`; to introduce a new store SDK instead, see
{doc}`add-a-sdk-locally`.

**The render works but warns that the override is load-bearing.**
Expected for `gh-cli` and `openchamber`. Confirm the new channel still
delivers the credential flow (`gh auth status` inside the workshop) or
the UI (`:3000`), and revert the layer if either breaks.
