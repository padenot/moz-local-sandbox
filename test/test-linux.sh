#!/bin/bash
#
# test-linux.sh — SRC/CWD_ONLY resolution tests for ccode (bwrap).
#
# ccode resolves which source trees get bind-mounted read-write from a mix of
# environment variables (CCODE_SRC / CCODE_CWD_ONLY) and a declarative config
# file (~/.config/ccode), then emits one big `bwrap` invocation in which each
# rw tree shows up as a `--bind <tree> <tree>` pair.
#
# Rather than spin up a real user namespace per case (slow, and unavailable in
# some CI), we shim `bwrap` on PATH with a stub that simply prints the argv it
# was handed, then assert on which `--bind <tree> <tree>` pairs are present.
# This is the Linux analogue of test-macos.sh inspecting the `(subpath …)`
# rules emitted into a sandbox-exec profile by `ccode-macos --print-profile`.
#
# No real claude install, and no working bwrap/user namespaces, are required.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/ccode"

if [[ "$(uname)" != "Linux" ]]; then
    echo "test-linux.sh: skipped (not Linux)" >&2
    exit 0
fi
if [[ ! -x "$SCRIPT" ]]; then
    echo "FATAL: $SCRIPT not executable" >&2
    exit 2
fi

TMP=$(mktemp -d -t ccode-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ok    $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1${2+ -- $2}" >&2; FAIL=$((FAIL+1)); }

# Stub bwrap: print the argv ccode resolved (one big space-joined line) and
# exit success, so the EXIT trap and the rest of ccode are happy. The test
# temp dirs never contain spaces, so a space-joined line is unambiguous for
# the `--bind <path> <path>` substring checks below.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/bwrap" <<'STUB'
#!/bin/bash
printf '%s ' "$@"; echo
STUB
chmod +x "$STUB_BIN/bwrap"

# Emit the bwrap argv ccode would exec, with the stub capturing it. Env vars
# (CCODE_SRC, CCODE_CWD_ONLY, XDG_CONFIG_HOME) are set by the caller as a
# prefix; `--exec true` is harmless since the stub never execs anything.
ccode_binds() { PATH="$STUB_BIN:$PATH" "$SCRIPT" --exec true; }

# A `--bind <path> <path>` pair means <path> was exposed read-write. Note that
# `--ro-bind` does not contain the `--bind` substring, so this never matches a
# read-only mount by accident.
expect_bind() {
    local desc="$1" argv="$2" path="$3"
    if grep -qF -- "--bind $path $path" <<<"$argv"; then
        ok "$desc"
    else
        fail "$desc" "missing --bind $path $path"
    fi
}
expect_no_bind() {
    local desc="$1" argv="$2" path="$3"
    if grep -qF -- "--bind $path $path" <<<"$argv"; then
        fail "$desc" "unexpected --bind $path $path"
    else
        ok "$desc"
    fi
}

TEST_RW="$TMP/rw-root";   mkdir -p "$TEST_RW"
TEST_RW2="$TMP/rw-second"; mkdir -p "$TEST_RW2"
TEST_RW3="$TMP/rw-third";  mkdir -p "$TEST_RW3"
CFG_DIR="$TMP/cfg-dir";    mkdir -p "$CFG_DIR"
write_cfg() { printf '%s\n' "$@" > "$CFG_DIR/ccode"; }

echo "==== rw resolution: env, config, precedence ===="

# Empty config — keeps the file's mere presence from changing behaviour.
: > "$CFG_DIR/ccode"

# env CCODE_SRC: single path becomes a bind.
binds=$(CCODE_SRC="$TEST_RW" ccode_binds 2>/dev/null)
expect_bind "CCODE_SRC=path -> bind"                       "$binds" "$TEST_RW"

# env CCODE_SRC: ':' separator exposes multiple trees.
binds=$(CCODE_SRC="$TEST_RW:$TEST_RW2" ccode_binds 2>/dev/null)
expect_bind "CCODE_SRC=a:b -> first tree bound"            "$binds" "$TEST_RW"
expect_bind "CCODE_SRC=a:b -> second tree bound"           "$binds" "$TEST_RW2"

# env CCODE_CWD_ONLY=1 short-circuits SRC.
binds=$(CCODE_SRC="$TEST_RW" CCODE_CWD_ONLY=1 ccode_binds 2>/dev/null)
expect_no_bind "CCODE_CWD_ONLY=1 drops CCODE_SRC trees"    "$binds" "$TEST_RW"

# Non-existent rw path is skipped with a warning; siblings survive.
out=$(CCODE_SRC="$TEST_RW:/this/does/not/exist" ccode_binds 2>&1)
expect_bind "missing rw path skipped, sibling survives"    "$out"  "$TEST_RW"
if grep -q '^ccode: warning.*does not exist.*does/not/exist' <<<"$out"; then
    ok "missing rw path emits a warning"
else
    fail "missing rw path emits a warning" "no warning matched"
fi

# config file: global SRC used when no [section] matches.
write_cfg "SRC = $TEST_RW" "SRC = $TEST_RW2"
binds=$(XDG_CONFIG_HOME="$CFG_DIR" ccode_binds 2>/dev/null)
expect_bind "config global SRC #1 -> bind"                 "$binds" "$TEST_RW"
expect_bind "config global SRC #2 -> bind"                 "$binds" "$TEST_RW2"

# config file: matching [section] overrides global SRC. The section path must
# contain the cwd, so run from the repo root.
write_cfg "SRC = $TEST_RW" "[$REPO]" "SRC = $TEST_RW2" "SRC = $TEST_RW3"
binds=$( cd "$REPO" && XDG_CONFIG_HOME="$CFG_DIR" ccode_binds 2>/dev/null )
expect_no_bind "matching section drops global SRC"         "$binds" "$TEST_RW"
expect_bind "matching section SRC #1"                      "$binds" "$TEST_RW2"
expect_bind "matching section SRC #2"                      "$binds" "$TEST_RW3"

# config file: CWD_ONLY=1 inside the matching section drops all SRC.
write_cfg "SRC = $TEST_RW" "[$REPO]" "SRC = $TEST_RW2" "CWD_ONLY = 1"
binds=$( cd "$REPO" && XDG_CONFIG_HOME="$CFG_DIR" ccode_binds 2>/dev/null )
expect_no_bind "section CWD_ONLY=1 drops global SRC"       "$binds" "$TEST_RW"
expect_no_bind "section CWD_ONLY=1 drops section SRC"      "$binds" "$TEST_RW2"

# config file: longest-path section wins over a shorter ancestor section.
write_cfg \
    "SRC = $TEST_RW" \
    "[$REPO]"       "SRC = $TEST_RW2" \
    "[$REPO/test]"  "SRC = $TEST_RW3"
binds=$( cd "$REPO/test" && XDG_CONFIG_HOME="$CFG_DIR" ccode_binds 2>/dev/null )
expect_bind "longest-match section wins (nested)"          "$binds" "$TEST_RW3"
expect_no_bind "longest-match: ancestor section dropped"   "$binds" "$TEST_RW2"

# precedence: env CCODE_SRC overrides config (any section).
write_cfg "SRC = $TEST_RW2"
binds=$( cd "$REPO" && XDG_CONFIG_HOME="$CFG_DIR" CCODE_SRC="$TEST_RW" ccode_binds 2>/dev/null )
expect_bind "env CCODE_SRC beats config SRC"               "$binds" "$TEST_RW"
expect_no_bind "env CCODE_SRC drops config SRC"            "$binds" "$TEST_RW2"

# precedence: env CCODE_SRC implies CWD_ONLY=0, overriding config's CWD_ONLY=1.
write_cfg "CWD_ONLY = 1" "SRC = $TEST_RW2"
binds=$( cd "$REPO" && XDG_CONFIG_HOME="$CFG_DIR" CCODE_SRC="$TEST_RW" ccode_binds 2>/dev/null )
expect_bind "explicit CCODE_SRC neutralises config CWD_ONLY" "$binds" "$TEST_RW"

# precedence: explicit env CCODE_CWD_ONLY=1 beats env CCODE_SRC.
binds=$(CCODE_SRC="$TEST_RW" CCODE_CWD_ONLY=1 ccode_binds 2>/dev/null)
expect_no_bind "env CCODE_CWD_ONLY beats env CCODE_SRC"    "$binds" "$TEST_RW"

# cwd is always rw regardless of resolution.
binds=$( cd "$REPO" && CCODE_CWD_ONLY=1 ccode_binds 2>/dev/null )
expect_bind "cwd is always rw (CWD_ONLY mode)"             "$binds" "$REPO"

echo
echo "==== summary ===="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
exit 0
