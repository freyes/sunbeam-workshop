#!/usr/bin/env bash
# Copyright 2026 Canonical Ltd. All rights reserved.
#
# Suite for scripts/render.sh (awesome-multirepo scripts/tests pattern).
# Every test renders against a FIXTURE profile tree in a mktemp ROOT, selected
# via SUNBEAM_WORKSHOP_ROOT - the suite never touches the real profiles/ tree
# (the wave-2 profile templates are not required here).
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd "${TEST_DIR}/../.." && pwd)
RENDER="${PROJECT_DIR}/scripts/render.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# All fixture roots live under one suite tmp dir so the EXIT trap cleans up
# even when a test subshell fails mid-way.
SUITE_TMP=$(mktemp -d /tmp/sunbeam-render-tests.XXXXXX)
trap 'rm -rf -- "$SUITE_TMP"' EXIT

new_root() {
    mktemp -d "${SUITE_TMP}/root.XXXXXX"
}

# Fixture profile tree: profiles/fixture/{workshop.yaml.j2,vars.json}, an
# (empty) config dir so the vars module's root discovery accepts the fixture,
# and a scratch TMPDIR so temp-file hygiene is observable.
make_fixture() {
    local root=$1
    mkdir -p "${root}/profiles/fixture" "${root}/config" "${root}/.workshop" "${root}/tmp"
    cat > "${root}/profiles/fixture/workshop.yaml.j2" <<'EOF'
name: {{ workshop_name }}
base: ubuntu@26.04
profile: {{ profile }}
suffix: {{ suffix }}
marker: {{ profile_vars.marker }}
EOF
    cat > "${root}/profiles/fixture/vars.json" <<'EOF'
{"marker": "from-vars-json"}
EOF
}

# Invoke render.sh against the fixture ROOT with TMPDIR pointed at the
# per-root scratch dir.
run_render() {
    local root=$1 name=$2
    env TMPDIR="${root}/tmp" SUNBEAM_WORKSHOP_ROOT="${root}" bash "${RENDER}" "${name}"
}

# run_render variant for tests that materialize user vars layers: the
# kill-switch must NOT leak in from the outer environment (the golden suite
# exports it), so these runs explicitly unset it.
run_render_layers() {
    local root=$1 name=$2
    env -u SUNBEAM_WORKSHOP_NO_USER_LAYERS \
        TMPDIR="${root}/tmp" SUNBEAM_WORKSHOP_ROOT="${root}" bash "${RENDER}" "${name}"
}

# Partials-backed fixture: profiles/fixture renders through COPIES of the real
# sdks-chain + actions partials (linked from profiles/fixture/partials/ so the
# render.sh symlink gate sees the same shape as the real tree). This exercises
# the real dumb emitter and the real actions partial end-to-end.
make_partials_fixture() {
    local root=$1
    make_fixture "${root}"
    mkdir -p "${root}/profiles/_partials" "${root}/profiles/fixture/partials"
    local partial
    for partial in sdks-chain actions; do
        cp "${PROJECT_DIR}/profiles/_partials/${partial}.yaml.j2" \
            "${root}/profiles/_partials/${partial}.yaml.j2"
        ln -s "../../_partials/${partial}.yaml.j2" \
            "${root}/profiles/fixture/partials/${partial}.yaml.j2"
    done
    cat > "${root}/profiles/fixture/workshop.yaml.j2" <<'EOF'
name: {{ workshop_name }}
base: ubuntu@26.04
sdks:
{% include 'partials/sdks-chain.yaml.j2' -%}
{% include 'partials/actions.yaml.j2' -%}
EOF
}

test_happy_render_fixture_instance() (
    local root output out
    root=$(new_root); make_fixture "${root}"
    output=$(run_render "${root}" fixture-foo) || fail "happy render failed: ${output}"
    out="${root}/.workshop/fixture-foo.yaml"
    [[ -f "${out}" ]] || fail "rendered file ${out} is missing."
    grep -q '^name: fixture-foo$' "${out}" || fail "rendered name is not the instance name."
    grep -q '^base: ubuntu@26.04$' "${out}" || fail "rendered base: is missing."
    grep -q '^profile: fixture$' "${out}" || fail "resolved profile did not flow into the render."
    grep -q '^suffix: foo$' "${out}" || fail "resolved suffix did not flow into the render."
    grep -q '^marker: from-vars-json$' "${out}" || fail "profile vars.json did not flow into the render."
    grep -q 'profile: fixture' <<<"${output}" || fail "success message does not name the profile."
)

test_happy_render_bare_profile() (
    local root output out
    root=$(new_root); make_fixture "${root}"
    output=$(run_render "${root}" fixture) || fail "bare-profile render failed: ${output}"
    out="${root}/.workshop/fixture.yaml"
    [[ -f "${out}" ]] || fail "rendered file ${out} is missing."
    grep -q '^name: fixture$' "${out}" || fail "bare profile did not render under its own name."
    grep -q '^suffix: $' "${out}" || fail "bare profile should render an empty suffix."
)

