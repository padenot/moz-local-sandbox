#!/bin/bash
#
# test-macos.sh — sandbox profile + script tests for ccode-macos.
#
# Two layers of tests:
#   1. Profile semantics: take the exact profile ccode-macos would use
#      (via `ccode-macos --print-profile`) and probe it with sandbox-exec
#      against a series of read/write/exec scenarios.
#   2. Script env handling: invoke ccode-macos with a stub `claude` binary
#      that prints its environment, and verify env -i drops host secrets
#      while forwarding the expected toolchain redirects.
#
# No real claude install is required to run these tests.

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
CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile > "$PROFILE_FILE" \
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
# Pasteboard mach service denied — pbcopy should fail to talk to it.
# (AppleEvents is *not* tested here: on modern macOS, cross-app scripting
# is gated by TCC/entitlements rather than mach-lookup, so a sandbox-exec
# deny does not reliably block `osascript -e 'tell app …'`. The deny rule
# is kept in the profile as an extra layer but cannot be asserted on.)
expect "deny pbcopy (clipboard)"     deny run_sb /bin/sh -c "echo test | /usr/bin/pbcopy"
# Belt-and-braces cleanup in case any of the above accidentally created files.
rm -f "$HOME/.ccode-test-bad-DELETE-ME" "$HOME/.claude/.ccode-test-bad-DELETE-ME" 2>/dev/null

echo
echo "==== rw resolution: env, config, precedence ===="
# These tests probe the SRC / CWD_ONLY resolution logic in ccode-macos by
# inspecting which (subpath …) rules end up in the emitted sandbox profile.
TEST_RW2="$TMP/rw-second"; mkdir -p "$TEST_RW2"
TEST_RW3="$TMP/rw-third";  mkdir -p "$TEST_RW3"
CFG_DIR="$TMP/cfg-dir";    mkdir -p "$CFG_DIR"

expect_subpath() {
    local desc="$1" profile="$2" path="$3"
    if grep -qF "(subpath \"$path\")" <<<"$profile"; then
        ok "$desc"
    else
        fail "$desc" "missing (subpath \"$path\")"
    fi
}
expect_no_subpath() {
    local desc="$1" profile="$2" path="$3"
    if grep -qF "(subpath \"$path\")" <<<"$profile"; then
        fail "$desc" "unexpected (subpath \"$path\")"
    else
        ok "$desc"
    fi
}
write_cfg() { printf '%s\n' "$@" > "$CFG_DIR/ccode"; }

# Empty config — keeps the file's mere presence from changing behaviour.
: > "$CFG_DIR/ccode"

