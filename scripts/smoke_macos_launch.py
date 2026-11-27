#!/usr/bin/env python3
"""Confirm the packaged app launches and renders a frame on the native runner."""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryFile() as output:
    runner = subprocess.Popen(
        [str(app / 'Contents/MacOS/fqapp')],
        cwd=app.parent,
        env={**os.environ, 'FQAPP_MACOS_SMOKE': '1'},
        stdout=output,
        stderr=subprocess.STDOUT,
    )
    try:
        for _ in range(90):
            if runner.poll() is not None:
                raise SystemExit(f'macOS app exited during startup: {runner.returncode}')
            if b'fqapp: first frame rasterized' in os.pread(output.fileno(), 1024 * 1024, 0):
                time.sleep(2)
                if runner.poll() is not None:
                    raise SystemExit(f'macOS app exited just after its first frame: {runner.returncode}')
                print('The packaged macOS app launched and rendered its first frame')
                break
            time.sleep(1)
        else:
            raise SystemExit('The packaged macOS app did not render within 90 seconds')
    finally:
        if runner.poll() is None:
            runner.terminate()
            try:
                runner.wait(timeout=10)
            except subprocess.TimeoutExpired:
                runner.kill()
                runner.wait()
        output.seek(0)
        sys.stdout.write(output.read().decode(errors='replace')[-12000:])
