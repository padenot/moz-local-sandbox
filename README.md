# moz-local-sandbox

Local sandbox for running Claude Code (`claude`) against a Firefox checkout.

- **Linux:** `bwrap`-based, supports `rr` recording/replay via the rr-mcp MCP
  server. Script: `ccode`.
- **macOS:** `sandbox-exec` (Seatbelt) based. Script: `ccode-macos`. `rr` is
  Linux-only and is not available here.

## Usage

```
ccode [claude-args...]
ccode --exec PROGRAM [args...]
```

Without `--exec`, the script launches `claude --permission-mode bypassPermissions`
inside the sandbox. With `--exec`, it runs the given program directly instead —
useful for a sandboxed shell, `mach`, or any other tool.

`~/src` and state directories are writable; most of the system is read-only.
Network is shared (needed for `mach`).

If `~/.config/claude/mcp-servers.json` or `~/.claude/mcp-servers.json` exists,
`--mcp-config` is passed automatically so MCP servers (e.g. rr-mcp) are
available inside the sandbox.

`./install.sh` symlinks the OS-appropriate script to `~/bin/ccode`.
To install manually, copy or symlink `ccode` (Linux) or `ccode-macos`
(macOS) somewhere on your `$PATH` and `chmod +x` it.

### Choosing what to expose read-write

By default the sandbox bind-mounts `~/src` rw, so the agent can hop between
checkouts. Two env vars and a config file let you tighten or relocate this.
The current working directory is always exposed rw regardless.

- `CCODE_SRC=/path/to/tree` — use a different root than `~/src`. Separate
  several trees with `:` to expose them all rw.
- `CCODE_CWD_ONLY=1` — expose **only** the current working directory rw,
  nothing else. Smaller blast radius if the agent goes off the rails; the cost
  is no cross-repo work in that session.
- `CCODE_EXTRA_BIN_DIR=/path/to/dir` — expose a directory of host binaries
  inside the sandbox, read-only and prepended to `PATH`. Useful for personal
  tools in `~/bin` that the agent should be able to invoke. Tilde is expanded
  so `~/bin/sandbox` works from `.zshenv`.

#### Config file (`~/.config/ccode`)

For a persistent, per-checkout setup, drop a config file at `~/.config/ccode`
(or `$XDG_CONFIG_HOME/ccode`). It is a small declarative INI-ish format — it is
**parsed, never sourced**, so it cannot execute code. Top-level keys are global
defaults; a `[<dir>]` section applies only when `ccode` is launched from within
`<dir>`, so different checkouts can expose different sets of trees. Lists are
expressed by repeating `SRC`. A leading `~` is expanded.

```ini
# global default, used when no section matches the cwd
SRC = ~/src
CWD_ONLY = 0

[~/firefox]            # active when cwd is at or below ~/firefox
SRC = ~/firefox
SRC = ~/depot_tools

[~/work/clientA]
SRC = ~/work/clientA
CWD_ONLY = 1           # ignore SRC here, expose only the cwd
```

The most specific (longest-path) matching section wins, and its keys override
the global ones. A configured tree that doesn't exist is skipped with a warning
rather than aborting the launch.

**Precedence**, highest first: `CCODE_CWD_ONLY` / `CCODE_SRC` env vars → the
matching config section → the global config keys → the built-in `~/src`
default. An explicit `CCODE_SRC` implies `CWD_ONLY=0` (you named the trees you
want), unless you also set `CCODE_CWD_ONLY` explicitly.

### Opening URLs in the host browser

The sandbox exposes a validated URL opener so the agent can open Bugzilla
bugs, Phabricator revisions, and localhost dev servers in the host browser.

**How it works:** `bin/ccode-open-server` (Python 3, no dependencies) runs
outside the sandbox and listens on a random loopback port. The in-sandbox
`xdg-open` (Linux) or `open` (macOS) command is shadowed by `bin/ccode-open`,
which sends the URL to the host server via loopback. The server re-validates
and calls `xdg-open` / `/usr/bin/open` on the host. Direct use of the OS open
mechanism is blocked inside the sandbox (no D-Bus on Linux; LaunchServices
mach-lookup is denied on macOS), so the host server is the only path.

