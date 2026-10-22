#!/usr/bin/env python3
"""Regression probes using synthetic host files, never real credentials."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

REPO = Path(__file__).resolve().parents[1]
MAC = sys.platform == "darwin"


class SecurityTests(unittest.TestCase):
    def setUp(self):
        # macOS grants all of /tmp and /var/folders: denied-file fixtures must
        # be elsewhere or a negative test would exercise the wrong policy.
        self.tmp = tempfile.TemporaryDirectory(prefix=".mozsb-test-", dir=Path.home())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.work = self.home / "src"
        self.work.mkdir(parents=True)
        self.hostbin = self.root / "host-bin"
        self.hostbin.mkdir()
        self.write(self.hostbin / "gh", "#!/bin/sh\nexit 1\n", 0o755)
        self.write(self.hostbin / "claude", "#!/bin/sh\nprintf 'ARG=%s\\n' \"$@\"\nenv\n", 0o755)
        self.write(self.hostbin / "codex", "#!/bin/sh\nprintf 'ARG=%s\\n' \"$@\"\n", 0o755)
        self.write(self.home / ".gitconfig", "[user]\nname = Test\nemail = test@example.invalid\n")
        self.write(self.home / ".ssh/id_ed25519", "synthetic private key\n")
        self.write(self.home / "Library/Application Support/Firefox/Profiles/test/cookies.sqlite",
                   "synthetic cookie\n")
        (self.home / "Library/Keychains").mkdir(parents=True)
        (self.home / "Documents").mkdir()
        self.env = {
            "HOME": str(self.home),
            "PATH": str(self.hostbin) + os.pathsep + os.environ["PATH"],
            "SHELL": "/bin/bash",
            "MOZSB_SRC": str(self.work),
            "MOZSB_NO_SSH_AGENT": "1",
            "MOZSB_CLAUDE_BIN": str(self.hostbin / "claude"),
            "MOZSB_CODEX_BIN": str(self.hostbin / "codex"),
        }

    @staticmethod
    def write(path, contents, mode=0o600):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        path.chmod(mode)

    def run_command(self, argv, *, cwd=None, extra=None, input=None):
        env = dict(self.env)
        env.update(extra or {})
        env = {key: value for key, value in env.items() if value is not None}
        return subprocess.run([str(arg) for arg in argv], cwd=cwd or self.work,
                              env=env, input=input, text=True, capture_output=True, timeout=30)

    def launch(self, *args, cwd=None, extra=None):
        return self.run_command([REPO / "ccode-macos", "exec", *args], cwd=cwd, extra=extra)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_denied(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Operation not permitted", result.stderr)

    def test_url_parser(self):
        loader = importlib.machinery.SourceFileLoader("open_server", str(REPO / "bin/ccode-open-server"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        for url in ["https://bugzilla.mozilla.org/show_bug.cgi?id=1",
                    "https://phabricator.services.mozilla.com/D1", "http://127.0.0.1:8000/test"]:
            self.assertTrue(module.allowed(url), url)
        for url in [r"https://example.invalid\@bugzilla.mozilla.org/",
                    r"http://example.invalid\@127.0.0.1/", "https://user@bugzilla.mozilla.org/",
                    "\nhttps://bugzilla.mozilla.org/", "http://localhost:65536/",
                    "http://localhost:bad/", "http://localhost/\x00", "file:///tmp/a"]:
            self.assertFalse(module.allowed(url), url)

    def test_clipboard_broker(self):
        # Fake host wl-clipboard: the clipboard offers text and a PNG.
        self.write(self.hostbin / "wl-paste", """#!/bin/sh
case "$*" in
  --list-types) printf 'text/plain\\nimage/png\\n' ;;
  *image/png) printf PNGDATA ;;
  *) printf secret-password ;;
