#!/bin/bash
#
# test-macos.sh — sandbox profile + script tests for ccode-macos.
#
# Two layers of tests:
#   1. Profile semantics: take the exact profile ccode-macos would use
#      (via `ccode-macos --print-profile`) and probe it with sandbox-exec
#      against a series of read/write/exec scenarios.
#   2. Script env handling: invoke ccode-macos with stub agent binaries
#      that prints its environment, and verify env -i drops host secrets
#      while forwarding the expected toolchain redirects.
#
# No real agent install is required for the launcher tests.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/ccode-macos"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "test-macos.sh: skipped (not macOS)" >&2
    exit 0
fi
if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not executable" >&2
    exit 2
fi

TMP=$(mktemp -d -t ccode-test)
trap 'rm -rf "$TMP"' EXIT

TEST_RW="$TMP/rw-root"
mkdir -p "$TEST_RW"
cd "$TEST_RW" || exit 2

PASS=0
FAIL=0
ok()   { echo "  ok    $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1${2+ -- $2}" >&2; FAIL=$((FAIL+1)); }

# expect <desc> <ok|deny> <command...>
# Runs the command and asserts exit-zero (ok) or non-zero (deny).
expect() {
    local desc="$1" expected="$2"; shift 2
    local out exit
    out=$("$@" 2>&1); exit=$?
    case "$expected" in
        ok)   if [[ $exit -eq 0 ]]; then ok "$desc"; else fail "$desc" "exit=$exit out=$(printf %q "$out")"; fi ;;
        deny) if [[ $exit -ne 0 ]]; then ok "$desc (denied)"; else fail "$desc" "expected deny but exit=0"; fi ;;
        *) fail "$desc" "bad expectation: $expected" ;;
    esac
}

# Generate the profile that ccode-macos would use, with a test RW root.
PROFILE_FILE="$TMP/profile.sb"
MOZSB_SRC="$TEST_RW" "$SCRIPT" --print-profile claude > "$PROFILE_FILE" \
    || { echo "FATAL: failed to generate profile"; exit 2; }

run_sb() { sandbox-exec -f "$PROFILE_FILE" "$@"; }

echo "==== profile: positive (should succeed) ===="
expect "exec /usr/bin/true"          ok run_sb /usr/bin/true
expect "read /etc/hosts"             ok run_sb /bin/cat /etc/hosts
expect "list /usr/bin"               ok run_sb /bin/ls /usr/bin
expect "stat \$HOME"                 ok run_sb /bin/test -d "$HOME"
expect "read \$HOME/.gitconfig"      ok run_sb /bin/cat "$HOME/.gitconfig"
expect "write to RW_ROOT"            ok run_sb /bin/sh -c "echo x > $TEST_RW/probe"
expect "RW_ROOT write took effect"   ok run_sb /usr/bin/grep -q '^x$' "$TEST_RW/probe"
expect "write to /tmp"               ok run_sb /bin/sh -c "echo x > /tmp/ccode-test-tmp && rm /tmp/ccode-test-tmp"
expect "write to ~/.claude (shared with host)" ok run_sb /bin/sh -c "mkdir -p '$HOME/.claude' && touch '$HOME/.claude/.ccode-test-probe' && rm '$HOME/.claude/.ccode-test-probe'"
expect "write to ~/.profiler-cli" ok run_sb /bin/sh -c "touch '$HOME/.profiler-cli/.mozsb-test-probe' && rm '$HOME/.profiler-cli/.mozsb-test-probe'"

echo
echo "==== profile: negative (should be denied) ===="
expect "deny write to \$HOME root"   deny run_sb /bin/sh -c "echo bad > $HOME/.ccode-test-bad-DELETE-ME"
expect "deny write to ~/.gitconfig"  deny run_sb /bin/sh -c "echo bad >> $HOME/.gitconfig"
expect "deny write to /etc"          deny run_sb /bin/sh -c "echo bad > /etc/ccode-test-bad"
expect "deny write to /usr/bin"      deny run_sb /bin/sh -c "echo bad > /usr/bin/ccode-test-bad"
# Ensure ssh private keys cannot be read. If no key exists yet, sandbox-exec
# still denies the open before ENOENT is reached, so this remains a useful
# probe regardless.
expect "deny read of ~/.ssh/id_rsa"      deny run_sb /bin/cat "$HOME/.ssh/id_rsa"
expect "deny read of ~/.ssh/id_ed25519"  deny run_sb /bin/cat "$HOME/.ssh/id_ed25519"
expect "deny ls of ~/Documents"      deny run_sb /bin/ls "$HOME/Documents"
# ~/Library/Keychains is intentionally rw — Claude Code on macOS stores
# its OAuth token there and rewrites it on /login (token refresh).
# Per-entry access is still gated by securityd ACLs (consent prompt for
# unrelated entries), but the file-level access has to be allowed.
expect "read ~/Library/Keychains (claude OAuth needs RW)" ok run_sb /bin/test -r "$HOME/Library/Keychains"
# Pasteboard remains available for Firefox compatibility.
# (AppleEvents is *not* tested here: on modern macOS, cross-app scripting
# is gated by TCC/entitlements rather than mach-lookup, so a sandbox-exec
# deny does not reliably block `osascript -e 'tell app …'`. The deny rule
# is kept in the profile as an extra layer but cannot be asserted on.)
# Do not overwrite the host clipboard while testing sandbox permissions.
# Belt-and-braces cleanup in case any of the above accidentally created files.
rm -f "$HOME/.ccode-test-bad-DELETE-ME" "$HOME/.claude/.ccode-test-bad-DELETE-ME" 2>/dev/null