**Allowed URLs (hardcoded):**
- `https://bugzilla.mozilla.org/*`
- `https://phabricator.services.mozilla.com/*`
- `http(s)://localhost:<any-port>/*`
- `http(s)://127.0.0.1:<any-port>/*`

Everything else is blocked at the host listener. The agent cannot bypass
this by modifying `bin/ccode-open` — the host listener validates
independently.

### Host-side noexec (macOS, opt-in)

`CCODE_NOEXEC=1 ccode` arms a post-exit `chmod a-x` sweep over the
writable tree: any file that gained the execute bit during the sandbox
session has it stripped when the sandbox exits. Files that were already
executable before launch are left alone (mtime-based diff).

On Linux you can achieve the same effect with an `MS_NOEXEC` bind mount
inside the user namespace; on macOS there are no mount namespaces, so
detect-and-strip on exit is the only option. `CCODE_NOEXEC` is macOS-only.

Restore with `chmod +x <file>` on the host. There is no automatic restore.

## Host system setup

### Linux

One or two changes are required on the host before the sandbox works correctly
with Firefox+rr, depending on the distro.

#### 1. AppArmor profile (Ubuntu/Debian only)

Replace `/etc/apparmor.d/bwrap-userns-restrict` with the file in
`apparmor/bwrap-userns-restrict`, then reload:

```
sudo cp apparmor/bwrap-userns-restrict /etc/apparmor.d/bwrap-userns-restrict
sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
```

**Why:** The stock `unpriv_bwrap` profile contains `audit deny capability`,
which blocks `perf_event_open` capability checks when Firefox spawns child
processes that create their own user namespaces. AppArmor enforces these checks
across namespace boundaries, causing `rr` to fail. The patched profile has that
line commented out.

Fedora uses SELinux instead of AppArmor and does not have this profile. On a
default Fedora Workstation install the user runs as `unconfined_t`, which does
not restrict `perf_event_open` for bwrap children. Skip this step on Fedora.

#### 2. perf_event_paranoid sysctl

```
sudo cp sysctl/10-perf.conf /etc/sysctl.d/10-perf.conf
sudo sysctl -p /etc/sysctl.d/10-perf.conf
```

**Why:** `rr` requires `perf_event_open`. The default paranoia level on Ubuntu
(≥3) blocks this for unprivileged processes; Fedora defaults to 2, which may
also be insufficient inside a user namespace. Setting it to 1 allows it.

#### 3. Disable per-repo git hooks on the host (recommended)

The sandbox can write to any repository under `~/src`, including its
`.git/hooks/` and `.git/config`. Inside the sandbox we disable hook execution,
but a compromised agent can still drop a `.git/hooks/post-merge` (or set
`core.hooksPath` / `core.fsmonitor` / a `[alias] x = !cmd` in `.git/config`)
that the *host's* git would later execute as you, outside the sandbox.

The cleanest defence is to make your host git ignore per-repo hooks entirely:

```
git config --global core.hooksPath ~/.git-hooks-trusted
mkdir -p ~/.git-hooks-trusted
```

Per-repo `.git/config` is harder to neutralise — treat sandbox-touched repos
as untrusted on the host, and audit `.git/config` before running git commands
in them if you suspect compromise.

### macOS

No host-side changes are required: `sandbox-exec` ships in the base system.
Disabling per-repo git hooks on the host (the same recommendation as on
Linux) is still worth doing.

To verify the sandbox is enforcing the expected policy on this machine:

```
./test/test-macos.sh
```

The suite probes the live profile with read/write/exec scenarios that
should succeed, ones that should be denied, and confirms the script's
`env -i` strips host secrets while redirecting toolchain caches into
`~/.sandbox/`. It does not require `claude` to be installed.

## What the sandbox exposes

### Linux (`bwrap`)

