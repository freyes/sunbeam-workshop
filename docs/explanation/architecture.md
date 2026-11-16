(architecture)=

# Architecture

sunbeam-workshop turns one Ubuntu host into any number of named, isolated
OpenStack development environments. This page explains the three layers the
system spans, how profiles become running workshops, how the SDK chain is
composed, how credentials flow without ever entering the repository, and
the security properties you should understand before trusting the result.

## The three layers

```text
┌──────────────────────────────────────────────────────────────────┐
│ Host (Ubuntu 24.04+ amd64)                                        │
│   just ── entry point for every workflow                          │
│   host keyring ── stores the GitHub token (never in the repo)     │
│   LXD ── runs the workshop containers and the sidecar VM          │
│   Workshop snap ── launches instances from rendered definitions   │
│                                                                   │
│   ┌────────────────────────────┐  ┌────────────────────────────┐  │
│   │ Workshop container         │  │ Workshop container         │  │
│   │ "sunbeam"                  │  │ "packaging-foo"            │  │
│   │ /project ← repo mount      │  │ /project ← repo mount      │  │
│   │ opencode, openchamber,     │  │ opencode, openchamber,     │  │
│   │ gh, uv, tox, craft snaps   │  │ gh, uv, packaging toolchain│  │
│   └────────────────────────────┘  └────────────────────────────┘  │
│                                                                   │
│   ┌────────────────────────────┐                                  │
│   │ Sidecar VM (optional,      │  sunbeam profile only:          │
│   │ LXD VM, ubuntu:26.04)      │  craft builds + microk8s/juju   │
│   └────────────────────────────┘                                  │
└──────────────────────────────────────────────────────────────────┘
```

**The host** holds the single `just` entry point, the layered configuration,
and the only long-lived secret: the GitHub token in the host keyring. LXD
and the Workshop snap do the heavy lifting; this repository orchestrates
them.

**Workshop containers** are LXD containers launched by the Workshop snap,
one per named instance. Each mounts this repository at `/project`, so the
same checkout is the source of truth on both sides of the boundary: the
host renders definitions from it, and the in-container hooks source their
shared library from it. A running workshop's kernel hostname IS the bare
workshop name - upstream canonical/workshop templates `/etc/hostname` from
`user.workshop.name`; `<workshop>.<project>.wp` is only the DNS-level
friendly name. Working clones of the profile's repositories live under
`git/` of the repo checkout - `/project/git` inside the workshop container,
`<checkout>/git` on a host checkout.

**The sidecar VM** (sunbeam profile only) is an optional LXD virtual machine
on the host for the work the container cannot do: craft builds - nested LXD
inside the container is blocked upstream - and a MicroK8s + Juju substrate
for deployment testing. Its hardware preset lives in `config/vm.json`;
`docs/dev-vm.md` covers its lifecycle (`just vm-create`, `vm-shell`,
`vm-status`, `vm-destroy`).

## The profile engine

Profiles are data, not code: a jinja2 template
(`profiles/<profile>/workshop.yaml.j2`) plus a variables document
(`profiles/<profile>/vars.json`). Rendering one never involves programming,
which is what makes new profiles and renamed instances cheap.

`just render <name>` (or `just setup <name>`, which renders as one of its
steps) resolves the name, merges the inputs, and renders:

- **Name resolution.** An exact match against `profiles/*` wins; otherwise
  the longest hyphen-prefix match applies, so `packaging-foo` resolves to
  the `packaging` profile with suffix `foo`. Names must match
  `^[a-z](?:-?[a-z0-9])*$` and are capped at 40 characters.
- **The merged variables document** combines the profile's `vars.json`, the
  layered user configuration (see {doc}`../reference/config`), and your
  identity (user name, GitHub handle, email). `just setup` persists it to
  `.state/<name>.vars.json` (mode 0600); the provisioning hooks read the
  git identity from it.
- **The template** is composed only from shared partials under
  `profiles/_partials/`, symlinked into each profile's `partials/`
  directory; `scripts/render.sh` refuses to render when a link is missing
  or broken.
- **Post-validation** parses the render, requires the top-level `name` to
  equal the requested name and a `base` key to be present, then publishes
  atomically to `.workshop/<name>.yaml`. The rendered file is generated and
  gitignored - see {doc}`../reference/rendered-yaml`.

Profiles and instances share one namespace. If a `profiles/<name>/` appears
where a rendered instance of the same name exists, the render succeeds but
prints a shadow warning - the profile now shadows the instance.

## SDK composition and ordering

A workshop is assembled from SDKs - snap-like bundles that install tooling
and run lifecycle hooks. Every profile declares the same chain, in this
order (the shared `sdks-chain` partial renders it):

1. **system** - not an install but the declaration point for the
   `github-token` secret slot and the `mcp-oauth-callback` tunnel plug.