echo
echo "==== script: env handling (env -i + redirects) ===="
mkdir -p "$TMP/stub-bin"
cat > "$TMP/stub-bin/claude" <<'STUB'
#!/bin/bash
# Test stub: print the arguments and environment it received.
printf 'ARG=%s\n' "$@"
env
STUB
chmod +x "$TMP/stub-bin/claude"

# Set a host-only env var that must NOT cross env -i, plus a tame value
# to confirm forwarding works for variables the script does export.
export CCODE_TEST_HOST_SECRET="must-not-leak"
output=$(PATH="$TMP/stub-bin:$PATH" MOZSB_CLAUDE_BIN="$TMP/stub-bin/claude" MOZSB_SRC="$TEST_RW" "$SCRIPT" claude 2>&1)

check() {
    local desc="$1" pattern="$2" mode="$3"
    if grep -qE "$pattern" <<<"$output"; then
        case "$mode" in
            present) ok "$desc" ;;
            absent)  fail "$desc" "pattern '$pattern' was present" ;;
        esac
    else
        case "$mode" in
            present) fail "$desc" "pattern '$pattern' missing from env output" ;;
            absent)  ok "$desc" ;;
        esac
    fi
}

check "CARGO_HOME redirected to ~/.sandbox/cargo" '^CARGO_HOME=.*\.sandbox/cargo$'  present
check "UV_CACHE_DIR redirected"                   '^UV_CACHE_DIR=.*\.sandbox/uv$'   present
check "GOPATH redirected"                         '^GOPATH=.*\.sandbox/go$'         present
check "GOMODCACHE redirected"                     '^GOMODCACHE=.*\.sandbox/go/pkg/mod$' present
check "NPM_CONFIG_CACHE redirected"               '^NPM_CONFIG_CACHE=.*\.sandbox/npm$'  present
# The global prefix goes through an npmrc rather than NPM_CONFIG_PREFIX:
# nvm refuses to activate a node version while that variable is set.
check "npm userconfig redirected"                 '^NPM_CONFIG_USERCONFIG=.*\.sandbox/npmrc$' present
check "NPM_CONFIG_PREFIX not set (breaks nvm)"    '^NPM_CONFIG_PREFIX='             absent
check "PIP_CACHE_DIR redirected"                  '^PIP_CACHE_DIR=.*\.sandbox/pip$' present
check "RUSTUP_HOME points at host (read-only)"    '^RUSTUP_HOME=.*/\.rustup$'       present
check "git core.hooksPath override set"           '^GIT_CONFIG_KEY_0=core\.hooksPath$' present
check "git hooks redirected to empty dir"         '^GIT_CONFIG_VALUE_0=.*\.sandbox/empty-hooks$' present
check "HOME forwarded"                            '^HOME='                          present
check "host secret blocked by env -i"             '^CCODE_TEST_HOST_SECRET='        absent

# CLAUDE_CODE_OAUTH_TOKEN must NOT be forwarded: the sandbox shares the
# host keychain rw, and an env-var token alongside the keychain-managed
# key triggers a "Auth conflict" warning in Claude Code.
if grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$output"; then
    fail "CLAUDE_CODE_OAUTH_TOKEN not forwarded" "env var was set, conflicts with keychain"
else
    ok "CLAUDE_CODE_OAUTH_TOKEN not forwarded (keychain is sole source of truth)"
fi

