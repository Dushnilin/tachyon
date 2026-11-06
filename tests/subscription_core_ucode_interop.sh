#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

set -eo pipefail

ucode() {
  command ucode -L "$TACHYON_LIB" "$@"
}

PARSER="$ROOT_DIR/tachyon/files/usr/lib/subscription/parser.uc"
CORE_BIN="${TACHYON_CORE_BIN:-/usr/bin/tachyon-core}"
HAS_CORE=0
if [ -x "$CORE_BIN" ] && "$CORE_BIN" subscription hwid >/dev/null 2>&1; then
  HAS_CORE=1
fi

# ---------------------------------------------------------------------------
# 1. Multi-protocol 38-node URI bundle (raw, Base64, URL-safe Base64, Gzip)
# ---------------------------------------------------------------------------
WG_PRIV="YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="
WG_PUB="YmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmI="
WG_PSK="Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2M="
REALITY_PUB="0123456789abcdef0123456789abcdef0123456789a"
# Valid 1184-byte (1579-char base64url) ML-KEM-768 encapsulation key
MLKEM768_EK="$(node -e 'const b = Buffer.alloc(1184); for (let i = 0; i < 1184; i++) b[i] = i % 251; console.log(b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""));')"
VMESS_B64="$(printf '%s' '{"v":"2","ps":"vmess-ws-node","add":"vmess.example.com","port":"443","id":"22222222-2222-2222-2222-222222222222","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.vmess.example.com","path":"/vmess-ws","tls":"tls","sni":"cdn.vmess.example.com","alpn":"h2,http/1.1","fp":"firefox"}' | base64 | tr -d '\r\n')"
SS_LEGACY_B64="$(printf '%s' 'chacha20-ietf-poly1305:secret-pass@ss-legacy.example.com:8388' | base64 | tr -d '\r\n')"
SS2022_USER_B64="$(printf '%s' '2022-blake3-aes-128-gcm:MTIzNDU2Nzg5MDEyMzQ1Ng==' | base64 | tr -d '\r\n')"