| Path | Access | Purpose |
|------|--------|---------|
| `/usr`, `/lib`, `/lib64`, `/bin` | ro | system binaries/libs |
| `/etc/{resolv.conf,hosts,ssl,passwd,group}` | ro | network + auth |
| `/etc/alternatives` | ro | compiler/tool alternative symlinks (Ubuntu/Debian; skipped if absent) |
| `/etc/ld.so.{cache,conf,conf.d}` | ro | dynamic linker config (skipped if absent) |
| `~/.config/claude`, `~/.local/share/claude` | ro | Claude config/data |
| `~/.config/gh`, `~/.config/jj` | ro | VCS credentials |
| `~/.gitconfig`, `~/.arcrc` | ro | VCS config |
| `~/.moz-phab-config` | rw | moz-phab config |
| `~/.nvm`, `~/.local/bin` | ro | Node, local tools |
| `~/.rustup` | ro | rust toolchains (use only) |
| `~/.cargo/bin` → `/opt/cargo-host/bin` | ro | host-installed cargo tools (jj, bat, …) |
| `~/.ssh/{known_hosts,config}` | ro | ssh known hosts / config (keys NOT exposed; see below) |
| `$SSH_AUTH_SOCK` | ro | ssh-agent socket forwarded for signing |
| `~/src` (or `$CCODE_SRC`, or `$PWD` with `CCODE_CWD_ONLY=1`) | rw | Firefox source tree |
| `~/.claude`, `~/.claude.json` | rw | Claude state |
| `~/.local/share/rr` | rw | rr traces |
| `~/.mozbuild` | rw | mach build artifacts |
| `~/.sandbox/{cargo,uv,npm,npm-prefix,pip,go}` (mounted at canonical paths) | rw | sandbox-only language toolchain caches; `npm-prefix/bin` is on `PATH` for `npm i -g` |
| `/opt/ccode-bin/xdg-open` (bind of `bin/ccode-open`) | ro | validated URL opener; shadows system `xdg-open` |

### macOS (`sandbox-exec`)

| Path | Access | Purpose |
|------|--------|---------|
| `/usr`, `/bin`, `/sbin`, `/System`, `/Library`, `/Applications`, `/opt` | ro | system binaries / libs / frameworks |
| `/private/etc`, `/private/var/db` | ro | system config, dyld cache |
| `/dev`, `/private/tmp`, `/private/var/folders` | rw | devices, tmp, per-user temp dirs |
| `~/.config/claude`, `~/.local/share/claude` | ro | Claude config/data |
| `~/.config/gh`, `~/.config/jj` | ro | VCS credentials |
| `~/.gitconfig`, `~/.arcrc` | ro | VCS config |
| `~/.moz-phab-config` | rw | moz-phab config |
| `~/.nvm`, `~/.local/bin` | ro | Node, local tools |
| `~/.rustup` | ro | rust toolchains (use only) |
| `~/.cargo/bin` | ro | host-installed cargo tools |
| `~/.ssh/{known_hosts,config}` | ro | ssh known hosts / config (keys NOT exposed) |
| `$SSH_AUTH_SOCK` (if set) | rw | ssh-agent socket forwarded for signing |
| `~/src` (or `$CCODE_SRC`, or `$PWD` with `CCODE_CWD_ONLY=1`) | rw | Firefox source tree |
| `~/.claude`, `~/.claude.json` | rw | Claude state (shared with host — see residual risks) |
| `~/Library/Keychains` | rw | macOS keychain (claude OAuth token + refresh on /login) |
| `~/.mozbuild` | rw | mach build artifacts |
| `~/.sandbox/{cargo,uv,npm,npm-prefix,pip,go}` | rw | sandbox-only language toolchain caches |

There are no bind mounts on macOS, so toolchain caches are redirected via
env vars (`CARGO_HOME`, `NPM_CONFIG_CACHE`/`PREFIX`, `PIP_CACHE_DIR`,
`GOPATH`, `GOMODCACHE`, `UV_CACHE_DIR`) instead of being mounted at the
canonical paths.

The sandbox profile also `(deny mach-lookup …)`s a hand-picked list of
user-facing Mach services — pasteboard, Dock, SystemUIServer, Notification
Center, AppleEvents — so a compromised agent can't read the system
clipboard, manipulate the Dock, send notifications, or (in theory) script
other apps via AppleEvents. Note that on modern macOS, AppleEvent
delivery is gated by TCC rather than mach-lookup, so the AppleEvents deny
is best-effort; rely on TCC consent (System Settings → Privacy & Security
→ Automation) as the real defence.

### Environment forwarding

The following environment variables are forwarded into the sandbox when
present: `GH_TOKEN` (read at launch via `gh auth token`),
`PHABRICATOR_TOKEN`, `BMO_API_KEY`, and `SSH_AUTH_SOCK`. Everything else
from the host environment is dropped (`--clearenv` on Linux, `env -i` on
macOS).

