// Synthetic subscriptions only. Node's crypto provides an independent encoder
// for the Happ framing, RSA PKCS#1 v1.5 and authenticated ChaCha20-Poly1305.
const fs = require('fs');
const crypto = require('crypto');
const keys = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const out = process.argv[3];
const pairs = value => value.replace(/(.)(.)/gs, '$2$1');
const halves = value => value.replace(/(.)(.)(.)(.)/gs, '$3$4$1$2');
const pem = (key, kind = 'PRIVATE KEY') =>
  `-----BEGIN ${kind}-----\n${key.match(/.{1,64}/g).join('\n')}\n-----END ${kind}-----`;
const rsa = (key, value, kind) => crypto.publicEncrypt({
  key: crypto.createPublicKey(pem(key, kind)), padding: crypto.constants.RSA_PKCS1_PADDING,
}, value);
function legacy(mode, text) {
  const size = mode === 'crypt' ? 117 : 501;
  const data = Buffer.from(text);
  const parts = [];
  for (let i = 0; i < data.length; i += size)
    parts.push(rsa(keys[mode], data.subarray(i, i + size), 'RSA PRIVATE KEY'));
  return `happ://${mode}/${Buffer.concat(parts).toString('base64')}`;
}
function crypt5(text, salt = null, options = {}) {
  const marker = options.marker || Object.keys(keys.crypt5)[0];
  const key = crypto.randomBytes(32);
  const nonce = Buffer.from('0123456789ab');
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  const encoded = pairs(Buffer.from(text).toString('base64'));
  const data = Buffer.concat([cipher.update(encoded), cipher.final(), cipher.getAuthTag()]);
  if (options.tamper) data[data.length - 1] ^= 1;
  const value = Buffer.from(key);
  if (salt) for (let i = 0; i < value.length; i++) value[i] ^= salt[i % 8];
  const rsaPart = rsa(keys.crypt5[marker], Buffer.from(pairs(value.toString('base64'))));
  const packed = data.toString('base64');
  const header = salt ? options.saltTag + salt.toString('latin1') : '';
  return 'happ://crypt5/' + halves(marker.slice(0, 4) + nonce.toString('latin1') + header +
    packed.length + ':' + packed + rsaPart.toString('base64') + marker.slice(4));
}
const expected = 'https://subscription.example/test?token=synthetic';
const inline = 'vless://00000000-0000-4000-8000-000000000001@example.com:443?encryption=none&security=tls#Synthetic';
const valid = ['crypt', 'crypt2', 'crypt3', 'crypt4'].map(mode => ({
  name: mode, link: legacy(mode, expected), expected,
}));
valid.push({ name: 'rsa-multiple-blocks', link: legacy('crypt4', expected + '&pad=' + 'x'.repeat(1000)), expected: expected + '&pad=' + 'x'.repeat(1000) });
valid.push({ name: 'crypt5-legacy', link: crypt5(expected), expected });
valid.push({ name: 'crypt5-salted', link: crypt5(expected, Buffer.from('salt1234'), { saltTag: 'XY' }), expected });
valid.push({ name: 'crypt5-salted-digit-tag', link: crypt5(expected, Buffer.from('salt1234'), { saltTag: '12' }), expected });
valid.push({ name: 'inline', link: crypt5(inline), expected: inline });
const urlSafe = legacy('crypt4', expected).replace('happ://crypt4/', '').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
valid.push({ name: 'upper-url-safe', link: 'HAPP://CRYPT4/' + urlSafe, expected });
for (const marker of Object.keys(keys.crypt5))
  valid.push({ name: 'marker-' + marker, link: crypt5(expected, null, { marker }), expected });
const invalid = [crypt5(expected, null, { tamper: true }),
  crypt5(expected, Buffer.from('salt1234'), { saltTag: '12', tamper: true }), crypt5(expected).slice(0, -10),
  'happ://crypt5/' + halves('xxxxxxxx' + '0'.repeat(900)), 'happ://crypt5/x',
  'happ://crypt6/test', 'happ://crypt4/invalid_!@#$', 'happ://crypt5/' + 'x'.repeat(65536)];
fs.writeFileSync(out, JSON.stringify({ valid, invalid }));