cat >"$WORK_DIR/bundle_raw.txt" <<EOF
#profile-title: base64:$(printf '%s' 'Tachyon Full Interop' | base64 | tr -d '\r\n')
#profile-update-interval: 12
#subscription-userinfo: upload=1073741824; download=5368709120; total=107374182400; expire=1893456000
#support-url: https://t.me/tachyon_support
#profile-web-page-url: https://panel.example.com
vless://11111111-1111-1111-1111-111111111111@vless-reality.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUB}&sid=01020304&pq=true&type=tcp#vless-reality-pq-vision
vless://11111111-1111-1111-1111-111111111111@vless-pq-x25519.example.com:8443?encryption=mlkem768x25519plus.native.0rtt.${REALITY_PUB}&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=${REALITY_PUB}&sid=aabb#vless-pq-x25519-vision
vless://11111111-1111-1111-1111-111111111111@vless-pq-mlkem.example.com:8443?encryption=mlkem768x25519plus.native.0rtt.${MLKEM768_EK}&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=${REALITY_PUB}&sid=ccdd&support_x25519mlkem768=true#vless-pq-mlkem768-vision
vless://11111111-1111-1111-1111-111111111111@vless-pq-dual.example.com:8443?encryption=mlkem768x25519plus.xorpub.1rtt.100-111-1111.75-0-111.50-0-3333.${REALITY_PUB}.${MLKEM768_EK}&security=tls&sni=vless-pq-dual.example.com&fp=chrome&type=tcp#vless-pq-dual-padded
vless://11111111-1111-1111-1111-111111111111@vless-pq-xhttp.example.com:443?encryption=mlkem768x25519plus.random.0rtt.${MLKEM768_EK}&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=${REALITY_PUB}&sid=eeff&pq=1&type=xhttp&path=%2Fpq-xhttp&host=www.cloudflare.com&mode=packet-up#vless-pq-xhttp-reality
vless://11111111-1111-1111-1111-111111111111@vless-xhttp.example.com:443?security=tls&sni=vless-xhttp.example.com&alpn=h2,http/1.1&type=xhttp&path=%2Fxhttp&host=vless-xhttp.example.com&mode=stream-up#vless-xhttp-tls
vless://11111111-1111-1111-1111-111111111111@vless-ws.example.com:443?security=tls&sni=vless-ws.example.com&type=ws&path=%2Fws%3Fed%3D2048&host=cdn.example.com#vless-ws-ed
vless://11111111-1111-1111-1111-111111111111@vless-grpc.example.com:443?security=tls&sni=vless-grpc.example.com&type=grpc&serviceName=gunService#vless-grpc-node
vless://11111111-1111-1111-1111-111111111111@vless-hu.example.com:443?security=tls&sni=vless-hu.example.com&type=httpupgrade&path=%2Fup&host=vless-hu.example.com#vless-httpupgrade
vmess://${VMESS_B64}
vmess://22222222-2222-2222-2222-222222222222@vmess-url.example.com:443?type=grpc&security=tls&sni=vmess-url.example.com&serviceName=vmessGrpc#vmess-url-grpc
trojan://trojan-pass@trojan.example.com:443?security=tls&sni=trojan.example.com&alpn=h2,http/1.1&type=tcp#trojan-tcp
trojan://trojan-pq@trojan-reality.example.com:443?security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUB}&sid=11223344&pq=true&type=tcp#trojan-reality-pq
trojan-go://trojango-pass@trojango.example.com:443?sni=trojango.example.com&type=ws&host=trojango.example.com&path=%2Ftg#trojan-go-ws
ss://${SS2022_USER_B64}@ss2022.example.com:8388?uot=1#ss2022-uot
ss://${SS_LEGACY_B64}#ss-legacy
hysteria2://hy2-secret@hy2.example.com:443?sni=hy2.example.com&obfs=salamander&obfs-password=sal-pass&mport=20000-30000&mportHopInterval=25&upmbps=100&downmbps=300#hy2-salamander-hop
hysteria2://hy2-gecko@hy2-gecko.example.com:443?sni=hy2-gecko.example.com&obfs=gecko&obfs-password=gecko-pass&packetSize=200-1200#hy2-gecko-node
hy2://hy2-plain@hy2-plain.example.com:8443?sni=hy2-plain.example.com&insecure=1#hy2-plain
hysteria://hy1.example.com:4433?auth=hy1-secret&upmbps=50&downmbps=100&obfs=xplus&obfsParam=xp-key&alpn=h3&peer=hy1.example.com&insecure=1#hysteria1-node
tuic://33333333-3333-3333-3333-333333333333:tuic-pass@tuic.example.com:443?sni=tuic.example.com&alpn=h3&congestion_control=bbr&udp_relay_mode=native#tuic-v5-bbr
tuic5://33333333-3333-3333-3333-333333333333:tuic5-pass@tuic5.example.com:8443?sni=tuic5.example.com&alpn=h3&congestion_control=cubic&udp_relay_mode=quic&zero_rtt_handshake=1#tuic5-cubic
anytls://anytls-secret@anytls.example.com:443?sni=anytls.example.com&fp=chrome#anytls-node
stls://stls-pass@stls.example.com:443?sni=www.cloudflare.com&version=3#shadowtls-v3
naive+https://naive-user:naive-pass@naive-h2.example.com:443?sni=naive-h2.example.com&uot=1#naive-h2
naive+h3://naive-user:naive-pass@naive-h3.example.com:443?sni=naive-h3.example.com#naive-h3
wg://${WG_PRIV}@wg.example.com:51820?publicKey=${WG_PUB}&psk=${WG_PSK}&address=10.77.0.2/32&mtu=1400#wg-uri-pq-psk
amneziawg://${WG_PRIV}@awg.example.com:51821?publicKey=${WG_PUB}&psk=${WG_PSK}&address=10.88.0.2/32&mtu=1380&jc=4&jmin=40&jmax=70&s1=15&s2=25&h1=101&h2=102&h3=103&h4=104&i1=%3Cb%200xc001%3E#awg-uri-pq-psk
mieru://mieru-user:mieru-pass@mieru.example.com:2012?transport=TCP&multiplexing=MULTIPLEXING_HIGH#mieru-tcp
mierus://mieru-user:mieru-pass@mieru-udp.example.com:2013?transport=UDP#mieru-udp
tewfai://44444444-4444-4444-4444-444444444444:tewfai-pass@tewfai.example.com:443?sni=tewfai.example.com&transport=tcp,quic&inner_cipher=aes-256-gcm&morph_profile=browsing&pqc=1&fec=1#tewfai-pqc-node
trusttunnel://tt-user:tt-pass@tt.example.com:443?sni=tt.example.com&quic=1&cc=bbr#trusttunnel-quic
masque://masque.example.com:443?sni=masque.example.com&profile=standard&ip=172.16.0.2/32#masque-node
openconnect://oc-user:oc-pass@oc.example.com:443?protocol=anyconnect&sni=oc.example.com#openconnect-node
snell://snell-psk-secret@snell.example.com:9443?version=5&obfs=http&obfs-host=www.bing.com&uot=1&reuse=1#snell-v5-http
tg://proxy?server=mtproto.example.com&port=443&secret=ee0123456789abcdef0123456789abcdef636c6f7564666c6172652e636f6d#mtproto-faketls
sudoku://aabbccddeeff00112233445566778899@sudoku.example.com:443?aead=chacha20-poly1305&padding_min=5&padding_max=15&http_mask=true&http_mask_mode=ws&http_mask_host=sudoku.example.com&http_mask_path=/ws#sudoku-ws
ssh://ssh-user:ssh-pass@ssh.example.com:2222?client_version=SSH-2.0-OpenSSH_9.6p1#ssh-node
socks5://socks-user:socks-pass@socks.example.com:1080#socks5-node
http://http-user:http-pass@http.example.com:8080#http-node
EOF

