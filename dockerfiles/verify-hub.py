#!/usr/bin/env python3
"""Verify that published Docker Hub tags refer to the validated image."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def verified_record(data, reference, expected_id, architecture='amd64'):
    records = data if isinstance(data, list) else [data]
    matches = []
    for record in records:
        descriptor = record.get('Descriptor', {})
        if descriptor.get('platform', {}).get('architecture') != architecture:
            continue
        manifest = record.get('SchemaV2Manifest', record.get('OCIManifest', {}))
        if manifest.get('config', {}).get('digest') != expected_id:
            raise ValueError('Docker Hub image differs from the validated local image')
        digest = descriptor.get('digest', '')
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
            raise ValueError('Docker Hub manifest digest is missing')
        matches.append({'reference': reference, 'digest': digest, 'image_id': expected_id,
                        'architecture': architecture})
    if len(matches) != 1:
        raise ValueError('Expected exactly one validated '+architecture+' image')
    return matches[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image_id')
    parser.add_argument('output', type=Path)
    parser.add_argument('references', nargs='+')
    parser.add_argument('--architecture',choices=['amd64','arm64'],default='amd64')
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', args.image_id):
        raise ValueError('Invalid local image identity')
    records = []
    for reference in args.references:
        pattern=r'spiritlhl/pve:[89]_(?:aarch64|arm64)' if args.architecture=='arm64' else r'spiritlhl/pve:[789](?:_x86_64)?'
        if not re.fullmatch(pattern, reference):
            raise ValueError('Unexpected Docker Hub publication target')
        raw = subprocess.check_output(['docker', 'manifest', 'inspect', '--verbose', reference],
                                      text=True, timeout=180)
        records.append(verified_record(json.loads(raw), reference, args.image_id,args.architecture))
    if len({record['digest'] for record in records}) != 1:
        raise ValueError('Published version and architecture tags differ')
    args.output.write_text(json.dumps(records, indent=2) + '\n')
    print('Docker Hub tags match the validated image: ' + ', '.join(args.references), flush=True)


if __name__ == '__main__':
    main()
