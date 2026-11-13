(profiles)=

# Profiles

Profiles are data: a jinja2 template plus a variables document per profile
under `profiles/<profile>/`. Three profiles ship with the repository.

| Profile | Purpose | Highlights |
| --- | --- | --- |
| `sunbeam` | Sunbeam / OpenStack-on-k8s development | `charmcraft`, `snapcraft`, `rockcraft`, `juju`, `go`, `astral-uv` (pinned channels); tox + tox-uv; uv-managed CPython 3.10 and 3.12; optional sidecar VM (`microk8s` `1.32-classic/stable`) |
| `charmed` | Classic charmed OpenStack development | charmcraft; tox + tox-uv; uv-managed CPython 3.10 and 3.12; git-review for Gerrit submissions |
| `packaging` | Ubuntu packaging for OpenStack | `orange-dev-tools` SDK (`latest/edge`) plus git-buildpackage, quilt, and sbuild tooling (`sbuild-launchpad-chroot`) from the hooks |

Any profile can be instantiated under a suffixed name - `just setup
packaging-foo` renders the packaging profile as an independent instance
named `packaging-foo`. Names must match `^[a-z](?:-?[a-z0-9])*$` and are
capped at 40 characters.

## Profile variables: `profiles/<profile>/vars.json`

| Key | Used by | Meaning |
| --- | --- | --- |
| `core_repos` | seed | Repositories the profile works on. Seeds `config/repos/<profile>.json`, the live list `just repos` consumes. Entry shape: `{name, forge, url}` - see {doc}`config`. |
| `supporting_repos` | seed | Same shape as `core_repos`, for secondary checkouts. |
| `snaps` | `setup-base` hook | Snap pins installed at launch: channel and confinement per snap. Sunbeam pins `charmcraft`, `snapcraft`, `rockcraft` (`latest/stable`, classic), `juju` (`3.6/stable`), `go` (`1.27/stable`), and `astral-uv` (`latest/stable`, classic); charmed pins `charmcraft`. |
| `tox` | `setup-project` hook | tox version (`4.47.3`) and plugins (`tox-uv`) for the hash-locked tox virtual environment. |
| `pythons` | `setup-project` hook | Interpreters installed via `uv python install` (`3.10`, `3.12`) for the tox environments; discovered through tox-uv. |
| `k8s` | sidecar VM cloud-init | Sunbeam only: the `microk8s` snap and channel (`1.32-classic/stable`) for the deployment-testing substrate in the sidecar VM. |
| `extra_sdks` | `sdks-chain` partial | Extra store SDKs inserted between `uv` and the in-project tools SDK. Packaging uses it for `orange-dev-tools` (`latest/edge`). |

## Template composition

Each profile's `workshop.yaml.j2` is composed only from the shared partials
under `profiles/_partials/` (`system-secret`, `oauth-tunnel`, `sdks-chain`,
`ssh-agent`), symlinked into the profile's `partials/` directory.
`scripts/render.sh` refuses to render when a partial symlink is missing or
broken. The rendered output contract is documented in
{doc}`rendered-yaml`.

## Adding a profile

Adding a profile never touches the render code. In outline (the full
contract lives in `AGENTS.md`):

1. Create `profiles/<name>/workshop.yaml.j2` from the shared partials and
   symlink every partial into `profiles/<name>/partials/`.
2. Create `profiles/<name>/vars.json` with the keys above.
3. Create the in-project SDK at `.workshop/<name>-tools/` (`sdk.yaml` plus
   the `setup-base`, `setup-project`, `check-health` hooks).
4. Create `config/repos/<name>.json`, seeded from the new `core_repos`.
5. Validate: `just render <name>`, then
   `bash scripts/check-render.sh .workshop/<name>.yaml`, then `just lint`;
   add the profile and one suffixed instance to the bounded render matrix
   in `scripts/ci/render-matrix.sh` so CI renders it.