base64 <"$WORK_DIR/bundle_raw.txt" | tr -d '\r\n' >"$WORK_DIR/bundle_b64.txt"
gzip -c "$WORK_DIR/bundle_b64.txt" >"$WORK_DIR/bundle_b64.gz"

# Normalize via ucode (engine="ucode")
ucode "$PARSER" normalize-content-validated "$WORK_DIR/bundle_raw.txt" "$WORK_DIR/ucode_raw_out.json" "" "ucode" ||
  fail "ucode failed to normalize 40-node multi-protocol raw bundle"
ucode "$PARSER" normalize-content-validated "$WORK_DIR/bundle_b64.txt" "$WORK_DIR/ucode_b64_out.json" "" "ucode" ||
  fail "ucode failed to normalize Base64 bundle"
ucode "$PARSER" normalize-content-validated "$WORK_DIR/bundle_b64.gz" "$WORK_DIR/ucode_gz_out.json" "" "ucode" ||
  fail "ucode failed to normalize Gzip+Base64 bundle"

# Verify UI metadata extraction from preamble comments
ucode "$PARSER" metadata-extract-ui-file "" "$WORK_DIR/bundle_b64.txt" "$WORK_DIR/ucode_meta.json" ||
  fail "ucode failed to extract UI metadata from Base64 bundle preamble"

grep -Fq '"Tachyon Full Interop"' "$WORK_DIR/ucode_meta.json" ||
  fail "expected decoded profile-title in ucode_meta.json"

if [ "$HAS_CORE" = "1" ]; then
  # Normalize via ucode delegating to tachyon-core (engine="core")
  TACHYON_CORE_BIN="$CORE_BIN" ucode "$PARSER" normalize-content-validated \
    "$WORK_DIR/bundle_raw.txt" "$WORK_DIR/core_via_ucode_out.json" "" "core" ||
    fail "engine=core failed to normalize 40-node multi-protocol raw bundle"

  # Parse directly via tachyon-core subscription parse --format full
  "$CORE_BIN" subscription parse "$WORK_DIR/bundle_b64.txt" --format full -o "$WORK_DIR/core_direct_full.json" ||
    fail "tachyon-core subscription parse --format full failed on Base64 bundle"

  # Compare ucode outbounds vs tachyon-core outbounds across all 40 nodes!
  UCODE_OUT="$WORK_DIR/ucode_raw_out.json" \
  CORE_VIA_UCODE="$WORK_DIR/core_via_ucode_out.json" \
  CORE_DIRECT="$WORK_DIR/core_direct_full.json" \
  node - <<'NODE'
