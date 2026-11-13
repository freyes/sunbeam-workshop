# Vendored workshop JSON schema

`workshop-json-schema.json` is a machine-readable copy of the JSON schema
embedded in the upstream workshop-definition reference page.

- Source URL: <https://ubuntu.com/workshop/docs/reference/definition-files/workshop-definition.md>
  (the single fenced `json` block under the page's
  `### Workshop definition schema` section)
- Retrieval date: 2026-11-13
- Schema `$id`: `https://canonical.com/workshop.yaml`

## Why vendored (the 404 situation)

The schema's own `$id` URL, `https://canonical.com/workshop.yaml`, returns
404 (Metis finding F-13): there is no fetchable canonical copy at that
address. The only machine-readable source is the schema embedded in the docs
page above, so this directory's copy IS the contract used by
`scripts/check-render.sh` and CI. Nothing fetches a schema at CI runtime.

## Re-vendoring

Never edit `workshop-json-schema.json` by hand. Refresh it from the live
docs page with:

```sh
bash scripts/vendor-schema.sh
```

The script curls the source page (with connect/total timeouts), strictly
isolates the JSON-schema block, and FAILS if the page structure changed
(missing heading, missing/moved/duplicated fence, invalid JSON, or missing
`$schema`/`$id`/`type: "object"`) rather than writing a mangled schema. If
the vendored copy is already byte-identical to the live page it reports
"already current" and exits 0, so re-vendoring is safe to run any time.