test_unknown_prefix_exit_3() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    set +e
    output=$(run_render "${root}" bogus 2>&1); status=$?
    set -e
    [[ ${status} -eq 3 ]] || fail "unknown prefix exited ${status}, want 3: ${output}"
    grep -q 'valid profiles:.*fixture' <<<"${output}" || fail "exit-3 message does not list valid profiles."
    [[ ! -e "${root}/.workshop/bogus.yaml" ]] || fail "exit-3 run still wrote an output file."
)

test_invalid_name_exit_4() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    set +e
    output=$(run_render "${root}" 1bad 2>&1); status=$?
    set -e
    [[ ${status} -eq 4 ]] || fail "invalid name exited ${status}, want 4: ${output}"
    grep -q 'invalid workshop name' <<<"${output}" || fail "exit-4 message does not state the name rules."
    [[ ! -e "${root}/.workshop/1bad.yaml" ]] || fail "exit-4 run still wrote an output file."
)

test_workshop_dir_collision_exit_5() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    mkdir -p "${root}/.workshop/fixture-tools"
    set +e
    output=$(run_render "${root}" fixture-tools 2>&1); status=$?
    set -e
    [[ ${status} -eq 5 ]] || fail ".workshop collision exited ${status}, want 5: ${output}"
    grep -q 'already exists' <<<"${output}" || fail "exit-5 message does not name the collision."
    [[ ! -e "${root}/.workshop/fixture-tools.yaml" ]] || fail "exit-5 run still wrote an output file."
)

test_rerender_is_byte_identical() (
    local root
    root=$(new_root); make_fixture "${root}"
    run_render "${root}" fixture-foo >/dev/null || fail "first render failed."
    cp "${root}/.workshop/fixture-foo.yaml" "${root}/first.yaml"
    run_render "${root}" fixture-foo >/dev/null || fail "re-render failed."
    cmp "${root}/first.yaml" "${root}/.workshop/fixture-foo.yaml" \
        || fail "re-render is not byte-identical."
)

