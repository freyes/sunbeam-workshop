(define-actions)=

# Define workshop actions

This guide defines named shell actions a workshop exposes through
`workshop run`, through the `actions` key of a user vars layer - or,
for actions tracked in the repo, of the profile vars. Actions are the
lightweight way to give a workshop repeatable commands without writing
hooks.

## Prerequisites

- A host checkout of this repository, and the workshop name (`sunbeam`,
  `charmed`, `packaging`, or a suffixed instance).
- A launched instance to run the action in (`just setup <name>`).

## Define an action

Actions are a mapping of name to shell body. YAML block scalars are the
readable form - the body keeps its newlines verbatim:

```yaml
# config/local/vars/profile/sunbeam.yaml
actions:
  charm-tests: |
    cd /project/git/sunbeam-charms
    tox -e "${1:?usage: workshop run <name> charm-tests <tox-env>}"
  hello: |
    echo "hello from $(hostname)"
```

The same layer as JSON - bodies become single strings with escaped
newlines, which is why the YAML form is recommended:

```json
{
  "actions": {
    "hello": "echo \"hello from $(hostname)\"\n"
  }
}
```

Action names must match `^[a-z](?:-?[a-z0-9])*$` - start with a lowercase
letter, then lowercase letters, digits, and single hyphens. Anything else
is a hard error naming the file and the action.

## Where actions come from

Actions merge **by name** from the profile vars (tracked, shared) and then
every applicable user layer in scope order (`all`, profile, instance) -
later definitions win. When one of your layers shadows an action the
profile already defines, the render prints a warning and
`just layers <name>` repeats it under "Warnings"; the report's "Actions"
section names the layer each action came from. Shadow on purpose, or
rename your action.

## Run an action

Inside a running instance, through the `just` passthrough or the
`workshop` CLI directly:

```sh
just run <name> hello
just run <name> charm-tests py312

workshop run <name> charm-tests py312
```

Semantics, as the Workshop snap implements them:

- the body runs **as the workshop user**, under bash as a login shell with
  `errexit` and `pipefail` set (`bash -elo pipefail`);
- arguments after the action name arrive as positional parameters (`$1`,
  `$2`, ..., `"$@"`);
- the action's exit code propagates back exactly, so actions compose in
  scripts and CI;
- bodies are re-read from the rendered definition at run time: after
  editing an action in a layer, `just render <name>` is enough - the next
  `workshop run` picks the new body up with no refresh or re-launch.

`just layers <name>` lists the merged actions under "Actions", with the
layer each came from.

## Troubleshooting

**`actions.<name>: invalid action name`**
The name violates the pattern above (uppercase, underscores, leading
digits, doubled hyphens). Rename it.

**The action fails immediately with a usage error from `$1`.**
Arguments are positional: everything after the action name is passed
through verbatim, so quote as one command -
`just run <name> charm-tests py312`, not `just run <name> "charm-tests py312"`.

**An edited body has no effect.**
Re-render so the definition the runner reads carries the new body:
`just render <name>`. No relaunch is needed; if the *chain* changed too,
re-run `just setup <name>` instead.
