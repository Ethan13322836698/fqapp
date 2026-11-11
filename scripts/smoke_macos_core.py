#!/usr/bin/env python3
"""Load the packaged Rust core on the native CI host and validate its C ABI."""
import ctypes
import json
import pathlib
import sys

core = pathlib.Path(sys.argv[1]) / 'Contents/Frameworks/libfqapi_core.dylib'
library = ctypes.CDLL(str(core.resolve()))
open_media = library.fq_desktop_media_open
open_media.argtypes = [ctypes.c_char_p]
open_media.restype = ctypes.c_void_p
free_result = library.fq_desktop_media_free
free_result.argtypes = [ctypes.c_void_p]
free_result.restype = None
# Malformed input must return an owned JSON error, without making network calls.
pointer = open_media(b'{}')
if not pointer:
    raise SystemExit('Native core returned a null result')
try:
    response = json.loads(ctypes.string_at(pointer).decode('utf-8'))
    if not isinstance(response.get('error'), str):
        raise SystemExit('Native core did not reject the malformed media request')
finally:
    free_result(pointer)
print('Packaged Rust core loaded successfully; C ABI error handling and memory release passed')