const fs = require("fs");
const ucodeDoc = JSON.parse(fs.readFileSync(process.env.UCODE_OUT, "utf8"));
const coreViaUcodeDoc = JSON.parse(fs.readFileSync(process.env.CORE_VIA_UCODE, "utf8"));
const coreDirectDoc = JSON.parse(fs.readFileSync(process.env.CORE_DIRECT, "utf8"));

const uOut = ucodeDoc.outbounds;
const cuOut = coreViaUcodeDoc.outbounds;
const cdOut = coreDirectDoc.outbounds;

if (uOut.length !== 40) {
  console.error(`Expected 40 outbounds from ucode, got ${uOut.length}`);
  process.exit(1);
}
if (cuOut.length !== 40) {
  console.error(`Expected 40 outbounds from engine=core, got ${cuOut.length}`);
  process.exit(1);
}
if (cdOut.length !== 40) {
  console.error(`Expected 40 outbounds from tachyon-core direct parse, got ${cdOut.length}`);
  process.exit(1);
}
if (coreDirectDoc.metadata.profile_title !== "Tachyon Full Interop") {
  console.error(`Unexpected core profile_title: ${JSON.stringify(coreDirectDoc.metadata)}`);
  process.exit(1);
}
if (!coreDirectDoc.user_info || (coreDirectDoc.user_info.Upload || coreDirectDoc.user_info.upload) !== 1073741824) {
  console.error(`Unexpected core user_info: ${JSON.stringify(coreDirectDoc.user_info)}`);
  process.exit(1);
}

for (let i = 0; i < uOut.length; i++) {
  const u = uOut[i];
  const c = cdOut[i];
  if (u.type !== c.type) {
    console.error(`Node ${i} (${u.tag}) type mismatch: ucode=${u.type} vs core=${c.type}`);
    process.exit(1);
  }
  if (u.tag !== c.tag) {
    console.error(`Node ${i} tag mismatch: ucode=${u.tag} vs core=${c.tag}`);
    process.exit(1);
  }
  const uServer = u.server || (u.peers && u.peers[0] && u.peers[0].address);
  const cServer = c.server || (c.peers && c.peers[0] && c.peers[0].address);
  if (uServer !== cServer) {
    console.error(`Node ${i} (${u.tag}) server mismatch: ucode=${uServer} vs core=${cServer}`);
    process.exit(1);
  }
  const uPort = u.server_port || (u.peers && u.peers[0] && u.peers[0].port);
  const cPort = c.server_port || (c.peers && c.peers[0] && c.peers[0].port);
  if (uPort !== cPort) {
    console.error(`Node ${i} (${u.tag}) port mismatch: ucode=${uPort} vs core=${cPort}`);
    process.exit(1);
  }
}
NODE

  # Validate BOTH ucode-generated outbounds and core-generated outbounds through `tachyon-core check`
  for src_json in "$WORK_DIR/ucode_raw_out.json" "$WORK_DIR/core_via_ucode_out.json"; do
    SRC_JSON="$src_json" OUT_CFG="$WORK_DIR/check_cfg.json" node - <<'NODE'
