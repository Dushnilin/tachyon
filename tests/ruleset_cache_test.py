"""Exercise the real ucode reader against committed and obsolete bbolt pages."""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading


def leaf(entries):
    page = bytearray(struct.pack('<QHHI', 0, 2, len(entries), 0))
    values = bytearray()
    for flags, key, value in entries:
        pos = 16 + len(entries) * 16 + len(values) - len(page)
        page.extend(struct.pack('<IIII', flags, pos, len(key), len(value)))
        values.extend(key + value)
    return page + values


def record(payload, version=2):
    size = len(payload)
    varint = bytearray()
    while size >= 128:
        varint.append((size & 127) | 128)
        size >>= 7
    varint.append(size)
    return bytes([version]) + varint + payload + bytes(8)


class CacheTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / 'cache.db'
        self.config = self.root / 'config.json'
        self.url = 'https://example.test/zapret.srs?rev=2'
        self.payload = b'SRS\x02' + b'current-list' * 500
        self.settings = {
            'route': {'rule_set': [{'type': 'remote', 'tag': 'custom-r2-ruleset',
                                    'url': self.url, 'format': 'binary'}]},
            'experimental': {'cache_file': {'enabled': True, 'path': str(self.db)}}}

    def database(self, *, page_size=4096, inline=False, branch=False, corrupt=False):
        pages = {}
        def store(number, data):
            pages[number] = bytes(data)
        def bucket(root):
            return struct.pack('<QQ', root, 0)
        # A stale duplicate occurs first in the physical file, outside the live tree.
        store(2, leaf([(1, b'rule_set', bucket(3))]))
        store(3, leaf([(0, b'custom-r2-ruleset', record(b'SRS\x02old-list'))]))
        live = leaf([(0, b'custom-r2-ruleset', record(self.payload))])
        store(5, live)
        rules_bucket = bucket(0) + live if inline else bucket(5)
        if branch:
            branch_page = bytearray(struct.pack('<QHHI', 20, 1, 1, 0))
            branch_page.extend(struct.pack('<IIQ', 16, 0, 5))
            store(20, branch_page)
            rules_bucket = bucket(20)
        store(4, leaf([(1, b'rule_set', rules_bucket)]))
        highest = max(n + (len(data) + page_size - 1) // page_size for n, data in pages.items())
        data = bytearray(highest * page_size)
        for n, body in pages.items():
            page = bytearray(body)
            struct.pack_into('<Q', page, 0, n)
            struct.pack_into('<I', page, 12, (len(page) - 1) // page_size)
            data[n * page_size:n * page_size + len(page)] = page
        for n, root, txid in [(0, 2, 10), (1, 4, 11)]:
            meta = struct.pack('<IIIIQQQQQ', 0xed0cdaed, 2, page_size, 0,
                               root, 0, 0, highest, txid)
            checksum = 0xcbf29ce484222325
            for byte in meta:
                checksum = ((checksum ^ byte) * 0x100000001b3) & ((1 << 64) - 1)
            if corrupt and n == 1:
                checksum ^= 1
            header = struct.pack('<QHHI', n, 4, 0, 0)
            data[n * page_size:n * page_size + 80] = header + meta + struct.pack('<Q', checksum)
        self.db.write_bytes(data)

    def extract(self, reference=None, success=True):
        self.config.write_text(json.dumps(self.settings))
        env = dict(os.environ, TACHYON_SINGBOX_CONFIG=str(self.config),
                   TMP_RULESET_FOLDER=str(self.root / 'snapshots'))
        library = Path(__file__).resolve().parents[1] / 'tachyon/files/usr/lib'
        result = subprocess.run(['ucode', '-L', str(library), '-e',
            'let c=require("diagnostics.ruleset_cache"); print(c.extract(ARGV[0]));',
            reference or self.url], env=env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return Path(result.stdout).read_bytes()
        self.assertNotEqual(result.returncode, 0)
        return result.stderr

    def test_live_tree_ignores_obsolete_duplicate_and_uses_configured_path(self):
        self.database()
        self.assertEqual(self.extract(), self.payload)

    def test_branch_and_overflow_pages(self):
        self.database(branch=True, page_size=1024)
        self.assertEqual(self.extract(), self.payload)

    def test_inline_bucket_and_source_json(self):
        self.payload = b'{"version":2,"rules":[{"domain_suffix":["r2.cloudflarestorage.com"]}]}'
        self.settings['route']['rule_set'][0]['format'] = 'source'
        self.database(inline=True)
        self.assertEqual(self.extract(), self.payload)

    def test_bad_metadata_checksum_uses_previous_committed_transaction(self):
        self.database(corrupt=True)
        self.assertEqual(self.extract(), b'SRS\x02old-list')

    def test_tag_lookup_and_changed_snapshot(self):
        self.database()
        self.assertEqual(self.extract('custom-r2-ruleset'), self.payload)
        self.payload = b'SRS\x02updated'
        self.database()
        self.assertEqual(self.extract(), self.payload)

    def test_unconfigured_reference_and_path_traversal_are_rejected(self):
        self.database()
        for reference in ['https://attacker.test/list.srs', '../../config/tachyon']:
            self.assertIn('not in the generated', self.extract(reference, success=False))

    def test_truncated_payload_is_rejected(self):
        self.database()
        data = self.db.read_bytes()
        self.db.write_bytes(data.replace(record(self.payload), b'\x02\xff\xff\xff\xff\x7f' + bytes(len(record(self.payload)) - 6)))
        self.assertIn('invalid cached rule-set payload', self.extract(success=False))

    def test_missing_cache_and_disabled_cache_fail(self):
        self.assertIn('unavailable', self.extract(success=False))
        self.settings['experimental']['cache_file']['enabled'] = False
        self.assertIn('disabled', self.extract(success=False))

    def test_configured_local_file_is_returned_without_network_or_database(self):
        local = self.root / 'local.trs'
        local.write_bytes(b'TRS-local')
        self.settings['route']['rule_set'] = [{'type': 'local', 'tag': 'local', 'path': str(local)}]
        self.assertEqual(self.extract(str(local)), b'TRS-local')

    def provider(self, modified='Sat, 31 Oct 2026 11:41:41 GMT', fail=False):
        payload = b'SRS\x02latest-remote'
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                if self.path.startswith('/providers/'):
                    if self.headers.get('Authorization') != 'Bearer test-secret':
                        self.send_error(401)
                        return
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"updatedAt":"2026-10-31T11:42:32.455Z"}')
                elif fail:
                    self.send_error(503)
                else:
                    self.send_response(200)
                    if modified:
                        self.send_header('Last-Modified', modified)
                    self.end_headers()
                    self.wfile.write(payload)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        address = f'127.0.0.1:{server.server_port}'
        self.settings['experimental']['clash_api'] = {'external_controller': address, 'secret': 'test-secret'}
        self.settings['route']['rule_set'][0]['url'] = f'http://{address}/zapret.srs'
        self.url = self.settings['route']['rule_set'][0]['url']
        return payload

    def test_stale_native_disk_cache_uses_explicit_current_source_fallback(self):
        self.database()
        payload = self.provider()
        self.assertEqual(self.extract(), payload)

    def test_missing_native_cache_can_use_current_source(self):
        payload = self.provider(modified=None)
        self.assertEqual(self.extract(), payload)

    def test_remote_publication_newer_than_loaded_provider_requires_update(self):
        self.database()
        self.provider(modified='Sat, 31 Oct 2026 11:43:00 GMT')
        self.assertIn('newer than the loaded', self.extract(success=False))

    def test_download_failure_does_not_use_stale_cache(self):
        self.database()
        self.provider(fail=True)
        self.assertIn('could not be read', self.extract(success=False))


if __name__ == '__main__':
    unittest.main()
