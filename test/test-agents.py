#!/usr/bin/env python3
"""Live end-to-end tests: run real agents through the launcher.

Uses the host's real HOME and agent logins, and makes (cheap) API calls, so
this is meant to be run locally, not in CI: `make test-live`. A hang fails
the test instead of blocking forever.

MOZSB_TEST_CLAUDE_MODEL and MOZSB_TEST_CODEX_MODEL override the models.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
LAUNCHER = REPO / ("ccode-macos" if sys.platform == "darwin" else "ccode")
TIMEOUT = 180
PROMPT = ("Use your shell tool to run exactly this command: echo PONG > pong.txt\n"
          "Then reply with exactly the word DONE and nothing else.")


class AgentTests(unittest.TestCase):
    def setUp(self):
        # Under HOME rather than /tmp: bwrap mounts a fresh tmpfs over /tmp.
        tmp = tempfile.TemporaryDirectory(prefix=".mozsb-live-", dir=Path.home())
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name).resolve()

    def run_agent(self, mode, *args):
        if not shutil.which(mode):
            self.skipTest(f"{mode} is not installed")
        env = dict(os.environ, MOZSB_SRC=str(self.work))
        try:
            result = subprocess.run([LAUNCHER, mode, *args, PROMPT], cwd=self.work, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    timeout=TIMEOUT)
        except subprocess.TimeoutExpired as e:
            self.fail(f"{mode} hung for {TIMEOUT}s\nstdout: {e.stdout}\nstderr: {e.stderr}")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("DONE", result.stdout, output)
        self.assertEqual((self.work / "pong.txt").read_text().strip(), "PONG", output)

    def test_claude(self):
        # User settings can carry hooks pointing outside the sandbox; they
        # would test the host's config rather than the launcher.
        self.run_agent("claude", "-p", "--setting-sources", "project",
                       "--model", os.environ.get("MOZSB_TEST_CLAUDE_MODEL", "haiku"))

    def test_codex(self):
        self.run_agent("codex", "exec", "--skip-git-repo-check",
                       "-m", os.environ.get("MOZSB_TEST_CODEX_MODEL", "gpt-6-luna"),
                       "-c", "model_reasoning_effort=low")


if __name__ == "__main__":
    unittest.main()
