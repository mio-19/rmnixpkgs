#!/usr/bin/env python3
"""Exercise activation ownership using temporary files and a fake vellum CLI."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("activate.sh").read_text()
FUNCTIONS = SCRIPT[SCRIPT.index("log() {"):SCRIPT.index("mode=apply")]
FUNCTIONS += SCRIPT[SCRIPT.index("remove_owned() {"):SCRIPT.index("# --- main")]


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("gen", "apps", "state"):
            (self.root / name).mkdir()
        (self.root / "db").write_text("P:foreign\n")
        (self.root / "gen/vellum.packages").write_text("foreign\nnew@testing\nfailed\n")
        (self.root / "gen/vellum.options").write_text("cleanup=0\n")
        cli = self.root / "vellum"
        cli.write_text('''#!/bin/sh
case "$1" in
add)
    name=${2%%@*}
    [ "$name" != failed ] || exit 1
    grep -qxF "P:$name" "$VELLUM_DB" || printf 'P:%s\\n' "$name" >> "$VELLUM_DB"
    ;;
del)
    printf '%s\\n' "$2" >> "$TEST_ROOT/deleted"
    [ ! -f "$TEST_ROOT/fail-delete" ] || exit 1
    ;;
esac
''')
        cli.chmod(0o755)
        self.env = dict(os.environ, TEST_ROOT=str(self.root))

    def run_function(self, commands):
        setup = '''
STATE=$TEST_ROOT/state
gen=$TEST_ROOT/gen
APPDIR=$TEST_ROOT/apps
MARKER=.rmpp-config
VELLUM=$TEST_ROOT/vellum
VELLUM_DB=$TEST_ROOT/db
VELLUM_STATE=$STATE/vellum-managed
export VELLUM_DB
'''
        subprocess.run(["sh", "-eu", "-c", setup + FUNCTIONS + commands],
                       env=self.env, check=True, capture_output=True, text=True)

    def managed(self):
        return set((self.root / "state/vellum-managed").read_text().split())

    def test_only_successful_new_packages_are_owned(self):
        (self.root / "state").rmdir()
        self.run_function("apply_vellum")
        self.assertEqual(self.managed(), {"new"})
        self.run_function("apply_vellum")
        self.assertEqual(self.managed(), {"new"})

    def test_disabled_cleanup_retains_ownership_for_later(self):
        self.run_function("apply_vellum")
        (self.root / "gen/vellum.packages").write_text("")
        self.run_function("apply_vellum")
        self.assertEqual(self.managed(), {"new"})
        (self.root / "gen/vellum.options").write_text("cleanup=1\n")
        (self.root / "fail-delete").touch()
        self.run_function("apply_vellum")
        self.assertEqual(self.managed(), {"new"})
        (self.root / "fail-delete").unlink()
        self.run_function("apply_vellum")
        self.assertEqual(self.managed(), set())
        self.assertEqual((self.root / "deleted").read_text(), "new\nnew\n")

    def test_foreign_appload_entries_and_staging_names_survive(self):
        source = self.root / "gen/appload/app"
        source.mkdir(parents=True)
        (source / ".rmpp-config").touch()
        (source / "external.manifest.json").write_text("{}")
        foreign = self.root / "apps/app"
        foreign.symlink_to(self.root / "missing")
        staging = self.root / "apps/app.tmp"
        staging.mkdir()
        (staging / "foreign").touch()
        self.run_function("apply_appload")
        self.assertTrue(foreign.is_symlink())
        foreign.unlink()
        self.run_function("apply_appload")
        self.assertTrue((foreign / ".rmpp-config").exists())
        self.assertTrue((staging / "foreign").exists())


if __name__ == "__main__":
    unittest.main()
