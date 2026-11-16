---
name: profile-authoring
description: Use when adding a profile, editing profiles/*/workshop.yaml.j2 or vars.json, or debugging render/name-resolution. Defines the vars doc, suffix instantiation, and the partials include contract.
---

# Profile Authoring

## When to Use

- Adding a new profile under `profiles/`.
- Editing `profiles/<profile>/workshop.yaml.j2` or `vars.json`.
- Chasing a render failure, a `TemplateNotFound`, or a name-resolution error.

## Profiles are data, not code

A profile is four pieces:

1. `profiles/<name>/workshop.yaml.j2` - the jinja2 template.
2. `profiles/<name>/vars.{json,yaml}` - profile defaults. The slot is
   format-flexible: exactly one of `vars.json` or `vars.yaml` (never both;
   `.yml` is never read).
3. `.workshop/<name>-tools/` - the in-project SDK (`sdk.yaml` + `hooks/`;
   see the `hook-authoring` skill).
4. `config/repos/<name>.json` - the repo list `just repos <name>` consumes
   (seed from the `core_repos` in the profile vars).

## Name resolution and suffix instances (D-13)

- A workshop NAME must match `^[a-z](?:-?[a-z0-9])*$`, max 40 chars.
- An exact `profiles/<NAME>/` dir match wins and yields an empty suffix;
  otherwise the LONGEST hyphen-delimited prefix matching a profile dir is
  the profile and the remainder is the instance suffix:
  `packaging-foo` -> profile `packaging`, suffix `foo`.
- Unknown prefixes fail listing the valid profiles (exit 3); an invalid name
  fails with exit 4; a name colliding with a launched `.workshop/<NAME>/`
  instance dir fails with exit 5 - UNLESS a profile dir shadows it, in which
  case resolution succeeds with `shadow_warning=True` and render prints the
  warning.
- The merged vars doc (`scripts/sunbeam_workshop/vars.py build_vars`)
  contains: `workshop_name`, `profile`, `suffix`, `shadow_warning`,
  `profile_vars` (the profile's vars slot), `config` (deep-merge of
  `config/config.json` < `config/local.json` < `config/<user>/config.json`;
  dicts recurse, lists/scalars replace), `user` (host user name,
  `github_handle`, `email`), plus the computed keys `sdks` (the assembled
  chain), `actions` (profile vars + user layers, merged by name), and
  `_layers` (provenance of every vars-doc input).

## The partials include contract

Templates are composed ONLY from the shared partials. Each profile dir holds
a `partials/` directory of git symlinks into `profiles/_partials/`;
jinja2-cli roots its loader at the template's own directory, and
`scripts/render.sh` refuses to render when a partial symlink is missing or
broken. Include order is the contract (copy the existing templates exactly):

1. `partials/system-secret.yaml.j2` FIRST under `sdks:` - it opens the
   `- name: system` entry carrying the `github-token` secret slot (keyring
   LOOKUP attributes, never a value).
2. `{% set oauth_tunnel_part = 'plug' %}` then include
   `partials/oauth-tunnel.yaml.j2` - nests the `mcp-oauth-callback` tunnel
   plug (endpoint `localhost:19876`) under that same system entry.
3. `partials/sdks-chain.yaml.j2` - a DUMB EMITTER over the computed
   `sdks` list. The chain is assembled in Python
   (`scripts/sunbeam_workshop/chain.py`): base chain (`opencode`,
   `openchamber` at `latest/edge` - it must follow opencode -, `gh-cli`,
   `uv` at `latest/stable`) -> any `profile_vars.extra_sdks` entries
   (packaging uses this for `orange-dev-tools@latest/edge` so its apt base
   lands before the project hooks run) -> user `sdks.add` entries ->
   `project-<profile>-tools`. The partial only emits `name:`/optional
   `channel:`/`plugs:`/`slots:` per entry; chain logic never goes back
   into the template.
4. `partials/ssh-agent.yaml.j2` IMMEDIATELY after the chain, so the
   ssh-agent graft nests under the trailing `project-<profile>-tools` entry.
5. Under top-level `connections:`,
   `{% set oauth_tunnel_part = 'connections' %}` and include
   `partials/oauth-tunnel.yaml.j2` again - emits the
   `gh-cli:github-token -> system:github-token` manual connection and the
   `system:mcp-oauth-callback -> opencode:opencode-mcp-oauth-callback`
   tunnel connection.
6. `partials/actions.yaml.j2` LAST, after the connections include - emits
   the top-level `actions:` block (block scalars, sorted by name) from the
   merged `actions` mapping. When the mapping is empty it must emit ZERO
   bytes (the golden byte-identity baseline depends on it); jinja comments
   only, nothing may reach the rendered yaml.

The oauth-tunnel partial deliberately renders an error when
`oauth_tunnel_part` is unset or misspelled - that is the contract working,
not a bug. Declare `name: {{ workshop_name }}` and `base: ubuntu@26.04` at
the top; hooks and SDK ordering do the rest.

## Profile vars keys in use

`core_repos` / `supporting_repos` (seed lists of `{name, forge, url}`),
`snaps` (`{"<snap>": {"channel": "...", "classic": true?}}` - mirrored by
`setup-base`), `tox` (`version`, `plugins`), `pythons` (uv-managed
interpreters for tox envs), `k8s` (sidecar-VM substrate, sunbeam),
`extra_sdks` (`[{"name": "...", "channel": "..."}]`), `actions` (tracked
action bodies - `{"<name>": "<shell body>"}`, names matching
`^[a-z](?:-?[a-z0-9])*$`; user layers merge on top by name).

## Verify

- `just render <name>` then `bash scripts/check-render.sh .workshop/<name>.yaml`
  (vendored schema; unknown top-level fields are rejected).
- `just lint` parses every `profiles/**/*.j2` (syntax only) and every
  data doc under `config/` (`.json` and `.yaml`; same-stem coexistence and
  `.yml` are rejected) plus `profiles/*/vars.{json,yaml}`.
- Add the new profile plus one suffixed instance to the bounded `NAMES`
  list in `scripts/ci/render-matrix.sh` so CI renders it.
- Never hand-edit the rendered `.workshop/<name>.yaml` - it is generated and
  gitignored (AGENTS.md Invariant 3).