esac
""", 0o755)
        copied = self.root / "copied"
        self.write(self.hostbin / "wl-copy", f"#!/bin/sh\necho \"$*\" >> {copied}\ncat >> {copied}\n", 0o755)
        env = dict(self.env, CCODE_CLIPBOARD_TOKEN="tok")
        server = subprocess.Popen([sys.executable, "-I", REPO / "bin/ccode-open-server"], env=env,
                                  stdout=subprocess.PIPE, text=True)
        self.addCleanup(server.stdout.close)
        self.addCleanup(server.wait)
        self.addCleanup(server.kill)
        port = server.stdout.readline().strip().removeprefix("OPEN_PORT=")
        extra = {"CCODE_OPEN_PORT": port, "CCODE_CLIPBOARD_TOKEN": "tok"}

        def shim(name, *args, extra=extra, input=None):
            return self.run_command([REPO / f"bin/ccode-{name}", *args], extra=extra, input=input)

        self.assertEqual(shim("wl-paste", "-l").stdout, "image/png\n")
        self.assertEqual(shim("wl-paste", "--type", "image/png").stdout, "PNGDATA")
        for args in [(), ("--type", "text/plain"), ("--type", "image/png;text/plain")]:
            self.assertNotIn("secret", shim("wl-paste", *args).stdout, args)
        self.assertNotEqual(shim("wl-paste", "-l", extra=dict(extra, CCODE_CLIPBOARD_TOKEN="bad")).returncode, 0)
        self.assert_ok(shim("wl-copy", input="hello"))
        self.assert_ok(shim("wl-copy", "--primary", input="world"))
        self.assertEqual(copied.read_text(), "\nhello--primary\nworld")

        # The shims run in the sandbox and can be bypassed: hit the server directly.
        def status(path, token="tok", data=None, headers={}):
            request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                             headers={"X-Clipboard-Token": token, **headers})
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    return response.status, response.read()
            except urllib.error.HTTPError as e:
                return e.code, e.read()
        self.assertEqual(status("/paste?type=image/png"), (200, b"PNGDATA"))
        for path in ["/paste", "/paste?type=text/plain", "/paste?type=image/png%3Btext/plain"]:
            self.assertEqual(status(path)[0], 403, path)
        self.assertEqual(status("/paste?type=image/png", token="bad")[0], 403)
        self.assertEqual(status("/paste?type=image/png", token="\u00e9")[0], 403)
        self.assertEqual(status("/copy", token="bad", data=b"x")[0], 403)
        self.assertEqual(status("/copy", data=b"x", headers={"Content-Length": "-1"})[0], 413)
        self.assertEqual(copied.read_text(), "\nhello--primary\nworld")

    def test_npmrc_symlinks(self):
        state = self.home / ".sandbox"
        state.mkdir()
        secret = self.root / "secret"
        self.write(secret, "sentinel")
        (state / "npmrc").symlink_to(secret)
        result = self.run_command([sys.executable, "-I", REPO / "bin/ccode-npmrc", state, state / "npm-prefix"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(secret.read_text(), "sentinel")
        (state / "npmrc").unlink()
        self.write(state / "npmrc", "prefix=old\n//registry.example/:_authToken=synthetic\n")
        (state / "npmrc.new").symlink_to(secret)
        self.assert_ok(self.run_command([sys.executable, "-I", REPO / "bin/ccode-npmrc", state, state / "npm-prefix"]))
        self.assertEqual(secret.read_text(), "sentinel")
        self.assertIn("_authToken=synthetic", (state / "npmrc").read_text())

    def test_noexec_permissions_and_symlinks(self):
        helper = REPO / "bin/ccode-noexec"
        state = self.root / "noexec.json"
        old = self.work / "old"
        script = self.work / "script"
        external = self.root / "external"
        self.write(old, "old", 0o600)
        self.write(script, "before", 0o755)
        self.write(external, "outside", 0o755)
        self.assert_ok(self.run_command([sys.executable, "-I", helper, "snapshot", self.work, state]))
        old.chmod(0o755)  # No mtime change.
        script.write_text("after")
        self.write(self.work / "new", "new", 0o755)
        (self.work / "link").symlink_to(external)
        self.assert_ok(self.run_command([sys.executable, "-I", helper, "restore", self.work, state]))
        self.assertEqual(old.stat().st_mode & 0o111, 0)
        self.assertEqual((self.work / "new").stat().st_mode & 0o111, 0)
        self.assertEqual(script.stat().st_mode & 0o111, 0o111)
        self.assertEqual(external.stat().st_mode & 0o111, 0o111)

    def test_installer_copies_launcher(self):
        (self.home / ".local/bin").mkdir(parents=True)
        result = self.run_command(["/bin/bash", REPO / "install.sh"], input="n\n")
        self.assert_ok(result)
        installed = (self.home / ".local/bin/mozsb").resolve()
        self.assertTrue(installed.is_file())
        self.assertFalse(installed.is_relative_to(REPO))
        self.assertTrue((installed.parent / "bin/ccode-open-server").is_file())
        if MAC:
            result = self.run_command([installed, "exec", "/bin/sh", "-c", "open blocked:"])
            self.assertIn("ccode-open: blocked:", result.stderr)
            result = self.run_command([installed, "exec", "/usr/bin/touch", installed])
            self.assert_denied(result)

    def config_settings(self, *, extra=None, cwd=None):
        return self.run_command(["/bin/bash", "-eu", "-c", '''
source "$1/bin/ccode-config"
printf 'SRC=%s\n' "${_cfg_global[@]-}"
printf 'MATCH_SRC=%s\n' "${_cfg_match[@]-}"
printf 'RO=%s\nBIN=%s\nSSH=%s\nAGENT=%s\nWL=%s\nGFX=%s\nGPU=%s\n' "$MOZSB_EXTRA_RO_DIRS" "${MOZSB_EXTRA_BIN_DIR-}" "${MOZSB_NO_SSH_AGENT-}" "${MOZSB_CODEX_BIN-}" "${MOZSB_ENABLE_WAYLAND-}" "${MOZSB_ENABLE_GRAPHICS-}" "${MOZSB_GPU-}"
''', "config-test", REPO], extra=extra, cwd=cwd)

    def test_config_directory_and_precedence(self):
        config_home = self.home / "custom-config"
        config = config_home / "mozsb/config"
        self.write(config, """# global defaults
