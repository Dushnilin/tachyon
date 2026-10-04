// Run on the patched router: ucode -L /usr/lib/tachyon test-tachyon-awg-manual.uc
// Synthetic keys and documentation addresses only; no UCI writes or network traffic.
let generator = require('singbox.generator_outbounds');
let wireguard = require('subscription.wireguard');
generator.init({runtime_generate_unsupported: message => assert(false, message)});
function check(ok, label) {
    if (!ok) { warn('FAIL: ', label, '\n'); exit(1); }
}
let bytes = ''; for (let i = 1; i <= 32; i++) bytes += chr(i);
let key = b64enc(bytes);
let conf = '[Interface]\nPrivateKey = ' + key + '\nAddress = 10.77.0.2/32\n' +
    '[Peer]\nPublicKey = ' + key + '\nEndpoint = [2001:db8::1]:51820\nPersistentKeepalive = 25\n';
let vpn = 'vpn://' + replace(replace(replace(b64enc(conf), /\+/g, '-'), /\//g, '_'), /=+$/, '');
if (ARGV[0] == '--reject-non-lx') {
    let failed = false;
    try { generator.manual_link_outbound(vpn, 'invalid'); } catch (e) { failed = true; }
    check(failed, 'vpn:// rejected without LX even for a plain WG payload');
    print('PASS: vpn:// requires LX\n'); exit(0);
}
for (let link in [vpn]) {
    let endpoint = generator.manual_link_outbound(link, 'manual-test');
    check(endpoint.type == 'wireguard' && endpoint.tag == 'manual-test', 'endpoint type and generated tag');
    check(endpoint.private_key == key && endpoint.peers[0].public_key == key, 'keys preserved');
    check(endpoint.peers[0].address == '2001:db8::1' && endpoint.peers[0].port == 51820, 'IPv6 peer preserved');
    check(endpoint.share_link == null && !wireguard.has_awg(endpoint), 'core endpoint without share link metadata');
}
let awg_conf = replace(conf, '[Peer]', 'Jc = 4\nH1 = 100-200\nRandomTrailers = on\nDisableCookies = on\n[Peer]');
let awg_vpn = 'vpn://' + replace(replace(replace(b64enc(awg_conf), /\+/g, '-'), /\//g, '_'), /=+$/, '');
let awg = generator.manual_link_outbound(awg_vpn, 'manual-awg');
check(wireguard.has_awg(awg) && awg.h1 == '100-200' && awg.random_trailers === true && awg.disable_cookies === true,
    'AWG ranges and flags preserved');
for (let link in ['vpn://invalid!', 'vpn://e30', 'wg://removed', 'wireguard://removed', 'awg://removed']) {
    let failed = false;
    try { generator.manual_link_outbound(link, 'invalid'); } catch (e) { failed = true; }
    check(failed, 'malformed manual link rejected');
}
print('PASS: manual vpn://, removed URI schemes, IPv6, tags, keys, AWG flags/ranges and malformed inputs\n');
