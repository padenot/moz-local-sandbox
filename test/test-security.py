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

    def test_linux_launcher(self):
        self.assert_ok(self.run_command(["/bin/bash", REPO / "test/test-linux-launcher.sh"]))

    @unittest.skipUnless(MAC, "requires Seatbelt")
    def test_existing_macos_probes(self):
        self.assert_ok(self.run_command(["/bin/bash", REPO / "test/test-macos.sh"]))

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
                                  extra={"SSH_AUTH_SOCK": str(path), "MOZSB_NO_SSH_AGENT": ""}))
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
