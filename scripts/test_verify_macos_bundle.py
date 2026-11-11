#!/usr/bin/env python3
"""Exercise packaging failures without requiring Apple command-line tools."""
import pathlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

VERIFY = pathlib.Path(__file__).with_name('verify_macos_bundle.py')

class BundleChecks(unittest.TestCase):
    def verify(self, slices='arm64', dependency='@rpath/libSystem.dylib'):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / '含空格 fqapp.app'
            frameworks = app / 'Contents/Frameworks'
            frameworks.mkdir(parents=True)
            (frameworks / 'libfqapi_core.dylib').touch()
            (frameworks / 'Mpv.framework').mkdir()
            (app / 'Contents/MacOS').mkdir()
            (app / 'Contents/MacOS/fqapp').touch()
            def output(args, **kwargs):
                if args[0] == 'nm':
                    return '_fq_desktop_media_open\n_fq_desktop_media_close\n_fq_desktop_media_free'
                if args[0] == 'file':
                    return 'Mach-O 64-bit dynamically linked shared library'
                if args[0] == 'lipo':
                    return slices
                if args[0] == 'otool':
                    return f'{args[-1]}:\n\t{dependency} (compatibility version 1.0.0)\n'
                raise AssertionError(args)
            with patch.object(sys, 'argv', [str(VERIFY), str(app), 'arm64']), patch.object(subprocess, 'check_output', side_effect=output):
                runpy.run_path(str(VERIFY), run_name='__main__')

    def test_accepts_relocatable_matching_architecture(self):
        self.verify()

    def test_rejects_wrong_architecture(self):
        with self.assertRaisesRegex(SystemExit, 'Unexpected slices'):
            self.verify(slices='x86_64')

    def test_rejects_homebrew_dependency_leaks(self):
        with self.assertRaisesRegex(SystemExit, 'Nonportable dependency'):
            self.verify(dependency='/opt/homebrew/lib/libmpv.dylib')

if __name__ == '__main__':
    unittest.main()
