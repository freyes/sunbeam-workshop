(how-to-guides)=

# How-to guides

Step-by-step guides covering key operations and common tasks.

```{toctree}
---
maxdepth: 1
---
authenticate-github
authenticate-jira-mcp
add-a-sdk-locally
remove-a-sdk-locally
override-sdk-channel
define-actions
customize-with-hooks
```

## User-level customization at a glance

The last five guides cover one feature family: customizing a workshop
without touching tracked profile data. Your customization lives in *user
vars layers* - data docs under `config/local/vars/` that apply in scope
order: `all` (every workshop), then `profile/<profile>` (one profile's
instances), then `instance/<name>` (one workshop). Layers can add or
remove SDKs, override an SDK's channel, and define actions; hook fragments
under `config/local/hooks/` customize provisioning itself.

Every layer slot is format-flexible: write `<base>.json` or `<base>.yaml`,
but never both - the loader refuses to guess when the two coexist, and
`.yml` is never read.

```{warning}
`config/local/` is gitignored on purpose: layers are personal and
machine-local, not portable. They are not shared through the repository,
so a checkout on another host - a teammate, a CI runner - renders without
them, and `SUNBEAM_WORKSHOP_NO_USER_LAYERS=1` ignores them explicitly on
any machine. And the standing rule still applies: never put credentials
in a layer or a fragment - secrets come from the host keyring only
(see {doc}`authenticate-github`).
```