const fs = require("fs");
const doc = JSON.parse(fs.readFileSync(process.env.SRC_JSON, "utf8"));
const outbounds = [{ type: "direct", tag: "direct" }];
const endpoints = [];
for (const o of doc.outbounds) {
  const copy = { ...o };
  delete copy.share_link;
  delete copy.remark;
  delete copy.__tachyon_allow_group;
  delete copy.__tachyon_hidden;
  if (copy.type === "wireguard") {
    if (!copy.address && copy.local_address) {
      copy.address = copy.local_address;
    }
    if (!copy.peers && copy.server) {
      const peer = {
        address: copy.server,
        port: copy.server_port || 51820,
        public_key: copy.peer_public_key || "",
        allowed_ips: ["0.0.0.0/0", "::/0"],
      };
      if (copy.pre_shared_key) peer.pre_shared_key = copy.pre_shared_key;
      if (copy.reserved) peer.reserved = copy.reserved;
      copy.peers = [peer];
    }
    for (const k of ["server", "server_port", "local_address", "peer_public_key", "pre_shared_key", "reserved", "persistent_keepalive_interval"]) {
      delete copy[k];
    }
    endpoints.push(copy);
  } else {
    if (copy.type === "shadowtls" && !copy.detour) {
      copy.detour = "direct";
    }
    outbounds.push(copy);
  }
}
fs.writeFileSync(process.env.OUT_CFG, JSON.stringify({ outbounds, endpoints }, null, 2));
NODE
    "$CORE_BIN" check -c "$WORK_DIR/check_cfg.json" ||
      fail "tachyon-core check rejected outbounds from $src_json"
  done

  # Also check native subscription expansion via `tachyon-core check -c`
  cat >"$WORK_DIR/sub_expand_cfg.json" <<EOF
{
  "subscriptions": [
    {
      "tag": "interop-sub",
      "path": "$WORK_DIR/bundle_b64.txt"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  "$CORE_BIN" check -c "$WORK_DIR/sub_expand_cfg.json" ||
    fail "tachyon-core check -c failed on native subscription expansion of Base64 bundle"
fi

# ---------------------------------------------------------------------------
# 2. Wrappers & Encryption (happ://, v2raytun://, incy://, crypt, crypt4, vpn://)
# ---------------------------------------------------------------------------
HWID_FIXED="a47a-cef7-2f80-655c"

# Verify OpenWrt HWID formula matches between cache.uc and tachyon-core
if [ "$HAS_CORE" = "1" ]; then
  # Build a wrapped v2raytun://import/happ://crypt4/ payload encrypted with HWID_FIXED and decrypt in both ucode and tachyon-core
  CRYPT_LINK="$(HWID="$HWID_FIXED" node - <<'NODE'
const crypto = require("crypto");
const hwid = process.env.HWID;
const plain = "vless://11111111-1111-1111-1111-111111111111@crypt-host.example.com:443?security=tls&sni=crypt-host.example.com#CryptNode\n";
const key = crypto.createHash("sha256").update(hwid).digest();
const iv = Buffer.from("000102030405060708090a0b0c0d0e0f", "hex");
const cipher = crypto.createCipheriv("aes-256-cbc", key, iv);
const enc = Buffer.concat([iv, cipher.update(plain, "utf8"), cipher.final()]);
process.stdout.write("v2raytun://import/happ://crypt4/" + enc.toString("base64"));
NODE
)"
  printf '%s\n' "$CRYPT_LINK" >"$WORK_DIR/crypt_sub.txt"

  "$CORE_BIN" subscription parse "$WORK_DIR/crypt_sub.txt" --hwid "$HWID_FIXED" --format outbounds -o "$WORK_DIR/core_crypt_out.json" ||
    fail "tachyon-core failed to decrypt v2raytun://import/happ://crypt4/ subscription"
  grep -Fq '"crypt-host.example.com"' "$WORK_DIR/core_crypt_out.json" ||
    fail "expected crypt-host.example.com in tachyon-core decrypted output"

  TACHYON_SUBSCRIPTION_HWID="$HWID_FIXED" ucode "$PARSER" normalize-content-validated \
    "$WORK_DIR/crypt_sub.txt" "$WORK_DIR/ucode_crypt_out.json" "" "ucode" ||
    fail "ucode failed to decrypt v2raytun://import/happ://crypt4/ subscription"
  grep -Fq '"crypt-host.example.com"' "$WORK_DIR/ucode_crypt_out.json" ||
    fail "expected crypt-host.example.com in ucode decrypted output"
fi

# ---------------------------------------------------------------------------
# 3. Structured Formats: Clash YAML, Xray JSON, SIP008, WireGuard .conf + Headers
# ---------------------------------------------------------------------------
cat >"$WORK_DIR/clash_sub.yaml" <<EOF
proxies:
  - name: clash-vless-pq-xhttp
    type: vless
    server: clash-vless.example.com
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
    encryption: mlkem768x25519plus.native.0rtt.${MLKEM768_EK}
    tls: true
    servername: clash-vless.example.com
    client-fingerprint: chrome
    reality-opts:
      public-key: ${REALITY_PUB}
      short-id: 01020304
      support_x25519mlkem768: true
    network: xhttp
    xhttp-opts:
      path: /xhttp
      host: clash-vless.example.com
      mode: packet-up
  - name: clash-hy2
    type: hysteria2
    server: clash-hy2.example.com
    port: 443
    password: hy2-password
    sni: clash-hy2.example.com
    obfs: salamander
    obfs-password: sal-password
    ports: 30000-40000
    up: 100 Mbps
    down: 200 Mbps
  - name: clash-hy2-gecko
    type: hysteria2
    server: clash-hy2-gecko.example.com
    port: 443
    password: hy2-gecko-password
    sni: clash-hy2-gecko.example.com
    obfs: gecko
    obfs-password: gecko-password
    packet-size: 200-1200
  - name: clash-tuic
    type: tuic
    server: clash-tuic.example.com
    port: 443
    uuid: 33333333-3333-3333-3333-333333333333
    password: tuic-password
    sni: clash-tuic.example.com
    congestion-controller: bbr
    udp-relay-mode: native
    reduce-rtt: true
  - name: clash-wg-awg
    type: wireguard
    server: clash-wg.example.com
    port: 51820
    ip: 10.99.0.2/32
    private-key: ${WG_PRIV}
    public-key: ${WG_PUB}
    pre-shared-key: ${WG_PSK}
    mtu: 1400
    amnezia-wg-opts:
      jc: 5
      jmin: 50
      jmax: 100
      s1: 20
      s2: 30
      h1: 111
      h2: 222
      h3: 333
      h4: 444
  - name: clash-tewfai-pqc
    type: tewfai
    server: clash-tewfai.example.com
    port: 443
    uuid: 44444444-4444-4444-4444-444444444444
    password: tewfai-password
    sni: clash-tewfai.example.com
    transport: tcp,quic
    inner-cipher: aes-256-gcm
    morph-profile: browsing
    pqc: true
    fec: true
  - name: clash-anytls
    type: anytls
    server: clash-anytls.example.com
    port: 443
    password: anytls-password
    sni: clash-anytls.example.com
    client-fingerprint: chrome
  - name: clash-sudoku
    type: sudoku
    server: clash-sudoku.example.com
    port: 443
    key: aabbccddeeff00112233445566778899
    aead: chacha20-poly1305
    http-mask: true
    http-mask-mode: ws
    http-mask-host: clash-sudoku.example.com
    http-mask-path: /ws
EOF

ucode "$PARSER" normalize-content-validated "$WORK_DIR/clash_sub.yaml" "$WORK_DIR/ucode_clash.json" "" "ucode" ||
  fail "ucode failed to normalize Clash YAML subscription"

if [ "$HAS_CORE" = "1" ]; then
  TACHYON_CORE_BIN="$CORE_BIN" ucode "$PARSER" normalize-content-validated \
    "$WORK_DIR/clash_sub.yaml" "$WORK_DIR/core_clash.json" "" "core" ||
    fail "engine=core failed to normalize Clash YAML subscription"

  UCODE_CLASH="$WORK_DIR/ucode_clash.json" CORE_CLASH="$WORK_DIR/core_clash.json" node - <<'NODE'
const fs = require("fs");
const u = JSON.parse(fs.readFileSync(process.env.UCODE_CLASH, "utf8")).outbounds;
const c = JSON.parse(fs.readFileSync(process.env.CORE_CLASH, "utf8")).outbounds;
if (u.length !== 8 || c.length !== 8) {
  console.error(`Expected 8 Clash outbounds, got ucode=${u.length}, core=${c.length}`);
  process.exit(1);
}
for (let i = 0; i < 8; i++) {
  if (u[i].type !== c[i].type || u[i].tag !== c[i].tag) {
    console.error(`Clash outbound ${i} mismatch: ucode=${JSON.stringify(u[i])} vs core=${JSON.stringify(c[i])}`);
    process.exit(1);
  }
}
NODE
fi

# Xray JSON outbound array with Post-Quantum VLESS + REALITY + XHTTP
cat >"$WORK_DIR/xray_sub.json" <<EOF
[
  {
    "remarks": "xray-vless-pq-xhttp",
    "outbounds": [
      {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "xray-pq.example.com",
              "port": 443,
              "users": [
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "encryption": "mlkem768x25519plus.native.0rtt.${MLKEM768_EK}"
                }
              ]
            }
          ]
        },
        "streamSettings": {
          "network": "xhttp",
          "security": "reality",
          "realitySettings": {
            "serverName": "www.microsoft.com",
            "fingerprint": "chrome",
            "publicKey": "${REALITY_PUB}",
            "shortId": "01020304"
          },
          "xhttpSettings": {
            "path": "/xhttp",
            "host": "www.microsoft.com",
            "mode": "stream-up"
          }
        }
      }
    ]
  }
]
EOF