SRC = ~/src
EXTRA_RO_DIRS = ~/reference data
EXTRA_RO_DIRS = /data/reference
EXTRA_BIN_DIR = ~/tools/bin
NO_SSH_AGENT = 0
CODEX_BIN = /config/codex
[~/src]
EXTRA_RO_DIRS = ~/checkout-reference
NO_SSH_AGENT = 1
ENABLE_WAYLAND = 1
ENABLE_GRAPHICS = 1
GPU = 0000:01:00.0
[~/src/nested]
SRC = ~/src/nested
EXTRA_RO_DIRS = ~/nested-reference
""")
        # New config wins over the legacy fallback. Its directory also holds env.
        self.write(config_home / "ccode", "EXTRA_RO_DIRS = /legacy\n")
        self.write(config_home / "mozsb/env", "SANDBOX_SETTING=value\n")
        extra = {"XDG_CONFIG_HOME": str(config_home)}
        result = self.config_settings(extra=extra, cwd=self.home)
        self.assert_ok(result)
        self.assertIn("RO=~/reference data:/data/reference\n", result.stdout)
        self.assertIn(f"BIN={self.home}/tools/bin\n", result.stdout)
        # Environment already sets these in setUp, so it wins over config.
        self.assertIn("SSH=1\n", result.stdout)
        self.assertIn(f"AGENT={self.hostbin}/codex\n", result.stdout)
        result = self.config_settings(extra=extra)
        self.assert_ok(result)
        self.assertIn("RO=~/checkout-reference\n", result.stdout)
        self.assertIn("WL=1\n", result.stdout)
        self.assertIn("GFX=1\n", result.stdout)
        self.assertIn("GPU=0000:01:00.0\n", result.stdout)
        nested = self.work / "nested"
        nested.mkdir()
        result = self.config_settings(extra=extra, cwd=nested)
        self.assert_ok(result)
        self.assertIn(f"MATCH_SRC={nested}\n", result.stdout)
        self.assertIn("RO=~/nested-reference\n", result.stdout)
        result = self.config_settings(extra={**extra, "MOZSB_NO_SSH_AGENT": None,
                                             "MOZSB_CODEX_BIN": None})
        self.assert_ok(result)
        self.assertIn("SSH=1\n", result.stdout)
        self.assertIn("AGENT=/config/codex\n", result.stdout)
        result = self.config_settings(extra={**extra, "MOZSB_NO_SSH_AGENT": None}, cwd=self.home)
        self.assert_ok(result)
        self.assertIn("SSH=0\n", result.stdout)
        self.assertIn("WL=\n", result.stdout)
        self.assertIn("GFX=\n", result.stdout)
        for override in [{"MOZSB_EXTRA_RO_DIRS": "/override"},
                         {"CCODE_EXTRA_RO_DIRS": "/override"},
                         {"MOZSB_EXTRA_RO_DIRS": ""}]:
            result = self.config_settings(extra={**extra, **override})
            self.assert_ok(result)
            self.assertIn("RO=" + next(iter(override.values())) + "\n", result.stdout)

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_config_and_env_files_together(self):
        config_home = self.home / "settings"
        reference = self.home / "reference data"
        self.write(reference / "data", "reference contents\n")
        self.write(config_home / "mozsb/config", f"""SRC = ~/src
