#!/bin/bash
# Exercise Linux launcher argument construction with a fake bwrap. This is
# intentionally host-independent: bwrap receives the complete argv and exits
# without creating namespaces or touching the paths it was asked to mount.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/ccode"
TMP=$(mktemp -d -t mozsb-linux-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/rw"
HOST_REALPATH=$(command -v realpath)

cat > "$TMP/bin/bwrap" <<'STUB'
#!/bin/bash
printf 'ARG=%s\n' "$@"
STUB
cat > "$TMP/bin/realpath" <<'STUB'
#!/bin/bash
# GNU realpath accepts -m; the macOS implementation used by this host-side
# launcher test does not. All test paths exist, so plain realpath is enough.
if [[ "${1:-}" == "-m" ]]; then shift; fi
"$HOST_REALPATH" "$@"
STUB
cat > "$TMP/bin/codex" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$TMP/bin/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$TMP/bin/pi" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TMP/bin/bwrap" "$TMP/bin/realpath" "$TMP/bin/codex" "$TMP/bin/claude" "$TMP/bin/pi"

PASS=0
FAIL=0
ok()   { echo "  ok    $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=$((FAIL+1)); }

run_launcher() {
    cd "$TMP/rw" || return
    PATH="$TMP/bin:$PATH" HOST_REALPATH="$HOST_REALPATH" MOZSB_SRC="$TMP/rw" MOZSB_NO_SSH_AGENT=1 \
        "$SCRIPT" "$@" 2>&1
}

codex_output=$(MOZSB_CODEX_BIN="$TMP/bin/codex" run_launcher codex exec marker)
if grep -q '^ARG=--dangerously-bypass-approvals-and-sandbox$' <<<"$codex_output" && \
   grep -q '^ARG=exec$' <<<"$codex_output" && grep -q '^ARG=marker$' <<<"$codex_output"; then
    ok "Codex receives forced outer-sandbox flag and user args"
else
    fail "Codex receives forced outer-sandbox flag and user args"
fi
if grep -q "$HOME/.codex" <<<"$codex_output" && ! grep -q "$HOME/.claude" <<<"$codex_output"; then
    ok "Codex bwrap mounts expose Codex state only"
else
    fail "Codex bwrap mounts expose Codex state only"
fi

pi_output=$(MOZSB_PI_BIN="$TMP/bin/pi" run_launcher pi marker)
if [[ "$(tail -n 2 <<<"$pi_output")" == "ARG=$(realpath "$TMP/bin/pi")"$'\nARG=marker' ]]; then
    ok "Pi receives user args without extra flags"
else
    fail "Pi receives user args without extra flags"
fi
if grep -q "$HOME/.pi/agent" <<<"$pi_output" && ! grep -q "$HOME/.claude" <<<"$pi_output" && \
   ! grep -q "$HOME/.codex" <<<"$pi_output"; then
    ok "Pi bwrap mounts expose Pi state only"
else
    fail "Pi bwrap mounts expose Pi state only"
fi
if grep -A2 '^ARG=--ro-bind-try$' <<<"$pi_output" | grep -q "^ARG=$HOME/.pi/agent/install$"; then
    ok "Pi install directory is mounted read-only"
else
    fail "Pi install directory is mounted read-only"
fi

check_codex_args() {
    local desc="$1" expected="$2"; shift 2
    local output received lines
    if ! output=$(MOZSB_CODEX_BIN="$TMP/bin/codex" run_launcher codex "$@"); then
        fail "$desc (launcher failed)"
        return
    fi
    lines=$(printf '%s\n' "$expected" | wc -l)
    received=$(printf '%s\n' "$output" | tail -n "$lines")
    if [[ "$received" == "$expected" ]]; then ok "$desc"; else fail "$desc"; fi
    if grep -q 'Terminated:' <<<"$output"; then fail "$desc (open-server cleanup)"; fi
}

forced=$'ARG=--dangerously-bypass-approvals-and-sandbox\nARG=--no-daemon'
check_codex_args "Codex startup avoids host daemon" "$forced"
check_codex_args "Codex resume avoids host daemon" "$forced"$'\nARG=resume\nARG=--last' resume --last
check_codex_args "Codex fork avoids host daemon" "$forced"$'\nARG=fork\nARG=session-id' fork session-id
check_codex_args "Codex exec preserves prompt" "$forced"$'\nARG=exec\nARG=prompt with spaces' exec "prompt with spaces"
check_codex_args "explicit no-daemon is not duplicated" "$forced" --no-daemon
check_codex_args "resume no-daemon is not duplicated" \
    $'ARG=--dangerously-bypass-approvals-and-sandbox\nARG=resume\nARG=--no-daemon\nARG=--last' resume --no-daemon --last
check_codex_args "no-daemon after separator remains a prompt" "$forced"$'\nARG=--\nARG=--no-daemon' -- --no-daemon

claude_output=$(MOZSB_CLAUDE_BIN="$TMP/bin/claude" run_launcher claude marker)
if grep -q '^ARG=--permission-mode$' <<<"$claude_output" && \
   grep -q '^ARG=bypassPermissions$' <<<"$claude_output" && grep -q '^ARG=marker$' <<<"$claude_output"; then
    ok "Claude receives forced bypassPermissions flag and user args"
else
    fail "Claude receives forced bypassPermissions flag and user args"
fi
if grep -q "$HOME/.claude" <<<"$claude_output" && ! grep -q "$HOME/.codex" <<<"$claude_output"; then
    ok "Claude bwrap mounts expose Claude state only"
else
    fail "Claude bwrap mounts expose Claude state only"
fi

exec_output=$(run_launcher exec /usr/bin/true)
if ! grep -q "$HOME/.claude" <<<"$exec_output" && ! grep -q "$HOME/.codex" <<<"$exec_output"; then
    ok "exec bwrap mounts expose no agent state"
else
    fail "exec bwrap mounts expose no agent state"
fi
if grep -q "$HOME/.profiler-cli" <<<"$exec_output"; then
    ok "shared profiler state is mounted read-write"
else
    fail "shared profiler state is mounted read-write"
fi
if grep -qE '/\.(bashrc|bash_profile|bash_login|profile|zshrc|zprofile|zshenv|zlogin)$' <<<"$exec_output"; then
    fail "personal shell startup files are not exposed"
else
    ok "personal shell startup files are not exposed"
fi

if (cd "$HOME" && PATH="$TMP/bin:$PATH" HOST_REALPATH="$HOST_REALPATH" MOZSB_SRC="$TMP/rw" \
    "$SCRIPT" exec /usr/bin/true >/dev/null 2>&1); then
    fail "launching from HOME outside the source root is rejected"
else
    ok "launching from HOME outside the source root is rejected"
fi

if MOZBUILD_STATE_PATH="$TMP/rw-other" run_launcher exec /usr/bin/true >/dev/null 2>&1; then
    fail "source-root prefix siblings are rejected"
else
    ok "source-root prefix siblings are rejected"
fi


mkdir -p "$TMP/reference data" "$TMP/rw/read-only" "$TMP/extra-bin"
ln -s "$TMP/reference data" "$TMP/reference-link"
ro_output=$(MOZSB_EXTRA_RO_DIRS="$TMP/reference-link:$TMP/rw/read-only" \
    MOZSB_EXTRA_BIN_DIR="$TMP/extra-bin" run_launcher exec /usr/bin/true)
for ro_dir in "$TMP/reference data" "$TMP/rw/read-only"; do
    ro_dir=$("$HOST_REALPATH" "$ro_dir")
    binding=$(printf 'ARG=--ro-bind\nARG=%s\nARG=%s' "$ro_dir" "$ro_dir")
    if [[ "$ro_output" == *"$binding"* ]]; then
        ok "extra read-only directory is mounted: $ro_dir"
    else
        fail "extra read-only directory is mounted: $ro_dir"
    fi
done
sandbox_path=$(awk '/^ARG=PATH$/ { getline; print; exit }' <<<"$ro_output")
if [[ "$sandbox_path" == "ARG=$TMP/extra-bin:"* && "$sandbox_path" != *"$TMP/reference"* && "$sandbox_path" != *"$TMP/rw/read-only"* ]]; then
    ok "extra read-only directories stay out of PATH; bin directory stays in PATH"
else
    fail "extra read-only directories stay out of PATH; bin directory stays in PATH"
fi
if MOZSB_EXTRA_RO_DIRS="$TMP/missing" run_launcher exec /usr/bin/true >/dev/null 2>&1; then
    fail "missing read-only directory is rejected"
else
    ok "missing read-only directory is rejected"
fi

cat > "$TMP/env" <<EOF
# comment
export CLAUDE_CODE_EFFORT_LEVEL=xhigh
QUOTED="spaced value"
TILDE=~/somewhere

not a valid line
BAD-KEY=x
CLAUDE_CONFIG_DIR=$TMP/cfg
EOF
env_output=$(MOZSB_ENV_FILE="$TMP/env" run_launcher exec /usr/bin/true)
if grep -q '^ARG=CLAUDE_CODE_EFFORT_LEVEL$' <<<"$env_output" && grep -q '^ARG=xhigh$' <<<"$env_output" && \
   grep -q '^ARG=spaced value$' <<<"$env_output" && grep -q "^ARG=$HOME/somewhere\$" <<<"$env_output"; then
    ok "env file entries reach the sandbox, unquoted and ~-expanded"
else
    fail "env file entries reach the sandbox, unquoted and ~-expanded"
fi
if grep -q 'ignoring malformed line.*not a valid line' <<<"$env_output" && \
   grep -q 'ignoring malformed line.*BAD-KEY=x' <<<"$env_output" && \
   ! grep -q '^ARG=BAD-KEY$' <<<"$env_output"; then
    ok "malformed env file lines are reported and skipped"
else
    fail "malformed env file lines are reported and skipped"
fi
if grep -q "^ARG=$TMP/cfg\$" <<<"$env_output" && [[ -d "$TMP/cfg" ]]; then
    ok "CLAUDE_CONFIG_DIR from the env file is created and bound"
else
    fail "CLAUDE_CONFIG_DIR from the env file is created and bound"
fi

echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
