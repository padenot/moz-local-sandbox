# moz-local-sandbox

Sandbox for running Claude Code (`claude`) or Codex (`codex`) against a
Firefox checkout.

- **Linux:** `bwrap`-based, supports `rr` via rr-mcp. Script: `ccode`.
- **macOS:** `sandbox-exec` (Seatbelt) based. Script: `ccode-macos`.

## Usage

### Setup

If you have your source code in `~/src` and you're ok with sharing all this in
the sandbox and forwarding an SSH agent, you can proceed to the next step.
Otherwise, see [Configuration](#configuration) below to change the defaults.

### Then

```
mozsb claude [claude-args...]
mozsb codex [codex-args...]
mozsb exec PROGRAM [args...]
```

The agent subcommands disable that agent's own sandbox and approval layer,
because the outer `mozsb` sandbox is the enforcement boundary. `exec` runs an
arbitrary program with neither agent's state exposed (useful for diagnosis).

`~/src` and the selected agent's state directory are writable; most of the
system is read-only. Claude state is not exposed to Codex, Codex state is not
exposed to Claude, and neither is exposed to `exec`. Network is shared (needed
for various things under and in `mach`). Claude MCP config is passed through
automatically if present; Codex reads its normal `$CODEX_HOME/config.toml`.
On both platforms, Codex runs with `--no-daemon` to keep its app server inside
the outer sandbox. This requires a Codex version that supports `--no-daemon`.

`./install.sh` copies the launchers and helpers into `~/.local/lib/mozsb.*`
and symlinks the OS-appropriate installed copy as `mozsb`. Re-run it after
updates. The launcher refuses to run when its own directory is inside the
writable source root: sandbox-controlled files must not execute on the host.

Run from within one of the configured source roots, or select
`MOZSB_CWD_ONLY=1` for a checkout elsewhere. The home directory and its
ancestors cannot be selected as writable source roots.

### Configuration

Use this directory layout:

```text
~/.config/mozsb/
├── config   # launcher settings: source roots, read-only access, options
└── env      # variables passed to programs inside the sandbox (optional)
```

Both files are optional. If `$XDG_CONFIG_HOME` is set, use
`$XDG_CONFIG_HOME/mozsb/` instead. If you already have a **file** named
`~/.config/mozsb`, follow [Migrating an old config](#migrating-an-old-config)
before creating the directory.

Create the directory with `mkdir -p ~/.config/mozsb`, then save your launcher
settings in `~/.config/mozsb/config`. For example:

```ini
SRC = ~/src
EXTRA_RO_DIRS = ~/reference docs
EXTRA_RO_DIRS = /data/reference
EXTRA_BIN_DIR = ~/.local/tools/bin
NO_SSH_AGENT = 1

[~/firefox]
SRC = ~/firefox
SRC = ~/depot_tools

[~/work/client]
CWD_ONLY = 1
```

| Config key | Effect |
| --- | --- |
| `SRC` | Expose a source root read-write; repeat for multiple roots. Default: `~/src`. |
| `CWD_ONLY` | Expose only the current directory read-write when set to `1`. |
| `EXTRA_RO_DIRS` | Expose a directory read-only, without adding it to `PATH`; repeat for multiple directories. |
| `EXTRA_BIN_DIR` | Expose a directory read-only and prepend it to `PATH`. |
| `NO_SSH_AGENT` | Disable SSH agent forwarding when set to `1`. |
| `ENABLE_WAYLAND` | On Linux, expose the Wayland socket so programs can open windows when set to `1`; see Residual risks. |
| `ENABLE_GRAPHICS` | On Linux, expose one GPU render node (`/dev/dri/renderD*`) and the sysfs files that identify that GPU when set to `1`; see Residual risks. |
| `GPU` | With `ENABLE_GRAPHICS`, select the GPU by render node (`renderD129`) or PCI slot (`0000:01:00.0`). Default: the GPU the display booted on. |
| `NOEXEC` | On macOS, remove newly gained execute bits on exit when set to `1`; see the details below. |
| `CLAUDE_BIN`, `CODEX_BIN` | Set the path to the agent executable. |
| `ENV_FILE` | Read sandbox environment variables from a different file. |

Use `1` to enable flags and `0` to disable them. Extra read-only and bin
directories must already exist. The config file uses INI-style syntax. Paths
can contain spaces and start with `~/`; values are literal, without shell
expansion. Double quotes around values are optional.
Lines starting with `#` and trailing `#` comments are accepted.

Settings above the first section are global defaults. A section such as
`[~/firefox]` applies when launching from that directory or any directory
below it. Only the most specific matching section applies. Its settings
override global values for the same key; its `SRC` and `EXTRA_RO_DIRS` lists
replace the corresponding global lists.

Environment overrides take priority over config settings. For example,
`MOZSB_EXTRA_RO_DIRS=/tmp/reference mozsb claude` replaces the configured
read-only directory list for that launch. `MOZSB_SRC` replaces configured
source roots and bypasses configured `CWD_ONLY`; use `MOZSB_CWD_ONLY=1` to
explicitly select only the current directory.

### Environment overrides

- `MOZSB_SRC=/path` - use a different root than `~/src`.
- `MOZSB_SRC=/path:/other/path` - expose multiple source roots read-write.
- `MOZSB_CWD_ONLY=1` - expose only `$PWD` rw instead of all of `~/src`.
- `MOZSB_EXTRA_RO_DIRS=/path:/other/path` - expose host directories read-only
  without adding them to `PATH`. Paths may contain spaces or start with `~/`.
- `MOZSB_EXTRA_BIN_DIR=/path` - mount a host bin dir read-only, prepended to `PATH`.
- `MOZSB_NOEXEC=1` (macOS) - strip the exec bit from any file that gained it
  during the session, on exit. Existing execute bits are preserved. This is
  an exit-time convenience, not an execution barrier; scripts can still be
  interpreted and files can execute before cleanup runs.
- `MOZSB_NO_SSH_AGENT=1` - disable SSH agent forwarding.
- `MOZSB_ENABLE_WAYLAND=1` (Linux) - expose the Wayland socket.
- `MOZSB_ENABLE_GRAPHICS=1` (Linux) - expose a GPU render node.
- `MOZSB_GPU=renderD129` or `MOZSB_GPU=0000:01:00.0` (Linux) - select the GPU exposed by `MOZSB_ENABLE_GRAPHICS`.
- `MOZSB_CLAUDE_BIN=/path`, `MOZSB_CODEX_BIN=/path` - override agent discovery.
- `MOZSB_ENV_FILE=/path` - read extra sandbox env vars from this file instead
  of `~/.config/mozsb/env`.

The former `CCODE_*` environment variable names remain accepted as aliases.

### Sandbox environment

The launcher forwards only selected host environment variables (listed under
[What's exposed](#whats-exposed)). To pass additional variables to programs
inside the sandbox, write `~/.config/mozsb/env`. Launcher settings such as
`SRC` and `EXTRA_RO_DIRS` belong in `config`; agent variables belong in `env`:

```sh
# one KEY=value per line; `export ` prefix, blank lines and # comments are fine
CLAUDE_CODE_EFFORT_LEVEL=xhigh
CLAUDE_CONFIG_DIR=~/.claude-separate-config
ANTHROPIC_API_KEY=sk-...
```

Values are literal — no `$VAR` expansion or command substitution — except a
leading `~/`, which expands to `$HOME/`. `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
are special-cased: the directory is created on the host and bound read-write
into the sandbox, since that is where the agent then keeps its settings and
credentials. The env file itself is never exposed to the sandbox, so keys in
it are reachable only as environment variables — the same exposure as
`GH_TOKEN` (see Residual risks).

### Migrating an old config

`~/.config/mozsb/` is a directory containing both `config` and `env`. The old
files `~/.config/mozsb` and `~/.config/ccode` remain supported as fallbacks,
in that order, when the new config file is absent. To migrate an old
`~/.config/mozsb` file:

```sh
mv ~/.config/mozsb ~/.config/mozsb.old
mkdir ~/.config/mozsb
mv ~/.config/mozsb.old ~/.config/mozsb/config
```

These paths also respect `$XDG_CONFIG_HOME`.

### Opening URLs in the host browser

`xdg-open`/`open` are shadowed inside the sandbox and forward the URL to
`bin/ccode-open-server`, running outside the sandbox, which re-validates and
opens it for real. Allowed: `bugzilla.mozilla.org`, `phabricator.services.mozilla.com`,
`localhost`/`127.0.0.1` (any port). The server validates requests independently
of the client. This does not guarantee desktop isolation: Linux shares the
host network namespace, and macOS exposes LaunchServices (see Residual risks).

### Clipboard (Linux, Wayland)

If `ENABLE_WAYLAND` is not set, the Wayland socket is not mounted.
Instead, `wl-paste`/`wl-copy` are shadowed by shims that go through the same
host-side server (it needs `wl-clipboard` installed on the host).
The sandbox can paste images (screenshots into claude) and write text (`/copy`),
but cannot read text from the clipboard, which may hold passwords; paste text with
the terminal (Ctrl+Shift+V) instead. Requests carry a per-session token so other
local processes cannot use the broker.

## Host setup

### Linux

1. **AppArmor (Ubuntu/Debian only):** the stock `unpriv_bwrap` profile blocks
   `perf_event_open` across namespaces, which breaks `rr`. Install the patched
   profile:
   ```
   sudo cp apparmor/bwrap-userns-restrict /etc/apparmor.d/bwrap-userns-restrict
   sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
   ```
   Not needed on Fedora (SELinux, unconfined by default).

2. **perf_event_paranoid:**
   ```
   sudo cp sysctl/10-perf.conf /etc/sysctl.d/10-perf.conf
   sudo sysctl -p /etc/sysctl.d/10-perf.conf
   ```
   Required for `rr`; Ubuntu's default paranoia level blocks it.

3. **Treat sandbox-touched repositories as untrusted on the host:** the sandbox can
   write `.git/hooks/` or `core.hooksPath`/`core.fsmonitor` in any repo under
   `~/src`, which the host's git would later execute as you.
   ```
   git -c core.hooksPath=/dev/null -c core.fsmonitor=false status
   ```
   Apply these command-line overrides to each host Git invocation that needs
   them. A global `core.hooksPath` setting is insufficient: repository-local
   configuration overrides it. These two overrides do not neutralize other
   execution-bearing settings such as filters, credential helpers or aliases.

### macOS

No host changes needed (`sandbox-exec` ships in the base system). The host Git
precautions above also apply. Verify the sandbox policy with isolated fixtures:

```
make test
```

`make test-live` runs real `claude` (haiku) and `codex` (gpt-6-luna) through
the launcher with your logins: one cheap prompt each, which must run a shell
command in the sandbox and answer. Run it locally after changing the policy.

## What's exposed

Roughly: system binaries/libs read-only; VCS credentials (`gh`, `jj`, `.gitconfig`,
`.arcrc`, `.moz-phab-config`) read-only except moz-phab config; `~/src` (or
`$MOZSB_SRC`/`$PWD`) read-write; the selected agent's state (`~/.claude*` or
`$CODEX_HOME`) read-write; language toolchain caches redirected into
`~/.sandbox/`; `~/.profiler-cli` read-write; `rr` traces and `~/.mozbuild`
read-write on Linux. In Claude
mode, macOS additionally exposes `~/Library/Keychains` read-write (Claude
Code's credential store there). Codex and `exec` modes do not expose it.
macOS denies a short list of user-facing Mach services (Dock, Notification
Center, pasteboard-adjacent, AppleEvents).
Firefox's host profile contents are not exposed. On macOS its registry files
are read-only and its crash-report directory is writable; pass an explicit
`-profile` directory under the writable source root or `~/.sandbox`.
See `ccode`/`ccode-macos` source for the exact mount/rule list.

`~/.nvm` is read-only, like `~/.rustup`: the version you had active on the
host is on `PATH` inside and `npm i -g` installs into `~/.sandbox/npm-prefix`,
but `nvm install` fails by design — add node versions on the host.

Env vars forwarded in: `GH_TOKEN`, `PHABRICATOR_TOKEN`, `BMO_API_KEY`,
`SSH_AUTH_SOCK` (if not disabled), `MOZCONFIG`, `MOZBUILD_STATE_PATH`.
Everything else is dropped.

## Residual risks

The sandbox reduces blast radius, it doesn't eliminate it:

- **Per-repo `.git/config`** in `~/src` can plant commands the host's Git
  will run later. The command-line overrides above cover hooks and fsmonitor
  only; treat sandbox-touched repos as untrusted on the host.
- **Linux shares the host network namespace**, including abstract Unix
  sockets. Depending on desktop authentication, X11/Xwayland may be reachable
  without mounting its filesystem socket. Loopback services are also reachable
  on both platforms. Filesystem isolation does not protect these services.
- **Linux: `ENABLE_WAYLAND=1` exposes the Wayland compositor.** The blast radius
  of this setting depends on the compositor. On GNOME/KDE, a compromised agent
  can open windows that imitate other apps and read the clipboard when
  one of its windows has focus. On wlroots compositors (Sway, Hyprland, river
  and similar), every client can bind privileged protocols by default which
  allows a lot of dangerous things like reading the clipboard at any time,
  taking screenshots and injecting keystrokes. It is off by default.
- **Linux: `ENABLE_GRAPHICS=1` exposes the GPU kernel driver.** A bug in the
  driver is a way out of the sandbox. It is off by default.
- **Bearer tokens (gh/arc/moz-phab) are readable**, not just unmodifiable — a
  compromised agent could exfiltrate them over the network.
- **`~/.claude`/`~/.claude.json` are shared with host claude**, read-write —
  a compromised sandbox can alter memory/settings/hooks/MCP config used by
  the host's `claude` later. (Isolating via `CLAUDE_CONFIG_DIR` was tried and
  reverted — it broke macOS login.)
- **`$CODEX_HOME` is shared with host Codex in Codex mode**, read-write — a
  compromised sandbox can alter settings, sessions, skills, plugins, or MCP
  configuration used by host Codex later. It is not exposed in Claude or
  `exec` mode.
- **macOS has no PID isolation** — the agent can enumerate host processes
  (not signal them).
- **macOS: `sandbox-exec` is deprecated** by Apple; still kernel-enforced
  today, but not guaranteed long-term.
- **macOS: Mach IPC is mostly allowed** (breaks AppKit startup otherwise);
  only a hand-picked deny list is blocked, so this is not comprehensive.
- **macOS: LaunchServices is reachable** — required for Firefox to start, but
  means a compromised agent can launch arbitrary apps/files via `NSWorkspace`,
  a real confused-deputy escape. The URL-open allowlist is not a hard boundary
  here.
- **macOS: the clipboard is reachable** — Firefox aborts on startup if
  pasteboard access is denied, so it's allowed; a compromised agent can read/
  write it.
- **macOS: Firefox's own per-process sandboxing is disabled** — `sandbox_init()`
  can't nest, so the outer Seatbelt profile is the only confinement in effect;
  content/GPU/etc. processes run without their usual isolation.