EXTRA_RO_DIRS = ~/reference data
CLAUDE_BIN = {self.hostbin}/claude
NO_SSH_AGENT = 1
""")
        self.write(config_home / "mozsb/env", "CONFIG_TEST=value-from-env-file\n")
        extra = {"XDG_CONFIG_HOME": str(config_home), "MOZSB_SRC": None,
                 "MOZSB_CLAUDE_BIN": None, "MOZSB_NO_SSH_AGENT": None}
        result = self.run_command([REPO / "ccode-macos", "claude"], extra=extra)
        self.assert_ok(result)
        self.assertIn("CONFIG_TEST=value-from-env-file\n", result.stdout)
        self.assert_ok(self.launch("/bin/cat", reference / "data", extra=extra))
        self.assert_denied(self.launch("/usr/bin/touch", reference / "data", extra=extra))

    def test_legacy_config_and_literal_values(self):
        marker = self.home / "must-not-exist"
        legacy = self.home / ".config/mozsb"
        self.write(legacy, f"SRC = ~/src\nEXTRA_RO_DIRS = $(touch {marker})\n")
        result = self.config_settings()
        self.assert_ok(result)
        self.assertIn(f"SRC={self.work}\n", result.stdout)
        self.assertIn(f"RO=$(touch {marker})\n", result.stdout)
        self.assertFalse(marker.exists())
        legacy.rename(legacy.with_name("ccode"))
        result = self.config_settings()
        self.assert_ok(result)
        self.assertIn(f"SRC={self.work}\n", result.stdout)

    def test_linux_launcher(self):
        self.assert_ok(self.run_command(["/bin/bash", REPO / "test/test-linux-launcher.sh"]))

    @unittest.skipUnless(sys.platform == "linux", "requires Linux and bubblewrap")
    def test_linux_codex_stays_in_sandbox(self):
        for directory in [".local/bin", ".cargo/bin", ".rustup", ".mozbuild"]:
            (self.home / directory).mkdir(parents=True, exist_ok=True)
        for config in [".arcrc", ".moz-phab-config"]:
            self.write(self.home / config, "{}\n")
        path = self.home / ".codex/app-server-control/app-server-control.sock"
        path.parent.mkdir(parents=True)
        server = socket.socket(socket.AF_UNIX)
        self.addCleanup(server.close)
        server.bind(str(path))
        server.listen(5)
        server.settimeout(0.1)
        # A synthetic Codex tries the host daemon unless explicitly disabled.
        # With no-daemon, its child server must inherit the PID namespace.
        self.write(self.hostbin / "codex", """#!/usr/bin/python3