test_temp_files_cleaned_up() (
    shopt -s nullglob dotglob
    local root output leftovers
    root=$(new_root); make_fixture "${root}"
    output=$(run_render "${root}" fixture-foo) || fail "render failed: ${output}"
    # Glob *.json, not *: uv keeps its own lock file in TMPDIR.
    leftovers=("${root}/tmp"/*.json)
    [[ ${#leftovers[@]} -eq 0 ]] || fail "VARS_TMP leaked into TMPDIR: ${leftovers[*]}"
    leftovers=("${root}/.workshop"/*)
    [[ ${#leftovers[@]} -eq 1 && ${leftovers[0]} == "${root}/.workshop/fixture-foo.yaml" ]] \
        || fail "stray temp files in .workshop: ${leftovers[*]}"
)

test_shadow_warning_printed() (
    local root output
    root=$(new_root); make_fixture "${root}"
    # A later-added profile dir shadows the launched instance (D-13): warn, still render.
    cp -r "${root}/profiles/fixture" "${root}/profiles/fixture-foo"
    mkdir -p "${root}/.workshop/fixture-foo"
    output=$(run_render "${root}" fixture-foo 2>&1) || fail "shadow render failed: ${output}"
    grep -qi 'warning:.*shadow' <<<"${output}" || fail "shadow warning was not printed: ${output}"
    grep -q '^name: fixture-foo$' "${root}/.workshop/fixture-foo.yaml" \
        || fail "shadow render wrote the wrong name."
)

test_post_validation_blocks_bad_render() (
    local root output status
    root=$(new_root); make_fixture "${root}"
    # Case 1: the template renders a name that is not the requested NAME.
    printf 'name: not-the-name\nbase: ubuntu@26.04\n' > "${root}/profiles/fixture/workshop.yaml.j2"
    set +e
    output=$(run_render "${root}" fixture-foo 2>&1); status=$?
    set -e
    [[ ${status} -eq 2 ]] || fail "wrong-name render exited ${status}, want 2: ${output}"
    grep -q 'post-validation failed' <<<"${output}" || fail "post-validation diagnostic missing: ${output}"
    [[ ! -e "${root}/.workshop/fixture-foo.yaml" ]] || fail "target written despite failed validation."
    # Case 2: the template renders text that is not YAML at all.
    printf 'name: [unclosed\n' > "${root}/profiles/fixture/workshop.yaml.j2"
    set +e
    output=$(run_render "${root}" fixture-foo 2>&1); status=$?
    set -e
    [[ ${status} -eq 2 ]] || fail "non-YAML render exited ${status}, want 2: ${output}"
    grep -q 'does not parse as YAML' <<<"${output}" || fail "YAML parse diagnostic missing: ${output}"
    [[ ! -e "${root}/.workshop/fixture-foo.yaml" ]] || fail "target written despite unparseable render."
)

test_missing_template_exit_2() (
    local root output status
    root=$(new_root)
    mkdir -p "${root}/profiles/fixture" "${root}/config" "${root}/tmp"
    set +e
    output=$(run_render "${root}" fixture 2>&1); status=$?
    set -e
    [[ ${status} -eq 2 ]] || fail "missing template exited ${status}, want 2: ${output}"
    grep -q 'workshop.yaml.j2 is missing' <<<"${output}" \
        || fail "missing-template diagnostic absent: ${output}"
)

# Format equivalence: the same user layer content as config/local/vars/all.json
# in one root and all.yaml in another must render byte-identical workshop yaml.
test_layer_format_equivalence_json_vs_yaml() (
    local root_json root_yaml
    root_json=$(new_root); make_partials_fixture "${root_json}"
    root_yaml=$(new_root); make_partials_fixture "${root_yaml}"
    mkdir -p "${root_json}/config/local/vars" "${root_yaml}/config/local/vars"
    cat > "${root_json}/config/local/vars/all.json" <<'EOF'
{
  "sdks": {
    "add": [
      {"name": "extra-one", "channel": "latest/candidate", "plugs": ["home"]}
    ]
  },
  "actions": {
    "fmt-probe": "echo json-vs-yaml\n- dash line\nexit 0"
  }
}
EOF
    cat > "${root_yaml}/config/local/vars/all.yaml" <<'EOF'
sdks:
  add:
    - name: extra-one
      channel: latest/candidate
      plugs:
        - home
actions:
  fmt-probe: |-
    echo json-vs-yaml
    - dash line
    exit 0
EOF
    run_render_layers "${root_json}" fixture-fmt >/dev/null \
        || fail "json-layer render failed."
    run_render_layers "${root_yaml}" fixture-fmt >/dev/null \
        || fail "yaml-layer render failed."
    cmp "${root_json}/.workshop/fixture-fmt.yaml" "${root_yaml}/.workshop/fixture-fmt.yaml" \
        || fail "json vs yaml user layer rendered different bytes."
    grep -q '^actions:$' "${root_json}/.workshop/fixture-fmt.yaml" \
        || fail "equivalence render is missing the top-level actions: block."
    grep -q '^  fmt-probe: |-$' "${root_json}/.workshop/fixture-fmt.yaml" \
        || fail "equivalence render is missing the fmt-probe block scalar."
)

# Synthetic actions: a user layer with two actions (one multi-line body) must
# render a well-formed top-level actions: block that the vendored schema
# accepts (check-render.sh), and an empty mapping must emit zero bytes.
test_synthetic_actions_wellformed() (
    local root out
    root=$(new_root); make_partials_fixture "${root}"
    mkdir -p "${root}/config/local/vars"
    cat > "${root}/config/local/vars/all.yaml" <<'EOF'
actions:
  web-rebuild: |-
    set -e
    snapcraft pack
    - echo dash-line
    echo done
  ping: "echo pong"
EOF
    run_render_layers "${root}" fixture-act >/dev/null \
        || fail "synthetic-actions render failed."
    out="${root}/.workshop/fixture-act.yaml"
    grep -q '^actions:$' "${out}" || fail "rendered yaml has no top-level actions: block."
    grep -q '^  web-rebuild: |-$' "${out}" || fail "multi-line action is not a |- block scalar."
    grep -q '^    - echo dash-line$' "${out}" || fail "dash-leading body line is not indented into the scalar."
    grep -q '^  ping: |-$' "${out}" || fail "single-line action is not a |- block scalar."
    bash "${PROJECT_DIR}/scripts/check-render.sh" "${out}" >/dev/null \
        || fail "synthetic-actions render failed vendored-schema validation."
    # Empty actions mapping: the actions partial must emit zero bytes (plan
    # trap 10), so the render is byte-identical to a no-layer render of the
    # same name in a twin root.
    local root_empty root_plain
    root_empty=$(new_root); make_partials_fixture "${root_empty}"
    root_plain=$(new_root); make_partials_fixture "${root_plain}"
    mkdir -p "${root_empty}/config/local/vars"
    printf 'actions: {}\n' > "${root_empty}/config/local/vars/all.yaml"
    run_render_layers "${root_empty}" fixture >/dev/null \
        || fail "empty-actions render failed."
    run_render_layers "${root_plain}" fixture >/dev/null \
        || fail "no-layer render failed."
    if grep -q '^actions:$' "${root_empty}/.workshop/fixture.yaml"; then
        fail "empty actions mapping still emitted an actions: block."
    fi
    cmp "${root_empty}/.workshop/fixture.yaml" "${root_plain}/.workshop/fixture.yaml" \
        || fail "empty actions mapping changed the rendered bytes."
)

test_happy_render_fixture_instance
test_happy_render_bare_profile
test_unknown_prefix_exit_3
test_invalid_name_exit_4
test_workshop_dir_collision_exit_5
test_rerender_is_byte_identical
test_temp_files_cleaned_up
test_shadow_warning_printed
test_post_validation_blocks_bad_render
test_missing_template_exit_2
test_layer_format_equivalence_json_vs_yaml
test_synthetic_actions_wellformed
echo "render tests passed."
