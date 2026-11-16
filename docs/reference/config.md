(config)=

# Configuration

Configuration in this repository is data, not code. This page describes the
layered user configuration, the per-profile repository lists, and the
sidecar VM preset - everything under `config/`.

## User configuration layers

Your identity and preferences come from up to three JSON layers, deep-merged
in this order (later layers win):

1. `config/config.json`
2. `config/local.json`
3. `config/<user>/config.json` (where `<user>` is your host user name)

Merge semantics: dictionaries merge recursively; lists and scalars replace.
Missing layers are skipped without error. There is no per-instance config
layer. `config/local.json` and `config/<user>/config.json` are gitignored,
so personal settings never leak into commits.

Copy `config/example/config.json` as a starting point:

```json
{
  "github_handle": "your-github-handle",
  "email": "your.name@canonical.com",
  "forks": {},
  "core_repos": ["charm-keystone", "snap-openstack", "sunbeam-charms"],
  "supporting_repos": ["openstack-agentic-skills"]
}
```

| Key | Meaning |
| --- | --- |
| `github_handle` | Your GitHub user name. Used for the `fork` remote when a repo entry names a `fork_of` upstream, and part of your identity in the merged variables document. |
| `email` | Your commit email; applied as the workshop's git identity by the provisioning hooks. |
| `forks` | Optional map of fork relationships for your own workflow. |
| `core_repos` / `supporting_repos` | Repo names you work with; see the repository lists below for the authoritative per-profile lists. |
| `gerrit_username` | Optional. Sets `gitreview.username` for `git review -s` on opendev clones; defaults to your host user name when unset. |

The merged layers feed the variables document that `just setup` persists to
`.state/<name>.vars.json` - the provisioning hooks read your git identity
(user name and email) from it.

## Repository lists: `config/repos/<profile>.json`

`just repos <profile>` clones or updates the checkouts under `git/` of the repo
checkout (`/project/git` inside the workshop container) from these lists.
`--filter <glob>` (repeatable, ORed) limits the run to matching repo names -
e.g. `just repos packaging --filter 'neutron*'` clones only the repos whose
name matches `neutron*`. Each entry in `core_repos` or `supporting_repos` is an
object:

```json
{
  "name": "sunbeam-charms",
  "forge": "opendev",
  "url": "https://opendev.org/openstack/sunbeam-charms"
}
```

| Key | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Directory name under the clone root (`/project/git` inside the workshop container). |
| `forge` | yes | One of `github`, `opendev`, `launchpad` - selects the clone behaviour below. |
| `url` | yes | The clone URL. |
| `fork_of` | no | `<owner>/<repo>` on GitHub; adds a `fork` remote (needs `github_handle`). |

Forge behaviour:

- `github` - clones via `gh repo clone`; adds a `fork` remote when
  `fork_of` is set.
- `opendev` - clones over HTTPS, then `git review -s` wires the Gerrit
  remote (`gitreview.username` from `gerrit_username`, else the host user
  name).
- `launchpad` - clones over HTTPS.

Existing clones are fetched and fast-forwarded, never re-cloned; dirty
clones are reported and left untouched. `just lint` parses every
`config/**/*.json` file, so a malformed list fails the lint gate.

## Sidecar VM preset: `config/vm.json`

Hardware for the optional sunbeam sidecar VM:

```json
{
  "name": "sunbeam-dev",
  "image": "ubuntu:26.04",
  "cpu": 8,
  "memory": "16GiB",
  "disk": "100GiB",
  "pool": "default"
}
```

Changing `cpu`, `memory`, or `disk` requires `just vm-destroy && just
vm-create`. See `docs/dev-vm.md` for the VM lifecycle.
