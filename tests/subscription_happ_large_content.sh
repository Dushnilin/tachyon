#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

# Synthetic AES/HWID subscription bodies larger than the RSA link limit.
node - "$WORK_DIR" <<'JS'
const fs = require('fs');
const crypto = require('crypto');
const dir = process.argv[2];
const body = Array.from({ length: 600 }, (_, i) =>
  `vless://00000000-0000-4000-8000-000000000001@node${i}.example.com:443?encryption=none&security=tls#Node${i}`
).join('\n');
fs.writeFileSync(`${dir}/plain`, body);
for (const [name, secret] of [['default', 'HappDefaultSalt'], ['hwid', 'test-large-body-hwid']]) {
  const iv = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex');
  const key = crypto.createHash('sha256').update(secret).digest();
  const cipher = crypto.createCipheriv('aes-256-cbc', key, iv);
  const payload = Buffer.concat([iv, cipher.update(body), cipher.final()]);
  const encrypted = `happ://crypt4/${payload.toString('base64')}`;
  if (encrypted.length <= 65536) throw new Error('fixture must exceed 64 KiB');
  fs.writeFileSync(`${dir}/${name}`, encrypted);
}
JS

cat >"$WORK_DIR/decrypt.uc" <<'UCODE'
let fs = require("fs");
let happ = require("subscription.happ");
let dir = ARGV[0];
let expected = fs.readfile(dir + "/plain");
if (happ.decrypt(fs.readfile(dir + "/default"), "HappDefaultSalt") != expected)
    die("large default-salt body was rejected\n");
if (happ.decrypt(fs.readfile(dir + "/hwid"), "test-large-body-hwid") != expected)
    die("large HWID body was rejected\n");
// The RSA-only formats must retain their size bound.
let oversized = "happ://crypt5/";
while (length(oversized) <= 65536)
    oversized += "A";
if (happ.decrypt(oversized) != null)
    die("oversized crypt5 input was accepted\n");
UCODE
ucode -L "$TACHYON_LIB" "$WORK_DIR/decrypt.uc" "$WORK_DIR"

cat >"$WORK_DIR/normalize.uc" <<'UCODE'
let fs = require("fs");
let parser = require("subscription.parser");
if (!parser.normalize_content_validated(ARGV[0], ARGV[1]))
    die("large encrypted body failed normalization\n");
let normalized = json(fs.readfile(ARGV[1]));
if (length(normalized.outbounds) != 600)
    die("normalization lost subscription nodes\n");
UCODE
ucode -L "$TACHYON_LIB" "$WORK_DIR/normalize.uc" "$WORK_DIR/default" "$WORK_DIR/normalized.json"

# Mock only HTTP transport: exercise real cache decryption with a custom HWID.
mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
set -e
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    shift
    cp "$HAPP_LARGE_BODY" "$1"
  fi
  shift
done
printf '200'
SH
chmod +x "$WORK_DIR/bin/curl"
export HAPP_LARGE_BODY="$WORK_DIR/hwid"
PATH="$WORK_DIR/bin:$PATH" ucode -L "$TACHYON_LIB" "$TACHYON_LIB/subscription/cache.uc" \
  download-subscription 'https://subscription.example/large' "$WORK_DIR/download" "" "" 'Happ-test' 'test-large-body-hwid'
cmp "$WORK_DIR/plain" "$WORK_DIR/download" || fail 'cache did not decrypt the large HTTP body'

printf 'Large Happ AES/HWID content checks passed\n'