import os, socket, subprocess, sys
if '--no-daemon' not in sys.argv:
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.path.join(os.environ['CODEX_HOME'], 'app-server-control/app-server-control.sock'))
    sys.exit(77)
subprocess.run(['/usr/bin/readlink', '/proc/self/ns/pid'], check=True)
""", 0o755)
        host_namespace = os.readlink("/proc/self/ns/pid")
        for args in [[], ["resume", "--last"], ["fork", "session-id"], ["exec", "prompt"]]:
            with self.subTest(args=args):
                result = self.run_command([REPO / "ccode", "codex", *args])
                self.assert_ok(result)
                self.assertRegex(result.stdout.strip(), r"^pid:\[\d+\]$")
                self.assertNotEqual(result.stdout.strip(), host_namespace)
                with self.assertRaises(socket.timeout):
                    server.accept()

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_extra_read_only_directories(self):
        reference = self.home / 'reference "data"'
        nested = self.work / "read-only"
        for directory in [reference, nested]:
            self.write(directory / "data", "reference contents\n")
        link = self.home / "reference-link"
        link.symlink_to(reference, target_is_directory=True)
        extra = {"MOZSB_EXTRA_RO_DIRS": "~/reference-link:" + str(nested),
                 "MOZSB_EXTRA_BIN_DIR": str(self.hostbin)}
        for directory in [reference, nested]:
            self.assert_ok(self.launch("/bin/cat", directory / "data", extra=extra))
            self.assert_denied(self.launch("/usr/bin/touch", directory / "data", extra=extra))
            self.assert_denied(self.launch("/usr/bin/touch", directory / "new", extra=extra))
        result = self.launch("/usr/bin/printenv", "PATH", extra=extra)
        self.assert_ok(result)
        paths = result.stdout.strip().split(":")
        self.assertEqual(paths[0], str(self.hostbin))
        for directory in [reference, link, nested]:
            self.assertNotIn(str(directory), paths)
        result = self.launch("/usr/bin/true", extra={"MOZSB_EXTRA_RO_DIRS": str(self.home / "missing")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a directory", result.stderr)

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_existing_macos_probes(self):
        self.assert_ok(self.run_command(["/bin/bash", REPO / "test/test-macos.sh"]))

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_codex_runs_without_host_daemon(self):
        # Simulate the new CLI default: connecting to the host daemon fails
        # unless the launcher selects an in-process server. Repeated flags
        # are rejected by Codex's argument parser as well.
        self.write(self.hostbin / "codex", """#!/bin/bash
count=0
for arg in "$@"; do
    [[ "$arg" != "--" ]] || break
    if [[ "$arg" == "--no-daemon" ]]; then count=$((count+1)); fi
done
if [[ "$count" != 1 ]]; then
    echo 'Error: app server did not become ready' >&2
    exit 2
