"""Conservative Windows ACL4SSR updater. Run a copy under CodeTemp."""
import argparse
from contextlib import contextmanager
from datetime import datetime
import hashlib
import io
import json
import logging
import msvcrt
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import uuid

ROOT = Path(__file__).resolve().parent
LOG = logging.getLogger('acl4ssr-sync')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(data):
    return data.decode('utf-8-sig').replace('\r\n', '\n').encode('utf-8')


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temp, path)


def safe_path(root, name):
    rel = PurePosixPath(name)
    if not name or rel.is_absolute() or '..' in rel.parts or '\\' in name or ':' in name:
        raise RuntimeError(f'Unsafe relative path: {name}')
    path = root.joinpath(*rel.parts)
    if not path.resolve().is_relative_to(root.resolve()):
        raise RuntimeError(f'Path escapes root: {name}')
    return path


def verify_live(target, files):
    if not target.is_dir():
        raise RuntimeError(f'Production directory unavailable: {target}')
    for name, expected in files.items():
        path = safe_path(target, name)
        if not path.is_file() or digest(path.read_bytes()) != expected:
            raise RuntimeError(f'Production file changed or missing; import/review it first: {name}')


def publish(target, files, changes, run):
    if not set(changes).issubset(files):
        raise RuntimeError('Cannot publish files not registered in the deployment manifest')
    verify_live(target, files)
    run.mkdir(parents=True, exist_ok=True)
    journal = {'completed': [], 'pending': list(changes), 'failed': None}
    # Back up the complete update set before replacing any production file.
    for name in changes:
        data = safe_path(target, name).read_bytes()
        if digest(data) != files[name]:
            raise RuntimeError(f'Production file changed during backup: {name}')
        backup = safe_path(run / 'backup', name)
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_bytes(data)
        if digest(backup.read_bytes()) != files[name]:
            raise RuntimeError(f'Backup verification failed: {name}')
    save_json(run / 'publish.json', journal)
    for name, data in changes.items():
        path = safe_path(target, name)
        temp = path.with_name('.' + path.name + '.acl4ssr-' + uuid.uuid4().hex + '.tmp')
        try:
            temp.write_bytes(data)
            if temp.read_bytes() != data:
                raise RuntimeError(f'Staged file readback failed: {name}')
            if digest(path.read_bytes()) != files[name]:
                raise RuntimeError(f'Production file changed before replacement: {name}')
            os.replace(temp, path)
            if path.read_bytes() != data:
                raise RuntimeError(f'Production readback failed: {name}')
            journal['completed'].append(name)
            journal['pending'].remove(name)
            save_json(run / 'publish.json', journal)
        except Exception:
            journal['failed'] = name
            save_json(run / 'publish.json', journal)
            raise
    return {**files, **{name: digest(data) for name, data in changes.items()}}


@contextmanager
def lock():
    # Byte-range locks are released by Windows if the process exits/crashes.
    with (ROOT / 'sync.lock').open('a+b') as handle:
        if handle.tell() == 0:
            handle.write(b'0')
            handle.flush()
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError('Another sync process is already running') from exc
        try:
            yield
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def git(repo, *args):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, timeout=180)
    LOG.info('git %s -> %s', ' '.join(args), result.returncode)
    if result.stderr:
        LOG.info('%s', result.stderr.decode('utf-8', errors='replace').strip())
    if result.returncode:
        output = result.stdout.decode('utf-8', errors='replace')
        LOG.error('%s', output)
        raise RuntimeError(f'Git failed ({result.returncode}): {args[0]}; see sync.log')
    return result.stdout


def clean_branch(repo, branch):
    actual = git(repo, 'branch', '--show-current').decode().strip()
    if actual != branch:
        raise RuntimeError(f'Expected branch {branch}, got {actual}')
    if git(repo, 'status', '--porcelain'):
        raise RuntimeError('Git working tree is dirty; stop before fetch or publish')
    for marker in ('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply'):
        path = Path(git(repo, 'rev-parse', '--git-path', marker).decode().strip())
        if not path.is_absolute():
            path = repo / path
        if path.exists():
            raise RuntimeError(f'Git operation in progress: {marker}')


