#!/usr/bin/env python3
"""Record validated deployed files in the configuration Git repository."""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import logging
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent
LOG = logging.getLogger('deployment-snapshot')


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.STDOUT).decode('utf-8', 'replace').strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sanitize(data, pref=False):
    text = data.decode('utf-8-sig')
    if pref:
        text = re.sub(r'(?m)^(\s*api_access_token\s*=).*$', r'\1 "REDACTED"', text)
        text = re.sub(r'(?m)^(\s*insert_url\s*=).*$', r'\1 []', text)
    text = re.sub(r'(?i)([?&](?:token|access_token|key)=)[^&\s"<>\x27)]+', r'\1REDACTED', text)
    text = re.sub(r'(?i)((?:%3f|%26)(?:token|access_token|key)%3d).*?(?=%26|[\s"<>\x27)]|$)', r'\1REDACTED', text)
    text = re.sub(r'(?i)(/link/)[A-Za-z0-9_-]+', r'\1REDACTED', text)
    text = re.sub(r'(?i)(/client/)[0-9a-f]{32}\b', r'\1REDACTED', text)
    text = re.sub(r'(/dns-query/)[A-Za-z0-9_-]+', r'\1DOGCLOUD_DOH_TOKEN', text)
    text = re.sub(r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b', 'REDACTED_UUID', text)
    text = re.sub(r'\b\d{8,12}:[A-Za-z0-9_-]{30,}\b', 'REDACTED_BOT_TOKEN', text)
    # Never silently export node credentials in URI form.
    if re.search(r'(?:vless|vmess|trojan|ssr?|hysteria2?|anytls|tuic)://', text):
        raise ValueError('Proxy credential URI found in candidate; stop for review')
    return text.replace('\r\n', '\n').encode('utf-8')


def collect(config, router_data=None):
    nas = Path(config['converter'])
    web = Path(config['subweb'])
    overlay = Path(config['overlay'])
    state = json.loads(Path(config['acl_state']).read_text(encoding='utf-8'))
    for path in (nas, web, overlay):
        if not path.is_dir():
            raise ValueError(f'Deployment directory unavailable: {path}')
    acl_repo = Path(config['acl_repository'])
    if git(acl_repo, 'branch', '--show-current') != 'local-production' or git(acl_repo, 'status', '--porcelain'):
        raise ValueError('ACL4SSR production branch must be clean and selected')
    if state['head'] != git(acl_repo, 'rev-parse', 'HEAD'):
        raise ValueError('ACL4SSR state does not match committed production branch')
    if Path(state['production']).resolve() != (nas / 'rules/ACL4SSR/Clash').resolve():
        raise ValueError('ACL4SSR state refers to another production path')
    files = {}
    sources = {}

    def add(source, target, redact=False, pref=False):
        data = source.read_bytes()
        if redact:
            data = sanitize(data, pref)
        files[target] = data
        sources[target] = str(source)

    for name, expected in state['files'].items():
        if Path(name).is_absolute() or '..' in Path(name).parts:
            raise ValueError('Invalid ACL4SSR manifest path')
        source = nas / 'rules/ACL4SSR/Clash' / name
        if digest(source.read_bytes()) != expected:
            raise ValueError(f'ACL4SSR production drift: {name}')
        add(source, 'Subconverter/rules/ACL4SSR/Clash/' + name)
    for name in ['GOUKI_Local.ini', 'GOUKI_Local2.ini', 'GOUKI_Online.ini']:
        add(nas / 'config' / name, 'Subconverter/config/' + name, redact=True)
    add(nas / 'base/GOUKI_Base.yml', 'Subconverter/base/GOUKI_Base.yml', redact=True)
    add(nas / 'pref.toml', 'Subconverter/pref.current.example.toml', redact=True, pref=True)
    add(nas / 'GOUKI_subconverter_notes.md', 'Subconverter/GOUKI_subconverter_notes.md', redact=True)
    for folder in ['snippets', 'rules/GOUKI']:
        for source in sorted((nas / folder).rglob('*')):
            if source.is_file() and source.suffix in {'.txt', '.toml', '.list'}:
                target = 'Subconverter/' + folder + '/' + source.relative_to(nas / folder).as_posix()
                add(source, target, redact=True)
    for name in ['ua_proxy.py', 'domains.json']:
        add(nas / 'airport_proxy' / name, 'airport_proxy/' + name)
    for name in ['index.html', 'favicon.ico', 'qrcode.min.js', 'LOCAL_CHANGES.md']:
        add(web / name, 'subweb/current-dist/' + name, redact=name.endswith('.md'))
    for folder in ['css', 'js', 'vendor']:
        for source in sorted((web / folder).rglob('*')):
            if source.is_file():
                add(source, 'subweb/current-dist/' + source.relative_to(web).as_posix())
    for name in ['apply.py', 'README.md', 'CURRENT_LOCAL_CHANGES.md']:
        add(overlay / name, 'subweb/local-overlay/' + name, redact=name.endswith('.md'))
    for source in sorted((overlay / 'vendor').rglob('*')):
        if source.is_file():
            add(source, 'subweb/local-overlay/' + source.relative_to(overlay).as_posix())
    if router_data is None:
        with urllib.request.urlopen(config['router_script_url'], timeout=15) as response:
            if response.status != 200:
                raise ValueError('Router script fetch failed')
            router_data = response.read(200000)
    if not router_data.startswith(b'#!/bin/bash') or b'result_limit_errors()' not in router_data:
        raise ValueError('Router response is not the expected submgr script')
    files['submgr/submgr.sh'] = router_data
    sources['submgr/submgr.sh'] = config['router_script_url']
    validate(files)
    provenance = {'acl_production_head': state['head'], 'acl_upstream_head': state['upstream'],
                  'files': {name: {'sha256': digest(data), 'source': sources[name]} for name, data in sorted(files.items())}}
    files['deployment-snapshot.json'] = (json.dumps(provenance, ensure_ascii=False, indent=2) + '\n').encode()
    return files


def validate(files):
    import tomllib
    import yaml
    for name, data in files.items():
        if name.endswith('.py'):
            ast.parse(data.decode('utf-8-sig'), filename=name)
        elif name.endswith('.json'):
            json.loads(data)
    tomllib.loads(files['Subconverter/pref.current.example.toml'].decode())
    yaml.safe_load(files['Subconverter/base/GOUKI_Base.yml'])
    index = files['subweb/current-dist/index.html'].decode()
    for forbidden in ['unpkg.com/jquery', 'fonts.googleapis.com/css2?family=Inter', 'cdnjs.cloudflare.com/ajax/libs/font-awesome']:
        if forbidden in index:
            raise ValueError('SUBWEB local resource overlay missing: ' + forbidden)


def update(repo, files, apply=False):
    changes = []
    # All candidates are read and validated before touching the repository.
    for name, data in files.items():
        path = repo / name
        if not path.is_file() or path.read_bytes().replace(b'\r\n', b'\n') != data.replace(b'\r\n', b'\n'):
            changes.append(name)
    if apply:
        for name in changes:
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(files[name])
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--commit', action='store_true')
    parser.add_argument('--push', action='store_true')
    args = parser.parse_args()
    if not ROOT.is_relative_to(Path('D:/Temp/CodeTemp').resolve()):
        parser.error('Run a copied tool from a dedicated CodeTemp runtime directory')
    if (args.commit or args.push) and not args.apply:
        parser.error('--commit/--push require --apply')
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                        handlers=[logging.FileHandler(ROOT / 'snapshot.log', encoding='utf-8'), logging.StreamHandler()])
    lock = ROOT / 'snapshot.lock'
    try:
        with lock.open('x'):
            pass
    except FileExistsError:
        LOG.error('Another snapshot run or stale lock exists'); return 1
    try:
        config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8'))
        repo = Path(config['repository'])
        if git(repo, 'branch', '--show-current') != config['branch'] or git(repo, 'status', '--porcelain'):
            raise ValueError('Configuration repository must be clean on the configured branch')
        before = git(repo, 'rev-parse', 'HEAD')
        files = collect(config)
        if git(repo, 'rev-parse', 'HEAD') != before or git(repo, 'status', '--porcelain'):
            raise ValueError('Configuration repository changed during collection')
        changes = update(repo, files, args.apply)
        (ROOT / 'last-plan.json').write_text(json.dumps({'candidate_files': len(files), 'changes': changes, 'applied': args.apply}, ensure_ascii=False, indent=2), encoding='utf-8')
        LOG.info('%d validated candidate files; %d changed files; apply=%s', len(files), len(changes), args.apply)
        if args.commit and changes:
            git(repo, 'add', '--', *changes)
            git(repo, 'diff', '--cached', '--check')
            git(repo, 'commit', '-m', 'Sync deployed subscription rules, converter and web configuration')
            LOG.info('Committed %s', git(repo, 'rev-parse', '--short', 'HEAD'))
        if args.push:
            if not args.commit or git(repo, 'status', '--porcelain'):
                raise ValueError('Push requires --commit and a clean worktree')
            git(repo, 'push', config.get('remote', 'origin'), config['branch'])
            LOG.info('Pushed %s', config['branch'])
        return 0
    except Exception:
        LOG.exception('Snapshot stopped; inspect log/plan and keep existing commits')
        return 1
    finally:
        lock.unlink()


if __name__ == '__main__':
    raise SystemExit(main())