fi
printf 'ARG=%s\\n' "$@"
""", 0o755)
        for args in [[], ["resume", "--last"], ["fork", "session-id"],
                     ["exec", "prompt with spaces"], ["--no-daemon"],
                     ["resume", "--no-daemon", "--last"], ["--", "--no-daemon"]]:
            with self.subTest(args=args):
                result = self.run_command([REPO / "ccode-macos", "codex", *args])
                self.assert_ok(result)
                received = result.stdout.splitlines()
                self.assertEqual(received[0], "ARG=--dangerously-bypass-approvals-and-sandbox")
                self.assertEqual(received[-len(args):] if args else [],
                                 ["ARG=" + arg for arg in args])
                self.assertNotIn("Terminated:", result.stderr)

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_existing_private_files_are_denied(self):
        self.assert_ok(self.launch("/usr/bin/true"))
        for path in [self.home / ".ssh/id_ed25519",
                     self.home / "Library/Application Support/Firefox/Profiles/test/cookies.sqlite"]:
            self.assert_denied(self.launch("/bin/cat", path))
            self.assert_denied(self.launch("/usr/bin/touch", path))

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_broad_cwd_and_source_rejected(self):
        for cwd, extra in [(self.home, {}), (self.home, {"MOZSB_CWD_ONLY": "1"}),
                           (self.work, {"MOZSB_SRC": str(self.home)}),
                           (self.work, {"MOZSB_SRC": "/"})]:
            result = self.launch("/usr/bin/true", cwd=cwd, extra=extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mozsb:", result.stderr)
        alias = self.root / "checkout-alias"
        alias.symlink_to(REPO, target_is_directory=True)
        result = self.run_command([alias / "ccode-macos", "exec", "/usr/bin/true"],
                                  cwd=REPO, extra={"MOZSB_SRC": str(REPO)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("launcher is inside", result.stderr)

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_profile_path_injection(self):
        secret = self.root / "secret"
        self.write(secret, "sentinel")
        attack = self.work / 'x")) (allow default) (allow file-read* (regex ".*'
        attack.mkdir()
        for extra in [{}, {"MOZSB_CWD_ONLY": "1"}]:
            self.assert_ok(self.launch("/usr/bin/true", cwd=attack, extra=extra))
            self.assert_denied(self.launch("/bin/cat", secret, cwd=attack, extra=extra))

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_state_path_boundary(self):
        self.assert_ok(self.launch("/usr/bin/true", extra={"MOZBUILD_STATE_PATH": str(self.work / "new/state")}))
        result = self.launch("/usr/bin/true", extra={"MOZBUILD_STATE_PATH": str(self.home / "src-other")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the sandbox", result.stderr)

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_log_symlink_cannot_truncate_host_file(self):
        secret = self.root / "secret"
        self.write(secret, "sentinel")
        self.assert_ok(self.launch("/bin/ln", "-s", secret, self.home / ".sandbox/open-server.log"))
        self.assert_ok(self.launch("/usr/bin/true"))
        self.assertEqual(secret.read_text(), "sentinel")

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_ssh_socket_forwarding_and_optout(self):
        # A real AF_UNIX listener with no SSH keys or other host capabilities.
        server = socket.socket(socket.AF_UNIX)
        self.addCleanup(server.close)
        path = self.root / "agent.sock"
        server.bind(str(path))
        server.listen(5)
        connect = "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])"
        self.assert_ok(self.launch(sys.executable, "-c", connect, path,
                                  extra={"SSH_AUTH_SOCK": str(path), "MOZSB_NO_SSH_AGENT": "0"}))
        self.assert_denied(self.launch(sys.executable, "-c", connect, path,
                                      extra={"SSH_AUTH_SOCK": str(path)}))
        result = self.launch("/usr/bin/env", extra={"SSH_AUTH_SOCK": str(path)})
        self.assert_ok(result)
        self.assertNotIn("SSH_AUTH_SOCK=", result.stdout)
        # The opt-out must still win if a socket happens to be under RW_ROOT.
        server_in_work = socket.socket(socket.AF_UNIX)
        self.addCleanup(server_in_work.close)
        work_socket = self.work / "agent.sock"
        server_in_work.bind(str(work_socket))
        server_in_work.listen(5)
        self.assert_denied(self.launch(sys.executable, "-c", connect, work_socket,
                                      extra={"SSH_AUTH_SOCK": str(work_socket)}))

    def test_host_git_overrides_local_config(self):
        hooks = self.work / "hooks"
        self.write(hooks / "pre-commit", "#!/bin/sh\nexit 99\n", 0o755)
        self.assert_ok(self.run_command(["git", "init", "-q"]))
        self.assert_ok(self.run_command(["git", "config", "core.hooksPath", hooks]))
        self.assert_ok(self.run_command(["git", "-c", "core.hooksPath=/dev/null",
                                         "-c", "core.fsmonitor=false", "commit", "--allow-empty", "-qm", "test"]))


if __name__ == "__main__":
    unittest.main()
