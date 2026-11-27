#!/usr/bin/env python3
"""Print the static update feed for an already published formal Android release."""
import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

APK_NAMES = ('app-arm64-v8a-release.apk', 'app-armeabi-v7a-release.apk')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag', help='Official GitHub Release tag, such as v1.0.208')
    parser.add_argument('--notes', required=True, type=Path, help='Release notes (UTF-8)')
    parser.add_argument('--checksums', required=True, type=Path, help='The release SHA256SUMS file')
    parser.add_argument('--mirror-base', help='HTTPS directory containing identical release files')
    args = parser.parse_args()
    if not re.fullmatch(r'v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}', args.tag):
        parser.error('expected a formal release tag')
    lines = args.checksums.read_text(encoding='utf-8').splitlines()
    for name in APK_NAMES:
        if sum(bool(re.fullmatch(r'[0-9a-fA-F]{64}\s+\*?' + re.escape(name), line.strip()))
               for line in lines) != 1:
            parser.error(f'SHA256SUMS must contain one hash for {name}')
    payload = {'tag_name': args.tag, 'body': args.notes.read_text(encoding='utf-8')}
    if args.mirror_base:
        base = urlsplit(args.mirror_base)
        if base.scheme != 'https' or not base.hostname or base.username or base.query or base.fragment:
            parser.error('mirror base must be an HTTPS directory without credentials, query or fragment')
        payload['mirror_assets'] = {
            name: args.mirror_base.rstrip('/') + '/' + name
            for name in (*APK_NAMES, 'SHA256SUMS')
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