2. **opencode** - the AI agent.
3. **openchamber** (`latest/edge`) - the web UI; it must follow the opencode
   SDK.
4. **gh-cli** - the GitHub CLI, with its `github-token` secret plug.
5. **uv** (`latest/stable`) - the Python toolchain manager.
6. **extra SDKs** - a profile may insert store SDKs here through the
   `extra_sdks` vars key; packaging inserts `orange-dev-tools`
   (`latest/edge`).
7. **project-\<profile\>-tools** - this repository's own SDK, carrying the
   `setup-base`, `setup-project`, and `check-health` hooks. The ssh-agent
   plug is grafted onto this entry.

Order matters: the openchamber SDK builds on opencode, and the in-project
tools SDK runs last so its health check can gate on everything before it.
The `setup-project` hooks provision per-user tooling (tox environment,
Atlassian MCP seed, agentic skills, host-key pinning, git identity), and
`check-health` reports the instance Ready only when the gates pass.

## Credential flow

```text
Host keyring                                   Workshop container
───────────                                    ──────────────────
GitHub token ──► system:github-token ────────► gh-cli:github-token plug
(stored by         secret slot                    (workshop connect)
just secret-setup)   attributes:                    │
                     service: gh:github.com         ▼
                     username: ""                gh runs with the token
                                                 injected per command

Host ssh-agent ──► ssh-agent plug (grafted on project-<profile>-tools)
                 ──► git over ssh to GitHub, Gerrit, Launchpad works
                     without copying private keys

Browser (host) ──► localhost:19876 ──► system:mcp-oauth-callback plug
                 ──► opencode:opencode-mcp-oauth-callback slot
                     (Atlassian OAuth consent reaches opencode)
```

Three rules keep this safe:

- **No secrets in the repository.** The rendered definition carries keyring
  lookup attributes, never the token value. `.state/` and
  `.openchamber-password` are gitignored.
- **No token in any environment.** Never export `GITHUB_TOKEN` or
  `GH_TOKEN` - `gh` prefers them over its keyring login, so a stale value
  silently overrides authentication. The secret plug exists to keep the
  token out of every environment.
- **Keys stay home.** The ssh-agent plug forwards the host agent, so git
  over SSH works without copying private keys into the container. As a
  MITM guard, the provisioning hooks pin the SSH host keys of `github.com`,
  `review.opendev.org`, and `git.launchpad.net`.

## Security

### openchamber listens on the LAN

The openchamber UI is served with `--lan`: it binds the container's
network-facing interface, not loopback. Anyone who can route to the
container address can reach the login page on port 3000. The only gate is
the password the SDK writes to `/project/.openchamber-password` - the
repository root on the host side of the mount, gitignored. Treat that file
as a secret: do not commit it (the gitignore rule does this), do not paste
it into tickets, and prefer reading it over SSH from the host rather than
copying it around. If it leaks, treat it as a compromised credential:
remove the instance (`just remove <name>`) and set it up again so the SDK
installs fresh, or replace the password per the openchamber SDK's own
documentation.

### Edge-channel supply chain

Two workshop components come from a personal snap namespace at `freyes`,
on `latest/edge`:

- the **openchamber SDK**, whose snap is installed unsigned with
  `--dangerous --classic` from `freyes/snap-openchamber` releases - so it
  receives no Store assertion and no automatic refresh;
- the **orange-dev-tools SDK** (packaging profile).

Both were explicitly supplied by the project's owner and are replaceable
later. The risks to understand: edge channels drift - every re-install can
pull newer bits than the last run - and an unsigned snap has no publisher
attestation. The openchamber SDK also auto-installs the oh-my-openagent
(omo) opencode plugin globally as part of its own setup. Mitigation built
into the repo: `just doctor` reports the locally installed SDK and snap
revisions, so drift is visible after the fact. If a Canonical-owned SDK or
a Store snap lands, swap the channel or source in the profile templates.

### GPG signing stays on the host

OpenPGP signing - Launchpad source uploads (`dput`/`debsign`) and
`git-buildpackage` tags - is a documented **host-side** responsibility. No
GPG material enters the containers, and no gpg-agent forwarding is set up;
ssh-agent forwarding covers git only. Sign on the host, then upload.

### The container is not a security boundary

The workshop user inside the container has passwordless sudo, and
`/project` is mounted writable - anything in the container can modify this
repository on the host, and host recipes later run from that same tree.
The `assert-host` guard on host-mutating recipes (`setup`, `secret-setup`,
`vm-create`, `vm-destroy`, `repos`) is a convention in the recipes, not an
enforcement boundary: `workshop` and `lxc` work directly from the host, and
`I_KNOW_WHAT_IM_DOING=1` bypasses the guard. Read `git diff` before running
guarded recipes on the host after container activity.