def tree_files(repo, tree):
    archive = git(repo, 'archive', '--format=tar', tree, 'Clash')
    result = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        for member in source.getmembers():
            if member.isfile() and member.name.startswith('Clash/'):
                name = member.name[len('Clash/'):]
                key = name.casefold()
                if key in result:
                    raise RuntimeError(f'Case-colliding upstream path: {name}')
                result[key] = source.extractfile(member).read()
    return result


def candidate_changes(target, manifest, candidate):
    changes = {}
    for name in manifest:
        data = candidate.get(name.casefold())
        if data is None:
            raise RuntimeError(f'Upstream deleted/renamed a deployed file; manual review required: {name}')
        current = safe_path(target, name).read_bytes()
        if normalized(data) == normalized(current):
            continue
        if not (name.endswith('.list') or name.startswith('Providers/') and name.endswith('.yaml')):
            raise RuntimeError(f'Configuration change needs manual review: {name}')
        changes[name] = data
    return changes


def validate(changes, core, run):
    if not changes:
        return
    import yaml
    if not core.is_file():
        raise RuntimeError(f'Mihomo validator unavailable: {core}')
    providers = {}
    inline = []
    check = run / 'validation'
    check.mkdir(parents=True, exist_ok=True)
    for index, (name, data) in enumerate(changes.items()):
        text = normalized(data).decode()
        if name.endswith('.list'):
            rules = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith('#')]
        else:
            parsed = yaml.safe_load(text)
            rules = parsed.get('payload') if isinstance(parsed, dict) else None
        if not isinstance(rules, list) or not rules or not all(isinstance(rule, str) for rule in rules):
            raise RuntimeError(f'Empty/invalid rules payload: {name}')
        for rule in rules:
            parts = rule.split(',')
            if len(parts) not in (2, 3) or (len(parts) == 3 and parts[2] != 'no-resolve'):
                raise RuntimeError(f'Rule needs manual syntax review in {name}: {rule}')
            inline.append(','.join(parts[:2] + ['DIRECT'] + parts[2:]))
        provider = f'file{index}'
        (check / f'{provider}.yaml').write_text(yaml.safe_dump({'payload': rules}), encoding='utf-8')
        providers[provider] = {'type': 'file', 'behavior': 'classical', 'path': f'./{provider}.yaml'}
    configs = {
        'inline': {'rules': inline + ['MATCH,DIRECT']},
        'providers': {'rule-providers': providers, 'rules': [f'RULE-SET,{name},DIRECT' for name in providers] + ['MATCH,DIRECT']},
    }
    for name, config in configs.items():
        path = check / f'{name}.yaml'
        path.write_text(yaml.safe_dump(config), encoding='utf-8')
        result = subprocess.run([str(core), '-t', '-d', str(check), '-f', str(path)],
                                cwd=check, capture_output=True, timeout=120)
        output = result.stdout + result.stderr
        (check / f'{name}.log').write_bytes(output)
        LOG.info('Mihomo %s: exit=%d', name, result.returncode)
        if result.returncode:
            raise RuntimeError(f'Mihomo validation failed: {check / (name + ".log")}')


