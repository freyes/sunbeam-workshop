# openstack-workshop

A starter repository that turns a fresh Ubuntu 24.04+ amd64 machine into a
named, isolated OpenStack development workshop - one guided command gives you
an LXD container with the right repositories, build tools, credentials
wiring, and AI tooling already in place. Profiles are data (a jinja2 template
plus variables), so you can also instantiate any profile under a new name
just by adding a suffix.

## Features

- **Named profiles + suffix instantiation.** Three ready profiles - `sunbeam`
  (charmcraft/snapcraft/rockcraft, tox), `charmed` (classic charms,
  git-review for Gerrit), and `packaging` (Ubuntu packaging) - resolved by
  longest-prefix match, so `just setup packaging-foo` renders the packaging
  profile as a second, independent instance named `packaging-foo`.
- **opencode + openchamber.** Every profile declares the opencode SDK and the
  openchamber UI SDK, which serves the agent UI on port 3000.
- **gh-cli SDK with host-keyring credentials.** `just secret-setup` stores
  your GitHub token in the host keyring; the rendered `github-token` secret
  plug delivers it to `gh` inside the workshop on request. No token is ever
  written to this repository, the rendered yaml, or the container
  environment. An optional OpenRouter key (the prompt is skippable with
  Enter) flows to opencode's `auth.json` the same way, through the
  `openrouter-key` secret plug.
- **Jira MCP, pre-seeded.** The Atlassian MCP server entry is seeded into the
  opencode config at provisioning; OAuth consent runs through
  `opencode mcp auth atlassian`, with the browser callback forwarded into
  the workshop through a tunnel plug that `just connect <name>` wires on
  demand - it is never auto-connected at launch (`just disconnect <name>`
  disconnects it again).
- **Agentic skills.** `canonical/openstack-agentic-skills` is cloned and
  symlinked into the opencode skills directory at provisioning, so OpenStack
  team practices are available to the agent out of the box.
- **Orange packaging toolchain.** The packaging profile layers the
  `orange-dev-tools` SDK (`latest/edge`) under an in-project tools SDK whose
  hooks add git-buildpackage, quilt, sbuild tooling, and a pre-seeded
  dput-ng PPA upload profile.
- **Sidecar VM (sunbeam).** `just vm-create` manages an optional LXD VM on
  the host for the heavy work the container cannot do: craft builds and a
  microk8s + juju substrate for deployment testing (see `docs/dev-vm.md`).

**No omp, no vscode, no herdr** - anywhere. opencode plus openchamber is the
only agent stack, by deliberate scope.

## Quickstart

The full walkthrough lives in the getting-started tutorial at
`docs/tutorial/getting-started.md` (landing with the sphinx-stack docs
site). The short version, on an Ubuntu host with the Workshop snap and LXD:

```sh
just doctor             # read-only host prerequisite checks
just setup sunbeam      # guided, idempotent setup; re-run to repair
just shell sunbeam      # open a shell inside the workshop
just repos sunbeam      # clone/update the profile's repositories
```

Replace `sunbeam` with `charmed`, `packaging`, or a suffixed instance such as
`packaging-foo`. `just` on its own lists every command.

## Repository map

- `Justfile` + `just/` - the single entry point for every workflow;
  host-mutating recipes carry an `assert-host` guard.
- `profiles/` - the profile templates and variables; `profiles/_partials/`
  holds the shared jinja2 partials.
- `.workshop/<profile>-tools/` - the in-project SDKs (definition + lifecycle
  hooks). Rendered `.workshop/*.yaml` instances are generated and gitignored.
- `config/` - data, not code: per-profile repo lists (`config/repos/`), the
  VM hardware preset, and layered user config.
- `scripts/` - the setup/render/secrets/doctor pipeline, the sidecar-VM
  lifecycle, the lint/test gates, and the uv-managed Python tooling.
- `skills/` - opencode skills for agents working in this repo.
- `AGENTS.md` - the agent contract: mutation table, invariants, runbook.

## Development

`just lint` runs the same gates as the CI lint workflow (shellcheck including
just recipe bodies and SDK hooks, actionlint, config/template validation);
`just test` runs the shell test suites, and the same CI test workflow also
runs the pytest unit tests and the bounded render matrix (locally:
`cd scripts && uv run --frozen pytest -q`,
`bash scripts/ci/render-matrix.sh`). Both workflows run on every push and
pull request.

## License

GNU General Public License v3.0 - see `LICENSE`.
