#!/usr/bin/env python3
"""Apply only the reviewed design patch to the exact public production base."""
# SPDX-License-Identifier: AGPL-3.0-only
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_SHA256 = 'f165c3a72e1d5b71bbae49dd8f5c5b456b41e92a951f181090210a00f4afb50a'


def load_spec(root=ROOT):
    data = (root / 'fixtures/activity-design.json').read_bytes()
    if hashlib.sha256(data).hexdigest() != MANIFEST_SHA256:
        raise ValueError('Reviewed design manifest digest mismatch')
    spec = json.loads(data)
    patch = gzip.decompress((root / 'fixtures/activity-design.patch.gz').read_bytes())
    if hashlib.sha256(patch).hexdigest() != spec['patch_sha256']:
        raise ValueError('Reviewed design patch digest mismatch')
    return spec, patch


def verify_hashes(upstream, spec, stage):
    for name, hashes in spec['files'].items():
        if hashlib.sha256((upstream / name).read_bytes()).hexdigest() != hashes[stage]:
            raise ValueError(f'Design {stage} source mismatch: {name}')


def apply(upstream, spec, patch):
    def git(*args, env=None):
        return subprocess.run(['git', '-C', str(upstream), *args], check=True,
                              capture_output=True, text=True, timeout=60, env=env).stdout.strip()
    if git('rev-parse', 'HEAD') != spec['base_commit']:
        raise ValueError('Design base commit mismatch')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Design base checkout must be clean')
    verify_hashes(upstream, spec, 'before')
    with tempfile.TemporaryDirectory(prefix='activity-design-patch-') as folder:
        patch_file = Path(folder) / 'reviewed.patch'
        patch_file.write_bytes(patch)
        git('apply', '--check', str(patch_file))
        git('apply', str(patch_file))
    verify_hashes(upstream, spec, 'after')
    if set(git('diff', '--name-only').splitlines()) != set(spec['files']):
        raise ValueError('Design patch changed an unexpected path')
    with tempfile.TemporaryDirectory(prefix='activity-design-index-') as folder:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(folder) / 'index'))
        git('read-tree', 'HEAD', env=env)
        git('add', '--', *spec['files'], env=env)
        tree = git('write-tree', env=env)
    if tree != spec['patched_tree']:
        raise ValueError('Design result tree mismatch')
    return dict(spec, verified=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, required=True)
    args = parser.parse_args()
    spec, patch = load_spec()
    identity = apply(args.upstream.resolve(), spec, patch)
    (ROOT / '.design-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
    print('Verified reviewed patch, all seven before/after source hashes, and exact result tree.')


if __name__ == '__main__':
    main()
