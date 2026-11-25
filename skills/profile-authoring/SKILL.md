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
2. `profiles/<name>/vars.json` - profile defaults (JSON only; no YAML data
   source anywhere in the vars path).
3. `.workshop/<name>-tools/` - the in-project SDK (`sdk.yaml` + `hooks/`;
   see the `hook-authoring` skill).
4. `config/repos/<name>.json` - the repo list `just repos <name>` consumes
   (seed from the `core_repos` in `vars.json`).

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
- The merged vars doc (`scripts/openstack_workshop/vars.py build_vars`)
  contains: `workshop_name`, `profile`, `suffix`, `shadow_warning`,
  `profile_vars` (the profile's `vars.json`), `config` (deep-merge of
  `config/config.json` < `config/local.json` < `config/<user>/config.json`;
  dicts recurse, lists/scalars replace), and `user` (host user name,
  `github_handle`, `email`).

## The partials include contract

Templates are composed ONLY from the shared partials. Each profile dir holds
a `partials/` directory of git symlinks into `profiles/_partials/`;
jinja2-cli roots its loader at the template's own directory, and
`scripts/render.sh` refuses to render when a partial symlink is missing or
broken. Include order is the contract (copy the existing templates exactly):

1. `partials/system-secret.yaml.j2` FIRST under `sdks:` - it opens the
   `- name: system` entry carrying TWO secret slots, `github-token` and
   `openrouter-key`, both keyring LOOKUP attributes only, never a value
   (`github-token`: `service: "gh:github.com"`, `username: ""`;
   `openrouter-key`: `service: "openstack-workshop-openrouter-key"`).
2. `{% set oauth_tunnel_part = 'plug' %}` then include
   `partials/oauth-tunnel.yaml.j2` - nests the `mcp-oauth-callback` tunnel
   plug (endpoint `localhost:19876`) under that same system entry.
3. `partials/sdks-chain.yaml.j2` - renders the chain every profile shares:
   `opencode`, `openchamber` (`latest/edge`; must follow opencode),
   `gh-cli`, `uv` (`latest/stable`), then any `profile_vars.extra_sdks`
   entries (packaging uses this for `orange-dev-tools@latest/edge` so its
   apt base lands before the project hooks run), then
   `project-<profile>-tools`.
4. `partials/project-plugs.yaml.j2` IMMEDIATELY after the chain, so its
   grafts nest under the trailing `project-<profile>-tools` entry. The
   partial carries BOTH plugs in one `plugs:` mapping - `ssh-agent`
   (interface `ssh-agent`; the system slot is implicit and auto-connects)
   and `openrouter-key` (interface `secret`). One mapping, not two
   partials: a second partial emitting `plugs:` under the same SDK entry
   would duplicate the YAML key.
5. Under top-level `connections:`,
   `{% set oauth_tunnel_part = 'connections' %}` and include
   `partials/oauth-tunnel.yaml.j2` again - emits TWO entries: the
   `gh-cli:github-token -> system:github-token` manual connection and
   `{{ profile }}-tools:openrouter-key -> system:openrouter-key`. The
   `system:mcp-oauth-callback` tunnel plug deliberately has NO entry -
   no auto-connect at launch: `just connect <name>` / `just disconnect
   <name>` (`scripts/oauth-tunnel.sh`) wire and unwire it on demand. The
   openrouter entry uses the RUNTIME (stripped) SDK name
   `<profile>-tools:openrouter-key`: `project-` is a definition-file
   source marker that the platform strips at runtime, and connection
   refs and `workshopctl get-secret` reject `project-`-prefixed names.
   Secret plugs never auto-connect - `scripts/secret-setup.sh` wires
   them with `workshop connect`.

The oauth-tunnel partial deliberately renders an error when
`oauth_tunnel_part` is unset or misspelled - that is the contract working,
not a bug. Declare `name: {{ workshop_name }}` and `base: ubuntu@26.04` at
the top; hooks and SDK ordering do the rest.

## vars.json keys in use

`core_repos` / `supporting_repos` (seed lists of `{name, forge, url}`),
`snaps` (`{"<snap>": {"channel": "...", "classic": true?}}` - mirrored by
`setup-base`), `tox` (`version`, `plugins`), `pythons` (uv-managed
interpreters for tox envs), `k8s` (sidecar-VM substrate, sunbeam),
`extra_sdks` (`[{"name": "...", "channel": "..."}]`).

## Verify

- `just render <name>` then `bash scripts/check-render.sh .workshop/<name>.yaml`
  (vendored schema; unknown top-level fields are rejected).
- `just lint` parses every `profiles/**/*.j2` (syntax only) and every
  `config/**/*.json`.
- Add the new profile plus one suffixed instance to the bounded `NAMES`
  list in `scripts/ci/render-matrix.sh` so CI renders it.
- Never hand-edit the rendered `.workshop/<name>.yaml` - it is generated and
  gitignored (AGENTS.md Invariant 3).
