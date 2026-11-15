#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let as_string = common.as_string;
let shell_quote = common.shell_quote;

function trim(str) {
    return replace(as_string(str), /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function is_crypt4(value) {
    value = lc(trim(value));
    return match(value, /^(happ:\/\/)?crypt4\//) != null;
}

function strip_prefix(value) {
    value = trim(value);
    if (match(value, /^(happ:\/\/)?crypt4\//i))
        return replace(value, /^(happ:\/\/)?crypt4\//i, "");
    return value;
}

function hex_to_bytes(h) {
    let res = "";
    for (let i = 0; i < length(h); i += 2)
        res += chr(hex(substr(h, i, 2)));
    return res;
}

function sha256_hex(str) {
    let p = fs.popen("printf %s " + shell_quote(str) + " | sha256sum 2>/dev/null", "r");
    if (!p)
        return "";
    let out = trim(p.read("all") || "");
    p.close();
    return split(out, /[ \t]+/)[0];
}

// Inverted S-Box for AES
let InvSbox = [
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d
];

// Forward S-box for key expansion
let Sbox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
];

let Rcon = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

let Mul9 = [], Mul11 = [], Mul13 = [], Mul14 = [];
function gmul(a, b) {
    let p = 0;
    for (let c = 0; c < 8; c++) {
        if ((b & 1) != 0) p ^= a;
        let hi = (a & 0x80);
        a = (a << 1) & 0xff;
        if (hi != 0) a ^= 0x1b;
        b >>= 1;
    }
    return p;
}
for (let i = 0; i < 256; i++) {
    push(Mul9, gmul(i, 9));
    push(Mul11, gmul(i, 11));
    push(Mul13, gmul(i, 13));
    push(Mul14, gmul(i, 14));
}

function key_expansion(key_bytes) {
    let Nk = length(key_bytes) / 4;
    let Nr = Nk + 6;
    let w = [];
    for (let i = 0; i < length(key_bytes); i += 4)
        push(w, [ord(key_bytes, i), ord(key_bytes, i + 1), ord(key_bytes, i + 2), ord(key_bytes, i + 3)]);

    for (let i = Nk; i < 4 * (Nr + 1); i++) {
        let temp = [w[i - 1][0], w[i - 1][1], w[i - 1][2], w[i - 1][3]];
        if (i % Nk == 0) {
            let t0 = temp[0];
            temp[0] = Sbox[temp[1]] ^ Rcon[i / Nk];
            temp[1] = Sbox[temp[2]];
            temp[2] = Sbox[temp[3]];
            temp[3] = Sbox[t0];
        } else if (Nk > 6 && (i % Nk == 4)) {
            temp[0] = Sbox[temp[0]];
            temp[1] = Sbox[temp[1]];
            temp[2] = Sbox[temp[2]];
            temp[3] = Sbox[temp[3]];
        }
        push(w, [w[i - Nk][0] ^ temp[0], w[i - Nk][1] ^ temp[1], w[i - Nk][2] ^ temp[2], w[i - Nk][3] ^ temp[3]]);
    }
    return { w, Nr };
}

function inv_cipher_block(block, exp) {
    let w = exp.w;
    let Nr = exp.Nr;
    let s = [];
    for (let r = 0; r < 4; r++) {
        s[r] = [];
        for (let c = 0; c < 4; c++)
            s[r][c] = ord(block, r + 4 * c);
    }

    for (let c = 0; c < 4; c++)
        for (let r = 0; r < 4; r++)
            s[r][c] ^= w[Nr * 4 + c][r];

    for (let round = Nr - 1; round >= 1; round--) {
        let t1 = s[1][3]; s[1][3] = s[1][2]; s[1][2] = s[1][1]; s[1][1] = s[1][0]; s[1][0] = t1;
        let t20 = s[2][0], t21 = s[2][1]; s[2][0] = s[2][2]; s[2][1] = s[2][3]; s[2][2] = t20; s[2][3] = t21;
        let t3 = s[3][0]; s[3][0] = s[3][1]; s[3][1] = s[3][2]; s[3][2] = s[3][3]; s[3][3] = t3;

        for (let r = 0; r < 4; r++)
            for (let c = 0; c < 4; c++)
                s[r][c] = InvSbox[s[r][c]];

        for (let c = 0; c < 4; c++)
            for (let r = 0; r < 4; r++)
                s[r][c] ^= w[round * 4 + c][r];

        for (let c = 0; c < 4; c++) {
            let s0 = s[0][c], s1 = s[1][c], s2 = s[2][c], s3 = s[3][c];
            s[0][c] = Mul14[s0] ^ Mul11[s1] ^ Mul13[s2] ^ Mul9[s3];
            s[1][c] = Mul9[s0] ^ Mul14[s1] ^ Mul11[s2] ^ Mul13[s3];
            s[2][c] = Mul13[s0] ^ Mul9[s1] ^ Mul14[s2] ^ Mul11[s3];
            s[3][c] = Mul11[s0] ^ Mul13[s1] ^ Mul9[s2] ^ Mul14[s3];
        }
    }

    let t1 = s[1][3]; s[1][3] = s[1][2]; s[1][2] = s[1][1]; s[1][1] = s[1][0]; s[1][0] = t1;
    let t20 = s[2][0], t21 = s[2][1]; s[2][0] = s[2][2]; s[2][1] = s[2][3]; s[2][2] = t20; s[2][3] = t21;
    let t3 = s[3][0]; s[3][0] = s[3][1]; s[3][1] = s[3][2]; s[3][2] = s[3][3]; s[3][3] = t3;

    for (let r = 0; r < 4; r++)
        for (let c = 0; c < 4; c++)
            s[r][c] = InvSbox[s[r][c]];

    for (let c = 0; c < 4; c++)
        for (let r = 0; r < 4; r++)
            s[r][c] ^= w[c][r];

    let out = "";
    for (let c = 0; c < 4; c++)
        for (let r = 0; r < 4; r++)
            out += chr(s[r][c]);
    return out;
}

function aes_cbc_decrypt(ciphertext, key_bytes, iv) {
    if (length(ciphertext) % 16 != 0 || length(key_bytes) < 16 || length(iv) != 16)
        return null;

    let exp = key_expansion(key_bytes);
    let plaintext = "";
    let prev = iv;
    for (let i = 0; i < length(ciphertext); i += 16) {
        let block = substr(ciphertext, i, 16);
        let dec = inv_cipher_block(block, exp);
        let xored = "";
        for (let j = 0; j < 16; j++)
            xored += chr(ord(dec, j) ^ ord(prev, j));
        plaintext += xored;
        prev = block;
    }

    // PKCS#7 unpadding validation
    let pad = ord(plaintext, length(plaintext) - 1);
    if (pad < 1 || pad > 16 || length(plaintext) < pad)
        return null;
    for (let i = length(plaintext) - pad; i < length(plaintext); i++) {
        if (ord(plaintext, i) != pad)
            return null;
    }
    return substr(plaintext, 0, length(plaintext) - pad);
}

function is_valid_plaintext(str) {
    if (str == null || length(str) == 0)
        return false;
    let len = length(str);
    for (let i = 0; i < len; i++) {
        let ch = ord(substr(str, i, 1));
        if (ch < 32 && ch != 9 && ch != 10 && ch != 13)
            return false;
    }
    return true;
}

function try_openssl_decrypt(cipher, key_hex, iv_hex, cipher_type) {
    let tmp_in = "/tmp/tachyon-c4-in." + clock()[0] + "." + clock()[1];
    if (fs.writefile(tmp_in, cipher) == null)
        return null;

    let cmd = "openssl enc -d -" + cipher_type + " -in " + shell_quote(tmp_in) + " -K " + shell_quote(key_hex) + " -iv " + shell_quote(iv_hex) + " 2>/dev/null";
    let p = fs.popen(cmd, "r");
    let out = p ? p.read("all") : null;
    let code = p ? p.close() : -1;
    fs.unlink(tmp_in);

    if (code != 0 || out == null || length(out) == 0 || !is_valid_plaintext(out))
        return null;

    return out;
}

function get_system_device_hwid() {
    let mac = trim(as_string(fs.readfile("/sys/class/net/eth0/address")));
    if (mac == "")
        mac = trim(as_string(fs.readfile("/sys/class/net/br-lan/address")));
    if (mac == "") {
        let mid = trim(as_string(fs.readfile("/etc/machine-id")));
        if (mid != "") return mid;
    }
    if (mac == "") return "";
    let p = fs.popen("printf %s " + shell_quote(mac) + " | md5sum 2>/dev/null", "r");
    if (!p) return "";
    let out = trim(p.read("all") || "");
    p.close();
    let hash = split(out, /[ \t]+/)[0];
    if (length(hash) >= 16)
        return substr(hash, 0, 4) + "-" + substr(hash, 4, 4) + "-" + substr(hash, 8, 4) + "-" + substr(hash, 12, 4);
    return "";
}

function decrypt_crypt4(payload, ...secret_keys) {
    payload = trim(as_string(payload));
    if (match(payload, /^(happ:\/\/)?crypt4\//i))
        payload = replace(payload, /^(happ:\/\/)?crypt4\//i, "");

    payload = replace(payload, /[\r\n\t ]/g, "");
    payload = replace(payload, /-/g, "+");
    payload = replace(payload, /_/g, "/");

    let rem = length(payload) % 4;
    if (rem == 1)
        return null;
    if (rem > 1) {
        for (let i = 0; i < 4 - rem; i++)
            payload += "=";
    }

    let binary = b64dec(payload);
    if (binary == null || length(binary) < 32)
        return null;

    let iv = substr(binary, 0, 16);
    let cipher = substr(binary, 16);
    if (length(cipher) % 16 != 0)
        return null;

    let keys = [];
    let seen_keys = {};
    function add_key(k) {
        if (type(k) == "array") {
            for (let item in k)
                add_key(item);
        } else {
            k = trim(as_string(k));
            if (k != "" && !seen_keys[k]) {
                seen_keys[k] = true;
                push(keys, k);
            }
        }
    }
    for (let k in secret_keys)
        add_key(k);

    let dev_hwid = get_system_device_hwid();
    if (dev_hwid != "")
        add_key(dev_hwid);

    add_key("HappDefaultSalt");

    let iv_hex = common.bytes_to_hex(iv);

    for (let k in keys) {
        let h = sha256_hex(k);
        if (length(h) != 64)
            continue;

        // 1. Try OpenSSL fast path if available
        let open_res = try_openssl_decrypt(cipher, h, iv_hex, "aes-256-cbc");
        if (open_res != null)
            return open_res;

        open_res = try_openssl_decrypt(cipher, substr(h, 0, 32), iv_hex, "aes-128-cbc");
        if (open_res != null)
            return open_res;

        // 2. Pure ucode fallback
        let full_key = hex_to_bytes(h);
        let res = aes_cbc_decrypt(cipher, full_key, iv);
        if (res != null && is_valid_plaintext(res))
            return res;

        res = aes_cbc_decrypt(cipher, substr(full_key, 0, 16), iv);
        if (res != null && is_valid_plaintext(res))
            return res;
    }
    return null;
}

function module_exports() {
    return {
        is_crypt4,
        strip_prefix,
        decrypt: decrypt_crypt4
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

let mode = ARGV[0] || "";
if (mode == "is-crypt4")
    exit(is_crypt4(ARGV[1]) ? 0 : 1);
else if (mode == "decrypt") {
    let dec = decrypt_crypt4(ARGV[1], ARGV[2], ARGV[3]);
    if (dec == null)
        exit(1);
    print(dec);
}