echo
echo "==== noexec: opt-in via MOZSB_NOEXEC=1 ===="
# Stub claude that writes a fresh executable file inside RW_ROOT and exits.
# After ccode-macos returns, the file should still exist but its +x bit
# must be stripped.
mkdir -p "$TMP/noexec-stub"
cat > "$TMP/noexec-stub/claude" <<STUB
#!/bin/bash
# Write a script with +x to the workdir. The ccode-macos EXIT trap should
# strip the +x bit when MOZSB_NOEXEC=1.
printf '%s\n' '#!/bin/bash' 'echo evil' > '$TEST_RW/sandbox-built-binary'
chmod +x '$TEST_RW/sandbox-built-binary'
STUB
chmod +x "$TMP/noexec-stub/claude"

PATH="$TMP/noexec-stub:$PATH" MOZSB_CLAUDE_BIN="$TMP/noexec-stub/claude" MOZSB_SRC="$TEST_RW" MOZSB_NOEXEC=1 "$SCRIPT" claude >/dev/null 2>&1 || true

if [[ -f "$TEST_RW/sandbox-built-binary" ]]; then
    ok "sandbox-built file persists after exit"
    if [[ -x "$TEST_RW/sandbox-built-binary" ]]; then
        fail "noexec stripped +x from new sandbox-built file" "+x still set"
    else
        ok "noexec stripped +x from new sandbox-built file"
    fi
else
    fail "sandbox-built file persists after exit" "file missing — stub did not run"
fi

# Counter-test: when MOZSB_NOEXEC is unset, the +x bit is preserved.
rm -f "$TEST_RW/sandbox-built-binary"
PATH="$TMP/noexec-stub:$PATH" MOZSB_CLAUDE_BIN="$TMP/noexec-stub/claude" MOZSB_SRC="$TEST_RW" "$SCRIPT" claude >/dev/null 2>&1 || true
if [[ -x "$TEST_RW/sandbox-built-binary" ]]; then
    ok "without MOZSB_NOEXEC, +x is preserved"
else
    fail "without MOZSB_NOEXEC, +x is preserved" "+x stripped even without opt-in"
fi
rm -f "$TEST_RW/sandbox-built-binary"

echo
echo "==== agent isolation and forced flags ===="
cat > "$TMP/stub-bin/codex" <<'STUB'
#!/bin/bash
printf 'ARG=%s\n' "$@"
STUB
chmod +x "$TMP/stub-bin/codex"

claude_profile=$(MOZSB_CLAUDE_BIN="$TMP/stub-bin/claude" MOZSB_SRC="$TEST_RW" "$SCRIPT" --print-profile claude)
codex_profile=$(MOZSB_CODEX_BIN="$TMP/stub-bin/codex" MOZSB_SRC="$TEST_RW" "$SCRIPT" --print-profile codex)
exec_profile=$(MOZSB_SRC="$TEST_RW" "$SCRIPT" --print-profile exec /usr/bin/true)

if grep -q "$HOME/.claude" <<<"$claude_profile" && ! grep -q "$HOME/.codex" <<<"$claude_profile"; then
    ok "Claude profile exposes Claude state only"
else
    fail "Claude profile exposes Claude state only"
fi
if grep -q "$HOME/.codex" <<<"$codex_profile" && \
   ! grep -q "$HOME/.claude" <<<"$codex_profile" && \
   ! grep -q "$HOME/Library/Keychains" <<<"$codex_profile"; then
    ok "Codex profile exposes Codex state only"
else
    fail "Codex profile exposes Codex state only"
fi
if ! grep -q "$HOME/.claude" <<<"$exec_profile" && ! grep -q "$HOME/.codex" <<<"$exec_profile"; then
    ok "exec profile exposes no agent state"
else
    fail "exec profile exposes no agent state"
fi

codex_output=$(MOZSB_CODEX_BIN="$TMP/stub-bin/codex" MOZSB_SRC="$TEST_RW" "$SCRIPT" codex exec marker 2>&1)
if grep -q '^ARG=--dangerously-bypass-approvals-and-sandbox$' <<<"$codex_output" && \
   grep -q '^ARG=exec$' <<<"$codex_output" && grep -q '^ARG=marker$' <<<"$codex_output"; then
    ok "Codex receives forced outer-sandbox flag and user args"
else
    fail "Codex receives forced outer-sandbox flag and user args" "got: $codex_output"
fi
if grep -q '^ARG=--permission-mode$' <(MOZSB_CLAUDE_BIN="$TMP/stub-bin/claude" MOZSB_SRC="$TEST_RW" "$SCRIPT" claude 2>&1); then
    ok "Claude receives forced bypassPermissions flag"
else
    fail "Claude receives forced bypassPermissions flag"
fi

echo
echo "==== summary ===="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
exit 0