ucode "$PARSER" normalize-content-validated "$WORK_DIR/xray_sub.json" "$WORK_DIR/ucode_xray.json" "" "ucode" ||
  fail "ucode failed to normalize Xray JSON subscription"

if [ "$HAS_CORE" = "1" ]; then
  TACHYON_CORE_BIN="$CORE_BIN" ucode "$PARSER" normalize-content-validated \
    "$WORK_DIR/xray_sub.json" "$WORK_DIR/core_xray.json" "" "core" ||
    fail "engine=core failed to normalize Xray JSON subscription"

  UCODE_XRAY="$WORK_DIR/ucode_xray.json" CORE_XRAY="$WORK_DIR/core_xray.json" node - <<'NODE'
const fs = require("fs");
const u = JSON.parse(fs.readFileSync(process.env.UCODE_XRAY, "utf8")).outbounds;
const c = JSON.parse(fs.readFileSync(process.env.CORE_XRAY, "utf8")).outbounds;
if (u.length !== 1 || c.length !== 1) {
  console.error(`Expected 1 Xray outbound, got ucode=${u.length}, core=${c.length}`);
  process.exit(1);
}
if (u[0].type !== "vless" || c[0].type !== "vless" || u[0].server !== "xray-pq.example.com" || c[0].server !== "xray-pq.example.com") {
  console.error(`Xray outbound mismatch: ucode=${JSON.stringify(u[0])} vs core=${JSON.stringify(c[0])}`);
  process.exit(1);
}
NODE
fi