def sync(config, apply):
    repo, target = Path(config['repository']), Path(config['production'])
    state_path = ROOT / 'state.json'
    state = json.loads(state_path.read_text(encoding='utf-8'))
    if state['repository'] != str(repo) or state['production'] != str(target):
        raise RuntimeError('Deployment state belongs to another repository/production directory')
    files = state['files']
    if not files:
        raise RuntimeError('Empty deployment manifest')
    clean_branch(repo, config['branch'])
    verify_live(target, files)
    remote = git(repo, 'remote', 'get-url', 'upstream').decode().strip().rstrip('/')
    if remote.removesuffix('.git') != config['upstream_url'].rstrip('/').removesuffix('.git'):
        raise RuntimeError(f'Unexpected upstream URL: {remote}')
    git(repo, 'fetch', 'upstream')
    upstream = git(repo, 'rev-parse', 'upstream/master').decode().strip()
    if state.get('upstream'):
        git(repo, 'merge-base', '--is-ancestor', state['upstream'], upstream)
    head = git(repo, 'rev-parse', 'HEAD').decode().strip()
    tree = git(repo, 'merge-tree', '--write-tree', head, upstream).decode().splitlines()[0]
    run = ROOT / 'runs' / (datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
    run.mkdir(parents=True)
    changes = candidate_changes(target, files, tree_files(repo, tree))
    plan = {'apply': apply, 'head_before': head, 'upstream': upstream, 'candidate_tree': tree,
            'changes': {name: {'before': files[name], 'after': digest(data)} for name, data in changes.items()},
            'registered_files': len(files), 'new_upstream_files': 'not deployed'}
    save_json(run / 'plan.json', plan)
    for name, data in changes.items():
        path = safe_path(run / 'candidate', name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    validate(changes, Path(config['mihomo']), run)
    LOG.info('Plan: %d changed / %d registered files; %s', len(changes), len(files), run)
    if apply:
        clean_branch(repo, config['branch'])
        if git(repo, 'rev-parse', 'HEAD').decode().strip() != head:
            raise RuntimeError('Git HEAD changed during validation')
        verify_live(target, files)
        git(repo, 'merge', '--no-edit', upstream)
        clean_branch(repo, config['branch'])
        if git(repo, 'rev-parse', 'HEAD^{tree}').decode().strip() != tree:
            raise RuntimeError('Merged tree differs from validated candidate')
        state['files'] = publish(target, files, changes, run)
        verify_live(target, state['files'])
        state.update({'upstream': upstream, 'head': git(repo, 'rev-parse', 'HEAD').decode().strip(),
                      'last_success': datetime.now().isoformat(), 'last_run': str(run)})
        save_json(state_path, state)
        LOG.info('Published and read back %d files. State saved.', len(changes))
    return plan


def record_live(config, names):
    """Accept a manual edit only after the same content has been committed."""
    repo, target = Path(config['repository']), Path(config['production'])
    state_path = ROOT / 'state.json'
    state = json.loads(state_path.read_text(encoding='utf-8'))
    if state['repository'] != str(repo) or state['production'] != str(target):
        raise RuntimeError('Deployment state belongs to another repository/production directory')
    if isinstance(names, str):
        names = [names]
    clean_branch(repo, config['branch'])
    committed = tree_files(repo, 'HEAD')
    recorded = {}
    for name in names:
        if name not in state['files']:
            raise RuntimeError('Only existing manifest files can be re-recorded')
        data = safe_path(target, name).read_bytes()
        tracked = committed.get(name.casefold())
        if tracked is None or normalized(tracked) != normalized(data):
            raise RuntimeError(f'Commit the reviewed production edit to local-production first: {name}')
        recorded[name] = {'before': state['files'][name], 'after': digest(data)}
        state['files'][name] = digest(data)
    verify_live(target, state['files'])
    save_json(state_path, state)
    LOG.info('Recorded committed production edits: %s', json.dumps(recorded))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--apply', action='store_true', help='Merge local branch and publish the validated update')
    actions.add_argument('--record-live', nargs='+', metavar='RELATIVE_PATH', help='Record production edits already committed to Git')
    args = parser.parse_args()
    # Logs and state may never be created alongside formal Git source code.
    if not ROOT.is_relative_to(Path('D:/Temp/CodeTemp').resolve()):
        parser.error('Copy this tool to D:/Temp/CodeTemp/<task>/runtime before running it')
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                        handlers=[logging.FileHandler(ROOT / 'sync.log', encoding='utf-8'), logging.StreamHandler()])
    try:
        with lock():
            config = json.loads((ROOT / 'config.json').read_text(encoding='utf-8'))
            if args.record_live:
                record_live(config, args.record_live)
            else:
                sync(config, args.apply)
    except Exception:
        LOG.exception('STOPPED: production may need inspection; see the latest run and backups')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