# env CCODE_SRC: single path becomes a subpath rule.
prof=$(CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "CCODE_SRC=path -> subpath rule"             "$prof" "$TEST_RW"

# env CCODE_SRC: ':' separator exposes multiple trees.
prof=$(CCODE_SRC="$TEST_RW:$TEST_RW2" "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "CCODE_SRC=a:b -> first tree as subpath"     "$prof" "$TEST_RW"
expect_subpath "CCODE_SRC=a:b -> second tree as subpath"    "$prof" "$TEST_RW2"

# env CCODE_CWD_ONLY=1 short-circuits SRC.
prof=$(CCODE_SRC="$TEST_RW" CCODE_CWD_ONLY=1 "$SCRIPT" --print-profile 2>/dev/null)
expect_no_subpath "CCODE_CWD_ONLY=1 drops CCODE_SRC trees"  "$prof" "$TEST_RW"

# Non-existent rw path is skipped with a warning; siblings survive.
out=$(CCODE_SRC="$TEST_RW:/this/does/not/exist" "$SCRIPT" --print-profile 2>&1)
expect_subpath "missing rw path skipped, sibling survives"  "$out"  "$TEST_RW"
if grep -q '^ccode: warning.*does not exist.*does/not/exist' <<<"$out"; then
    ok "missing rw path emits a warning"
else
    fail "missing rw path emits a warning" "no warning matched"
fi

# config file: global SRC used when no [section] matches.
write_cfg "SRC = $TEST_RW" "SRC = $TEST_RW2"
prof=$(XDG_CONFIG_HOME="$CFG_DIR" "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "config global SRC #1 -> subpath"            "$prof" "$TEST_RW"
expect_subpath "config global SRC #2 -> subpath"            "$prof" "$TEST_RW2"

# config file: matching [section] overrides global SRC.
write_cfg "SRC = $TEST_RW" "[$REPO]" "SRC = $TEST_RW2" "SRC = $TEST_RW3"
prof=$(XDG_CONFIG_HOME="$CFG_DIR" "$SCRIPT" --print-profile 2>/dev/null)
expect_no_subpath "matching section drops global SRC"       "$prof" "$TEST_RW"
expect_subpath "matching section SRC #1"                    "$prof" "$TEST_RW2"
expect_subpath "matching section SRC #2"                    "$prof" "$TEST_RW3"

# config file: CWD_ONLY=1 inside the matching section drops all SRC.
write_cfg "SRC = $TEST_RW" "[$REPO]" "SRC = $TEST_RW2" "CWD_ONLY = 1"
prof=$(XDG_CONFIG_HOME="$CFG_DIR" "$SCRIPT" --print-profile 2>/dev/null)
expect_no_subpath "section CWD_ONLY=1 drops global SRC"     "$prof" "$TEST_RW"
expect_no_subpath "section CWD_ONLY=1 drops section SRC"    "$prof" "$TEST_RW2"

# config file: longest-path section wins over a shorter ancestor section.
write_cfg \
    "SRC = $TEST_RW" \
    "[$REPO]"       "SRC = $TEST_RW2" \
    "[$REPO/test]"  "SRC = $TEST_RW3"
prof=$(cd "$REPO/test" && XDG_CONFIG_HOME="$CFG_DIR" "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "longest-match section wins (nested)"        "$prof" "$TEST_RW3"
expect_no_subpath "longest-match: ancestor section dropped" "$prof" "$TEST_RW2"

# precedence: env CCODE_SRC overrides config (any section).
write_cfg "SRC = $TEST_RW2"
prof=$(XDG_CONFIG_HOME="$CFG_DIR" CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "env CCODE_SRC beats config SRC"             "$prof" "$TEST_RW"
expect_no_subpath "env CCODE_SRC drops config SRC"          "$prof" "$TEST_RW2"

# precedence: env CCODE_SRC implies CWD_ONLY=0, overriding config's CWD_ONLY=1.
write_cfg "CWD_ONLY = 1" "SRC = $TEST_RW2"
prof=$(XDG_CONFIG_HOME="$CFG_DIR" CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "explicit CCODE_SRC neutralises config CWD_ONLY" "$prof" "$TEST_RW"

# precedence: explicit env CCODE_CWD_ONLY=1 beats env CCODE_SRC.
prof=$(CCODE_SRC="$TEST_RW" CCODE_CWD_ONLY=1 "$SCRIPT" --print-profile 2>/dev/null)
expect_no_subpath "env CCODE_CWD_ONLY beats env CCODE_SRC"  "$prof" "$TEST_RW"

# cwd is always rw regardless of resolution.
prof=$(CCODE_CWD_ONLY=1 "$SCRIPT" --print-profile 2>/dev/null)
expect_subpath "cwd is always rw (CWD_ONLY mode)"           "$prof" "$REPO"

# Reset the test config so the existing later tests are unaffected.
rm -f "$CFG_DIR/ccode"

echo
echo "==== script: env handling (env -i + redirects) ===="
mkdir -p "$TMP/stub-bin"
cat > "$TMP/stub-bin/claude" <<'STUB'
#!/bin/bash
# Test stub: print the env it received, ignoring real claude args.
env
STUB
chmod +x "$TMP/stub-bin/claude"

# Set a host-only env var that must NOT cross env -i, plus a tame value
# to confirm forwarding works for variables the script does export.
export CCODE_TEST_HOST_SECRET="must-not-leak"
output=$(PATH="$TMP/stub-bin:$PATH" CCODE_SRC="$TEST_RW" "$SCRIPT" 2>&1)

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
check "NPM_CONFIG_PREFIX redirected"              '^NPM_CONFIG_PREFIX=.*\.sandbox/npm-prefix$' present
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
echo "==== noexec: opt-in via CCODE_NOEXEC=1 ===="
# Stub claude that writes a fresh executable file inside RW_ROOT and exits.
# After ccode-macos returns, the file should still exist but its +x bit
# must be stripped.
mkdir -p "$TMP/noexec-stub"
cat > "$TMP/noexec-stub/claude" <<STUB
#!/bin/bash
# Write a script with +x to the workdir. The ccode-macos EXIT trap should
# strip the +x bit when CCODE_NOEXEC=1.
printf '%s\n' '#!/bin/bash' 'echo evil' > '$TEST_RW/sandbox-built-binary'
chmod +x '$TEST_RW/sandbox-built-binary'
STUB
chmod +x "$TMP/noexec-stub/claude"

PATH="$TMP/noexec-stub:$PATH" CCODE_SRC="$TEST_RW" CCODE_NOEXEC=1 "$SCRIPT" >/dev/null 2>&1 || true

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

# Counter-test: when CCODE_NOEXEC is unset, the +x bit is preserved.
rm -f "$TEST_RW/sandbox-built-binary"
PATH="$TMP/noexec-stub:$PATH" CCODE_SRC="$TEST_RW" "$SCRIPT" >/dev/null 2>&1 || true
if [[ -x "$TEST_RW/sandbox-built-binary" ]]; then
    ok "without CCODE_NOEXEC, +x is preserved"
else
    fail "without CCODE_NOEXEC, +x is preserved" "+x stripped even without opt-in"
fi
rm -f "$TEST_RW/sandbox-built-binary"

echo
echo "==== network policy: profile shape ===="
# With a policy, the profile network section must switch to deny + only
# loopback proxy ports. Use --print-profile (sentinel ports, no proxy
# actually started).
prof_with=$(CCODE_NETPOLICY=anthropic-only CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile 2>&1)
if grep -q '(deny network\*)' <<<"$prof_with" && \
   grep -q 'localhost:<HTTP_PORT>' <<<"$prof_with" && \
   grep -q 'localhost:<SOCKS_PORT>' <<<"$prof_with"; then
    ok "policy active: profile denies network, allows proxy ports only"
else
    fail "policy active: profile denies network, allows proxy ports only" "got profile not as expected"
fi

prof_without=$(CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile 2>&1)
if grep -q '(allow network\*)' <<<"$prof_without"; then
    ok "policy unset: profile allows network (default behaviour)"
else
    fail "policy unset: profile allows network (default behaviour)" "expected (allow network*)"
fi

# Unknown policy name should bail with a clear error, not silently fall
# back to open network.
out_bad=$(CCODE_NETPOLICY=this-does-not-exist CCODE_SRC="$TEST_RW" "$SCRIPT" --print-profile 2>&1 || true)
if grep -q 'policy not found' <<<"$out_bad"; then
    ok "unknown policy name aborts loudly"
else
    fail "unknown policy name aborts loudly" "got: $out_bad"
fi

echo
echo "==== network policy: env wiring when proxy is active ===="
output_with=$(PATH="$TMP/stub-bin:$PATH" CCODE_SRC="$TEST_RW" CCODE_NETPOLICY=anthropic-only "$SCRIPT" 2>/dev/null || true)
check_proxy() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" <<<"$output_with"; then ok "$desc"
    else fail "$desc" "pattern '$pattern' missing from env"; fi
}
check_proxy "HTTP_PROXY -> loopback netproxy"  '^HTTP_PROXY=http://127\.0\.0\.1:[0-9]+$'
check_proxy "HTTPS_PROXY -> loopback netproxy" '^HTTPS_PROXY=http://127\.0\.0\.1:[0-9]+$'
check_proxy "ALL_PROXY uses socks5h"           '^ALL_PROXY=socks5h://127\.0\.0\.1:[0-9]+$'
check_proxy "NO_PROXY excludes loopback"       '^NO_PROXY=localhost,127\.0\.0\.1,::1$'

output_without=$(PATH="$TMP/stub-bin:$PATH" CCODE_SRC="$TEST_RW" "$SCRIPT" 2>/dev/null || true)
if grep -q '^HTTP_PROXY=' <<<"$output_without"; then
    fail "policy unset: HTTP_PROXY not set" "HTTP_PROXY leaked into env"
else
    ok "policy unset: HTTP_PROXY not set"
fi

# Proxy should be killed by the script's EXIT trap. Check directly.
sleep 0.5
if pgrep -fl ccode-netproxy >/dev/null 2>&1; then
    fail "netproxy cleaned up on exit" "stray ccode-netproxy still running: $(pgrep -fl ccode-netproxy)"
else
    ok "netproxy cleaned up on exit (no stray processes)"
fi

echo
echo "==== summary ===="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
exit 0
