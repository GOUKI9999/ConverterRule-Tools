import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import snapshot


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir=Path(__file__).parent, prefix='fixture-'))
        self.nas = self.root / 'nas'
        self.web = self.root / 'web'
        self.overlay = self.root / 'overlay'
        self.repo = self.root / 'rules-repo'
        for name in ['config', 'base', 'snippets', 'rules/GOUKI', 'rules/ACL4SSR/Clash', 'airport_proxy']:
            (self.nas / name).mkdir(parents=True)
        for parent in [self.web, self.overlay, self.repo]:
            parent.mkdir()
        for folder in ['css', 'js', 'vendor']:
            (self.web / folder).mkdir()
        (self.overlay / 'vendor').mkdir()
        for name in ['GOUKI_Local.ini', 'GOUKI_Local2.ini', 'GOUKI_Online.ini']:
            (self.nas / 'config' / name).write_text('[custom]\nadd_emoji=true\n')
        (self.nas / 'base/GOUKI_Base.yml').write_text('mixed-port: 7890\n')
        (self.nas / 'pref.toml').write_text('enable_cache = true\n')
        (self.nas / 'GOUKI_subconverter_notes.md').write_text('Notes\n')
        (self.nas / 'airport_proxy/ua_proxy.py').write_text('x = 1\n')
        (self.nas / 'airport_proxy/domains.json').write_text('{}')
        for name in ['index.html', 'favicon.ico', 'qrcode.min.js', 'LOCAL_CHANGES.md']:
            (self.web / name).write_text('local-assets')
        for name in ['apply.py', 'README.md', 'CURRENT_LOCAL_CHANGES.md']:
            (self.overlay / name).write_text('x = 1\n' if name.endswith('.py') else 'Notes\n')
        subprocess.run(['git', 'init', '-b', 'local-production', str(self.repo)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-m', 'fixture'], check=True, capture_output=True)
        source = self.nas / 'rules/ACL4SSR/Clash/Test.list'
        source.write_text('DOMAIN,example.com\n')
        self.state = self.root / 'state.json'
        self.state.write_text(json.dumps({'head': snapshot.git(self.repo, 'rev-parse', 'HEAD'), 'upstream': 'upstream-test', 'production': str(source.parent), 'files': {'Test.list': snapshot.digest(source.read_bytes())}}))
        self.config = {'converter': str(self.nas), 'subweb': str(self.web), 'overlay': str(self.overlay), 'acl_state': str(self.state), 'acl_repository': str(self.repo), 'router_script_url': 'http://example.invalid/script'}
        self.router = b'#!/bin/bash\nresult_limit_errors(){ :; }\n'

    def tearDown(self):
        # Retain diagnostic fixtures in CodeTemp, including Git object files.
        pass

    def test_sanitize(self):
        data = b'https://x/?token=private&flag=meta\nhttps://doh/dns-query/private-key\n'
        result = snapshot.sanitize(data)
        self.assertNotIn(b'private', result)
        self.assertIn(b'flag=meta', result)

    def test_pref_redacts_credentials(self):
        data = b'api_access_token = "secret"\ninsert_url = ["vless://secret@host"]\nenable_cache = true\n'
        result = snapshot.sanitize(data, pref=True)
        self.assertNotIn(b'secret', result)
        self.assertIn(b'enable_cache = true', result)

    def test_path_and_encoded_tokens(self):
        data = b'https://x/link/private123?extend=1\nhttps://x/client/0123456789abcdef0123456789abcdef\nurl=https%3A%2F%2Fx%3Ftoken%3Dprivate123%26flag%3Dmeta\n'
        result = snapshot.sanitize(data)
        self.assertNotIn(b'private123', result)
        self.assertNotIn(b'0123456789abcdef0123456789abcdef', result)
        self.assertIn(b'%26flag%3Dmeta', result)

    def test_uri_rejected(self):
        with self.assertRaises(ValueError):
            snapshot.sanitize(b'vless://private@host')

    def test_snapshot_and_idempotence(self):
        files = snapshot.collect(self.config, self.router)
        destination = self.root / 'output'
        destination.mkdir()
        (destination / 'keep').write_text('keep')
        self.assertTrue(snapshot.update(destination, files, apply=True))
        self.assertEqual(snapshot.update(destination, files, apply=True), [])
        self.assertTrue((destination / 'keep').is_file())

    def test_drift_rejected(self):
        (self.nas / 'rules/ACL4SSR/Clash/Test.list').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'drift'):
            snapshot.collect(self.config, self.router)

    def test_wrong_branch_rejected(self):
        subprocess.run(['git', '-C', str(self.repo), 'checkout', '-b', 'pr-branch'], check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, 'branch'):
            snapshot.collect(self.config, self.router)

    def test_bad_router_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Router'):
            snapshot.collect(self.config, b'<html>Error</html>')

    def test_remote_cdn_rejected(self):
        (self.web / 'index.html').write_text('unpkg.com/jquery')
        with self.assertRaisesRegex(ValueError, 'overlay'):
            snapshot.collect(self.config, self.router)


if __name__ == '__main__':
    unittest.main()