# Raw WireGuard .conf with Peer parameters supplied via HTTP headers file
cat >"$WORK_DIR/wg_incomplete.conf" <<EOF
[Interface]
PrivateKey = ${WG_PRIV}
Address = 10.66.0.2/32
Jc = 3
Jmin = 30
Jmax = 60
S1 = 15
S2 = 20
H1 = 1001
H2 = 1002
H3 = 1003
H4 = 1004
EOF

cat >"$WORK_DIR/wg_headers.txt" <<EOF
HTTP/1.1 200 OK
X-Peer-Public-Key: ${WG_PUB}
X-Peer-Endpoint: 198.51.100.77:51820
EOF

ucode "$PARSER" normalize-content-validated "$WORK_DIR/wg_incomplete.conf" "$WORK_DIR/ucode_wg_hdr.json" "$WORK_DIR/wg_headers.txt" "ucode" ||
  fail "ucode failed to normalize incomplete WG .conf with HTTP headers"

if [ "$HAS_CORE" = "1" ]; then
  TACHYON_CORE_BIN="$CORE_BIN" ucode "$PARSER" normalize-content-validated \
    "$WORK_DIR/wg_incomplete.conf" "$WORK_DIR/core_wg_hdr.json" "$WORK_DIR/wg_headers.txt" "core" ||
    fail "engine=core failed to normalize incomplete WG .conf with HTTP headers"

  grep -Fq '"198.51.100.77"' "$WORK_DIR/core_wg_hdr.json" ||
    fail "expected 198.51.100.77 peer address in core_wg_hdr.json"
fi

printf 'Subscription core <-> ucode interop checks passed\n'
