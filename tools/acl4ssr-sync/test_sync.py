"""Run from a copy under CodeTemp; all fixtures stay next to this script."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sync', Path(__file__).with_name('sync.py'))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class RealPathTests(unittest.TestCase):
    BS = chr(92)

    def test_normalize_extended_forms(self):
        bs = self.BS
        plain = bs * 2 + 'srv' + bs + 'share' + bs + 'Clash'
        self.assertEqual(sync.normalize_extended(bs * 2 + '?' + bs + 'UNC' + bs + 'srv' + bs + 'share' + bs + 'Clash'), plain)
        self.assertEqual(sync.normalize_extended(bs * 2 + '?' + bs + 'D:' + bs + 'x'), 'D:' + bs + 'x')
        self.assertEqual(sync.normalize_extended(plain), plain)

    def test_safe_path_accepts_mixed_resolve_spellings(self):
        # Root resolves to the UNC-extended spelling while the file resolves to the plain one.
        bs = self.BS
        plain = bs * 2 + 'srv' + bs + 'share' + bs + 'Clash'
        extended = bs * 2 + '?' + bs + 'UNC' + bs + 'srv' + bs + 'share' + bs + 'Clash'
        root = Path(plain)

        def fake_resolve(self, strict=False):
            return Path(extended) if str(self) == plain else self

        with patch.object(Path, 'resolve', fake_resolve):
            self.assertEqual(sync.safe_path(root, 'Ruleset/Apple.list'), root / 'Ruleset' / 'Apple.list')
            with self.assertRaises(RuntimeError):
                sync.safe_path(root, '../x.list')


class PublishTests(unittest.TestCase):
    def setUp(self):
        # Keep fixtures for inspection; never use system Temp.
        self.root = Path(tempfile.mkdtemp(prefix='fixture-', dir=Path(__file__).parent))
        self.live = self.root / 'Clash'
        self.live.mkdir()
        self.file = self.live / 'Example.list'
        self.file.write_bytes(b'DOMAIN-SUFFIX,old.example\r\n')
        self.files = {'Example.list': sync.digest(self.file.read_bytes())}
        self.new = {'Example.list': b'DOMAIN-SUFFIX,new.example\n'}

    def test_normalization_preserves_existing_bytes(self):
        self.assertEqual(sync.normalized(self.file.read_bytes()), b'DOMAIN-SUFFIX,old.example\n')

    def test_external_change_stops_before_writes(self):
        self.file.write_bytes(b'personal change')
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            sync.publish(self.live, self.files, self.new, self.root / 'run')
        self.assertEqual(self.file.read_bytes(), b'personal change')

    def test_missing_drive_stops(self):
        with self.assertRaises(RuntimeError):
            sync.verify_live(self.root / 'unavailable', self.files)

    def test_backup_and_readback(self):
        run = self.root / 'run'
        sync.publish(self.live, self.files, self.new, run)
        self.assertEqual(self.file.read_bytes(), self.new['Example.list'])
        self.assertEqual((run / 'backup/Example.list').read_bytes(), b'DOMAIN-SUFFIX,old.example\r\n')
        self.assertEqual(json.loads((run / 'publish.json').read_text())['completed'], ['Example.list'])

    def test_unregistered_file_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'registered'):
            sync.publish(self.live, self.files, {'New.list': b'new'}, self.root / 'run')
        self.assertFalse((self.live / 'New.list').exists())

    def test_write_failure_keeps_original(self):
        with patch.object(sync.os, 'replace', side_effect=OSError('simulated network failure')):
            with self.assertRaises(OSError):
                sync.publish(self.live, self.files, self.new, self.root / 'run')
        self.assertEqual(sync.digest(self.file.read_bytes()), self.files['Example.list'])

    def test_path_escape_rejected(self):
        for name in ['../GOUKI/a.list', '/absolute.list', 'C:/a.list', 'sub\\..\\a.list']:
            with self.assertRaises(RuntimeError):
                sync.safe_path(self.live, name)


class GitIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='git-fixture-', dir=Path(__file__).parent))
        self.remote = self.root / 'upstream'
        self.repo = self.root / 'local'
        self.live = self.root / 'production/Clash'
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir()
        self.live.mkdir(parents=True)
        self.remote.mkdir()
        self.repo.mkdir()
        for repo in (self.remote, self.repo):
            self.git(repo, 'init', '-b', 'master')
            self.git(repo, 'config', 'user.name', 'Fixture')
            self.git(repo, 'config', 'user.email', 'fixture@example.invalid')
            self.git(repo, 'config', 'commit.gpgsign', 'false')
        (self.remote / 'Clash').mkdir()
        for name in ('Update.list', 'Keep.list'):
            (self.remote / 'Clash' / name).write_bytes(b'DOMAIN-SUFFIX,old.example\n')
            (self.live / name).write_bytes(b'DOMAIN-SUFFIX,old.example\n')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, 'commit', '-m', 'base')
        base = self.git(self.remote, 'rev-parse', 'HEAD')
        self.git(self.repo, 'remote', 'add', 'upstream', str(self.remote))
        self.git(self.repo, 'fetch', 'upstream')
        self.git(self.repo, 'checkout', '-b', 'local-production', 'upstream/master')
        custom = b'DOMAIN-SUFFIX,personal.example\n'
        (self.repo / 'Clash/Keep.list').write_bytes(custom)
        (self.live / 'Keep.list').write_bytes(custom)
        self.git(self.repo, 'add', '.')
        self.git(self.repo, 'commit', '-m', 'local override')
        (self.remote / 'Clash/Update.list').write_bytes(b'DOMAIN-SUFFIX,new.example\n')
        (self.remote / 'Clash/New.list').write_bytes(b'DOMAIN-SUFFIX,newfile.example\n')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, 'commit', '-m', 'upstream update')
        self.config = {'repository': str(self.repo), 'production': str(self.live),
                       'branch': 'local-production', 'upstream_url': str(self.remote), 'mihomo': 'unused'}
        sync.save_json(self.runtime / 'state.json', {**self.config, 'upstream': base,
                       'files': {p.name: sync.digest(p.read_bytes()) for p in self.live.iterdir()}})
        self.root_patch = patch.object(sync, 'ROOT', self.runtime)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.validate_patch = patch.object(sync, 'validate')
        self.validate_patch.start()
        self.addCleanup(self.validate_patch.stop)

    def git(self, repo, *args):
        result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        return result.stdout.decode().strip()

    def test_preview_apply_and_second_run(self):
        before = self.git(self.repo, 'rev-parse', 'HEAD')
        plan = sync.sync(self.config, False)
        self.assertEqual(list(plan['changes']), ['Update.list'])
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), before)
        self.assertIn(b'old.example', (self.live / 'Update.list').read_bytes())
        sync.sync(self.config, True)
        self.assertIn(b'new.example', (self.live / 'Update.list').read_bytes())
        self.assertIn(b'personal.example', (self.live / 'Keep.list').read_bytes())
        self.assertFalse((self.live / 'New.list').exists())
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        self.assertEqual(sync.sync(self.config, True)['changes'], {})
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)

    def test_dirty_worktree_stops(self):
        (self.repo / 'Clash/Keep.list').write_bytes(b'uncommitted')
        with self.assertRaisesRegex(RuntimeError, 'dirty'):
            sync.sync(self.config, True)
        self.assertIn(b'old.example', (self.live / 'Update.list').read_bytes())

    def test_record_live_requires_matching_commit(self):
        data = b'DOMAIN-SUFFIX,manual.example\n'
        for name in ('Keep.list', 'Update.list'):
            (self.live / name).write_bytes(data)
        with self.assertRaisesRegex(RuntimeError, 'Commit'):
            sync.record_live(self.config, 'Keep.list')
        for name in ('Keep.list', 'Update.list'):
            (self.repo / 'Clash' / name).write_bytes(data)
        self.git(self.repo, 'add', '.')
        self.git(self.repo, 'commit', '-m', 'manual production edit')
        sync.record_live(self.config, ['Keep.list', 'Update.list'])
        state = json.loads((self.runtime / 'state.json').read_text())
        self.assertEqual(state['files']['Keep.list'], sync.digest(data))
        self.assertEqual(state['files']['Update.list'], sync.digest(data))

    def test_conflict_does_not_touch_worktree_or_production(self):
        (self.remote / 'Clash/Keep.list').write_bytes(b'DOMAIN-SUFFIX,upstream.example\n')
        self.git(self.remote, 'add', '.')
        self.git(self.remote, 'commit', '-m', 'conflicting update')
        before = self.git(self.repo, 'rev-parse', 'HEAD')
        with self.assertRaisesRegex(RuntimeError, 'Git failed'):
            sync.sync(self.config, True)
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), before)
        self.assertEqual(self.git(self.repo, 'status', '--porcelain'), '')
        self.assertIn(b'old.example', (self.live / 'Update.list').read_bytes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
