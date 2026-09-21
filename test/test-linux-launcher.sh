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
chmod +x "$TMP/bin/bwrap" "$TMP/bin/realpath" "$TMP/bin/codex" "$TMP/bin/claude"

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
