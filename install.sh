#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

case "$(uname)" in
    Linux)  BIN="ccode" ;;
    Darwin) BIN="ccode-macos" ;;
    *) echo "Unsupported OS: $(uname)" >&2; exit 1 ;;
esac

# Prefer a writable bin dir already on $PATH; fall back to creating ~/.local/bin.
CANDIDATES=("$HOME/.local/bin" "$HOME/bin")

TARGET_DIR=""
for dir in "${CANDIDATES[@]}"; do
    if [[ ":$PATH:" == *":$dir:"* && -d "$dir" && -w "$dir" ]]; then
        TARGET_DIR="$dir"
        break
    fi
done

if [[ -z "$TARGET_DIR" ]]; then
    for dir in "${CANDIDATES[@]}"; do
        if [[ -d "$dir" && -w "$dir" ]]; then
            TARGET_DIR="$dir"
            break
        fi
    done
fi

if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="$HOME/.local/bin"
    read -r -p "Neither ~/.local/bin nor ~/bin exist. Create $TARGET_DIR? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS]) mkdir -p "$TARGET_DIR" ;;
        *) echo "Aborted." >&2; exit 1 ;;
    esac
fi

# Install a copy outside the writable source tree. A symlink into the checkout
# would let a sandboxed agent replace code executed on the host next launch.
mkdir -p "$HOME/.local/lib"
INSTALL_DIR="$(mktemp -d "$HOME/.local/lib/mozsb.XXXXXXXX")"
cp "$REPO/ccode" "$REPO/ccode-macos" "$INSTALL_DIR/"
cp -R "$REPO/bin" "$INSTALL_DIR/bin"
ln -sf "$INSTALL_DIR/$BIN" "$TARGET_DIR/mozsb"
echo "Installed: $TARGET_DIR/mozsb -> $INSTALL_DIR/$BIN"

if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
    echo "Note: $TARGET_DIR is not on your \$PATH. Add it, e.g.:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
fi

if [[ "$(uname)" == "Linux" ]] && command -v apparmor_parser >/dev/null 2>&1; then
    APPARMOR_SRC="$REPO/apparmor/bwrap-userns-restrict"
    APPARMOR_DST="/etc/apparmor.d/bwrap-userns-restrict"
    read -r -p "Install AppArmor profile to $APPARMOR_DST (needs sudo, required for rr on Ubuntu/Debian)? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS])
            sudo cp "$APPARMOR_SRC" "$APPARMOR_DST"
            sudo apparmor_parser -r "$APPARMOR_DST"
            echo "Installed AppArmor profile: $APPARMOR_DST"
            ;;
        *) echo "Skipped AppArmor profile install." ;;
    esac
fi
