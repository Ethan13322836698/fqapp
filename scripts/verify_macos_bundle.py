#!/usr/bin/env python3
"""Check bundle architectures, Rust exports, and relocatable native dependencies."""
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
architecture = sys.argv[2]
required = {'x64': {'x86_64'}, 'arm64': {'arm64'}, 'universal': {'x86_64', 'arm64'}}[architecture]
core = app / 'Contents/Frameworks/libfqapi_core.dylib'
if not core.is_file():
    raise SystemExit('Missing Rust core')
for arch in required:
    exports = subprocess.check_output(['nm', '-arch', arch, '-gU', str(core)], text=True)
    for symbol in ('fq_desktop_media_open', 'fq_desktop_media_close', 'fq_desktop_media_free'):
        if symbol not in exports:
            raise SystemExit(f'Missing native media export for {arch}: {symbol}')
if not (app / 'Contents/MacOS/fqapp').is_file():
    raise SystemExit('Missing app executable')
if not any((app / 'Contents/Frameworks').glob('*[Mm]pv*.framework')):
    raise SystemExit('Missing mpv framework')
count = 0
for binary in (app / 'Contents').rglob('*'):
    if not binary.is_file() or binary.is_symlink():
        continue
    kind = subprocess.check_output(['file', '-b', str(binary)], text=True)
    if 'Mach-O' not in kind:
        continue
    count += 1
    actual = set(subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split())
    if actual != required:
        raise SystemExit(f'Unexpected slices in {binary.name}: {actual}; expected {required}')
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for dependency in dependencies:
        if not dependency.startswith(('\t', ' ')):
            continue
        name = dependency.strip().split(' (', 1)[0]
        if name.startswith('/') and not name.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Nonportable dependency in {binary.name}: {name}')
print(f'Validated {count} Mach-O files for {architecture}, including Rust media exports')
