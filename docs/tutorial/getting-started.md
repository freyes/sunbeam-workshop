(getting-started)=
# Get started with sunbeam-workshop

This tutorial takes you from a fresh Ubuntu host to a running OpenStack
development workshop. You will check the host prerequisites, run the guided
setup of a named workshop instance, open your first opencode session inside
it, and reach the openchamber web UI.

## What you need

### A suitable host

- An **amd64 Ubuntu 24.04 or later** machine. Other architectures are
  untested; arm64 is best-effort only.
- Room for the `sunbeam` profile's optional sidecar VM: about **8 CPU cores,
  16 GiB of RAM, and 100 GiB of free disk** (the preset lives in
  `config/vm.json`). `just doctor sunbeam` reports shortfalls as warnings.
- The **Workshop snap** and a working **LXD 6.8 or later** - the two hard
  requirements `just doctor` fails on. The Workshop
  [get started tutorial](https://ubuntu.com/workshop/docs/tutorial/part-1-get-started/)
  covers installing both.
- `just`, `uv`, `git`, `jq`, `yq`, and `secret-tool` (from the
  `libsecret-tools` package) on PATH. `just doctor` warns when any is
  missing.
- The [GitHub CLI](https://cli.github.com) (`gh`) on the host. The rendered
  secret slot reads `gh`'s own keyring login, so the credential flow cannot
  work without it.

### Accounts and entitlements

The workshop provisions tooling, not accounts - entitlements are
prerequisites, not something setup can create for you. Before you start:

- A **GitHub account** and a personal access token, which
  `just secret-setup` asks for. {doc}`../how-to/authenticate-github` covers
  the whole flow.
- A **GitHub Copilot seat**. GitHub Copilot is the seeded opencode provider;
  the first opencode session signs in through its device flow.
- **Atlassian Cloud access** (<https://id.atlassian.com>) for the Jira MCP
  server, plus **metered LLM spend** - the AI tooling consumes metered model
  usage, so make sure that is budgeted for.
- An **Ubuntu One account** (<https://login.ubuntu.com>) and a signed
  **Canonical ICLA** (<https://ubuntu.com/legal/contributors>). The ICLA is
  required to contribute through Gerrit, and signing it is your
  responsibility - it cannot be automated.
- A **Launchpad account** if you will use the `packaging` profile, with an
  SSH key pair registered (see
  [creating an SSH key pair](https://help.launchpad.net/YourAccount/CreatingAnSSHKeyPair)).

```{note}
`just doctor` never probes external services. It detects what it can
locally - for example whether `gh` is authenticated and whether an SSH
public key exists - and prints pointers to the account documentation above
for everything else.
```

## 1. Check the host

From a checkout of this repository on the host, run:

```sh
just doctor
```

The doctor is strictly read-only. It fails hard only when the Workshop snap
or a working LXD 6.8+ is missing; everything else - tooling on PATH, the
keyring probe, host architecture, the sunbeam capacity floor - is a warning
or a pointer. Run it again with a profile argument to add that profile's
capacity check:

```sh
just doctor sunbeam
```

## 2. Run the guided setup

Pick a name for your instance: one of the three profiles (`sunbeam`,
`charmed`, `packaging`) or a suffixed variant such as `packaging-foo` for a
second, independent instance of the same profile. Then run:

```sh
just setup sunbeam
```

The setup is guided and idempotent - every step can be re-run to repair an
interrupted run. It walks six steps:

1. **Host checks** - the read-only doctor above; setup stops here if the
   host is not ready.
2. **Confirm** - a summary of what will change. `SETUP_YES=1` takes every
   default without prompting.
3. **Render** - generates `.workshop/<name>.yaml` from the profile template
   and your merged configuration.
4. **Persist variables** - writes the merged variables document to
   `.state/<name>.vars.json` (mode 0600); the workshop hooks read your git
   identity from it.
5. **Secrets** - stores your GitHub token in the host keyring (input is
   hidden and never printed) and prepares the gh-cli secret plug.
6. **Launch** - runs `workshop launch <name>` and waits until
   `workshop info <name>` reports the instance Ready, then wires the gh-cli
   secret plug.

Provisioning inside the container - the tox environment, the Atlassian MCP
server entry, the agentic-skills symlink, SSH host-key pinning - runs as SDK
lifecycle hooks while the instance comes up. A first launch takes a while;
re-runs skip what is already done.

```{tip}
If anything stops, fix the reported item and re-run `just setup <name>`.
Completed steps are skipped, so a re-run resumes where it stopped.
```

## 3. Open your first opencode session

Enter the running workshop:

```sh
just shell sunbeam
```

Inside, opencode is already on PATH:

```sh
opencode
```

On first run, opencode walks you through signing in to GitHub Copilot with
its device flow. This is one of the two interactive auth gates in the
workshop - the Atlassian OAuth consent in
{doc}`../how-to/authenticate-jira-mcp` is the other. Both are manual by
design: consent is human, and no setup step automates it.

The OpenStack agentic skills (`canonical/openstack-agentic-skills`) are
already cloned and symlinked into the opencode skills directory by the
provisioning hooks, so the team's OpenStack practices are available to the
agent out of the box.

## 4. Open the openchamber web UI

The openchamber SDK serves a browser UI for opencode on port 3000 of the
workshop container. From the host, find the container address - the
workshop is a normal LXD instance, so `lxc list` shows it - and browse to:

```text
http://<container-address>:3000
```

The UI asks for a password. The openchamber SDK writes it to
`.openchamber-password` at the project root, which is gitignored; read it
from your host checkout, or inside the container at
`/project/.openchamber-password`:

```sh
cat .openchamber-password
```

```{warning}
openchamber listens on the container's LAN interface, so anyone who can
reach the container address can reach the login page - the password file is
the only gate. Treat it as a secret. See
{doc}`../explanation/architecture` for the full security discussion.
```

## Where to go next

- {doc}`../how-to/authenticate-github` - the GitHub credential flow in
  depth, including troubleshooting.
- {doc}`../how-to/authenticate-jira-mcp` - connect opencode to Jira through
  the Atlassian MCP server.
- `just repos <profile>` - clone or update the profile's repositories under
  `/project/git` (see {doc}`../reference/config` for the repo lists).
- `just vm-create` - create the optional sunbeam sidecar VM for craft
  builds and deployment testing (see `docs/dev-vm.md`).
- {doc}`../explanation/architecture` - how the pieces fit together.
