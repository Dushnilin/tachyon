// Run on the router: ucode -L /usr/lib/tachyon test-tachyon-awg-subscription.uc
// Fixtures contain only synthetic keys and documentation IP addresses.
let wg = require('subscription.wireguard');
function check(ok, label) {
    if (!ok) { warn('FAIL: ', label, '\n'); exit(1); }
}
let bytes = '';
for (let i = 1; i <= 32; i++) bytes += chr(i);
let key = b64enc(bytes);
let conf = '[Interface]\nPrivateKey = ' + key + '\nAddress = 10.10.0.2/32, fd00::2/128\n' +
    'MTU = 1280\nJc = 4\nJmin = 40\nJmax = 70\nS1 = 20\nS2 = 20\nS3 = 20\nS4 = 20\n' +
    'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nI1 = <b 0x010203>\n' +
    'HeaderProtectionKey = ' + key + '\nContentPaddingAddition = 10-30\n' +
    'RekeyAfterTime = 120-150\nRekeyTimeout = 5-7\nRejectAfterTime = 180-200\n' +
    'KeepaliveTimeout = 10-12\nMaxHandshakeAttempts = 18-20\nRandomTrailers = on\nDisableCookies = on\n' +
    '\n# sample-awg\n[Peer]\nPublicKey = ' + key + '\nPresharedKey = ' + key +
    '\nEndpoint = [2001:db8::1]:51820\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25-35\n';
let raw = 'vpn://' + replace(replace(replace(b64enc(conf), /\+/g, '-'), /\//g, '_'), /=+$/, '');
let imported = wg.from_vpn(raw);
check(imported != null && wg.has_awg(imported), '3x-ui unpadded base64url AWG import');
check(imported.tag == 'sample-awg' && imported.peers[0].address == '2001:db8::1', 'name and IPv6 endpoint');
check(imported.private_key == key && imported.header_protection_key == key &&
    imported.peers[0].pre_shared_key == key, 'all keys retained');
for (let field in ['content_padding_addition','rekey_after_time','rekey_timeout',
    'reject_after_time','keepalive_timeout','max_handshake_attempts'])
    check(type(imported[field]) == 'string', 'AWG range retained: ' + field);
check(imported.random_trailers === true && imported.disable_cookies === true, 'AWG 3.1 flags');
let plain = wg.from_conf('[Interface]\nPrivateKey = ' + key + '\nAddress = 10.10.0.2/32\n' +
    '[Peer]\nPublicKey = ' + key + '\nEndpoint = 192.0.2.1:51820\nPersistentKeepalive = 25\n', '', 'WG');
check(plain != null && !wg.has_awg(plain) && plain.peers[0].persistent_keepalive_interval == 25, 'plain WG .conf');
check(wg.from_uri == null, 'additional WG/AWG URI importer removed');
check(wg.from_vpn('vpn://invalid!') == null, 'bad base64 rejected');
check(wg.from_conf(replace(conf, '120-150', '150-120'), '', '') == null, 'inverted range rejected');
check(wg.from_conf(replace(conf, '120-150', '4294967296'), '', '') == null, 'overflow rejected');
check(wg.from_conf(conf + '\n[Peer]\nPublicKey = ' + key, '', '') == null, 'multiple peers rejected');
check(wg.from_conf(replace(conf, key, 'bad-key'), '', '') == null, 'invalid keys rejected');
check(wg.from_conf(conf + '\nPostUp = arbitrary command\n', '', '').postup == null, 'INI hooks ignored');
print('PASS: AWG 3.1 vpn://, plain .conf, IPv6, ranges, flags, keys, malformed inputs and INI hooks\n');