`MOZCONFIG` and `MOZBUILD_STATE_PATH` are also forwarded when set. `MOZCONFIG`
is additionally bind-mounted rw (Linux) or granted a profile subpath rule
(macOS) so `mach` can write build artifacts into it. `MOZBUILD_STATE_PATH` must
resolve inside an already-accessible writable path (`~/.mozbuild`, `$CCODE_SRC`,
or `$PWD`); the script exits with an error if it points outside those roots.

On macOS, Claude Code uses the login keychain as its sole credential
store, so `~/Library/Keychains` is exposed rw to the sandbox: the
in-sandbox claude reads the "Claude Code" entry on startup and rewrites
it on `/login` (token refresh). Without RW, `/login` fails with "Failed
to save API key to macOS Keychain". File-level RW does not bypass
securityd ACLs — accessing unrelated entries (Slack, 1Password, etc.)
still triggers a consent prompt or outright denial. See residual risks.

We do **not** also forward `CLAUDE_CODE_OAUTH_TOKEN` via env: doing so
in combination with a keychain-managed login key makes claude warn
about an auth conflict.

## Residual risks

The sandbox limits blast radius but does not eliminate it. Things to be aware
of:

- **Per-repo `.git/config`.** The agent can edit `.git/config` in any repo
  under `~/src`. Settings like `core.hooksPath`, `core.fsmonitor` or
  `[alias] x = !shell-cmd` will be honoured by the *host's* git. Mitigate by
  setting `core.hooksPath` in your own `~/.gitconfig` (see Host system
  setup) and by treating sandbox-touched repos as untrusted on the host.

- **Bearer tokens are readable, not just unmodifiable.** `~/.arcrc`,
  `~/.config/gh` and `~/.moz-phab-config` are exposed so the agent can use
  Phabricator / GitHub. Read-only mounts stop tampering but a compromised
  agent can still copy the tokens out over the (shared) network. Network
  egress filtering is expected to be handled separately.

- **Claude state is shared with host claude.** `~/.claude` and
  `~/.claude.json` are writable and are the same paths the host's `claude`
  binary uses. A compromised sandbox can edit memory files, settings,
  hooks, or MCP server lists — and a subsequent host `claude` run will pick
  them up, *outside* the sandbox. Isolating via `CLAUDE_CONFIG_DIR`
  was tried and removed: Claude Code on macOS spreads login state
  across `~/.claude/`, `~/.claude.json`, and the keychain, and isolating
  any one of them broke login UX even with a token forwarded via env
  var. Network egress filtering is the real mitigation.

- **rustup `~/.rustup` is shared read-only.** A compromised agent cannot
  modify the host toolchain, but cannot install new toolchains either —
  `rustup install/update` must run on the host.

- **`cargo install` no longer reaches the host.** Cargo-installed CLI tools
  live in the sandbox's `~/.cargo/bin` (under `~/.sandbox/cargo/bin`). If
  you want a tool inside the sandbox, install it from inside `ccode`.

- **macOS: no PID isolation.** `bwrap` uses a PID namespace so the agent
  cannot see or signal host processes. macOS has no equivalent primitive;
  `sandbox-exec` only restricts the `signal` operation. The agent can still
  enumerate host PIDs via `ps`/`sysctl`, though it cannot send signals to
  them or read their per-process info beyond what `sysctl` exposes.

- **macOS: `sandbox-exec` is deprecated.** Apple's own man page says so. It
  remains the only unprivileged sandboxing primitive available on macOS and
  is still enforced by the kernel, but Apple may break or remove it in
  future releases. Treat the macOS sandbox as best-effort.

- **macOS: Mach IPC is mostly allowed.** `mach-lookup` is allowed broadly
  because denying it breaks system frameworks at startup. The profile
  blocks a hand-picked list of user-facing services (pasteboard, Dock,
  SystemUIServer, Notification Center, AppleEvents) but the deny list is
  not exhaustive — a compromised agent can still talk to anything else
  reachable via Mach. AppleEvents in particular is gated by TCC rather
  than sandbox-exec on modern macOS; the deny rule is a tripwire, not a
  guarantee.

