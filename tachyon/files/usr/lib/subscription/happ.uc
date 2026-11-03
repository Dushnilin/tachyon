#!/usr/bin/env ucode
// Happ's RSA and ChaCha20-Poly1305 primitives are provided by OpenSSL.
// Wire format reference and compatibility keys: see happ-keys.NOTICE.
let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");

const MAX_LINK_BYTES = 65536;
let key_table = null;

function trim(value) {
    return replace(common.as_string(value), /^\s+|\s+$/g, "");
}

function is_encrypted(value) {
    return match(trim(value), /^(happ:\/\/)?crypt([2-5])?\//i) != null;
}

function decode64(value) {
    value = replace(common.as_string(value), /\s/g, "");
    value = replace(replace(value, /-/g, "+"), /_/g, "/");
    if (value == "" || length(value) > MAX_LINK_BYTES ||
        !match(value, /^[A-Za-z0-9+\/]*={0,2}$/) || length(value) % 4 == 1)
        return null;
    while (length(value) % 4 != 0)
        value += "=";
    return b64dec(value);
}

function swap_pairs(value, block_halves) {
    let step = block_halves ? 4 : 2;
    let half = step / 2;
    let end = length(value) - length(value) % step;
    let out = "";
    for (let i = 0; i < end; i += step)
        out += substr(value, i + half, half) + substr(value, i, half);
    return out + substr(value, end);
}

function run_openssl(args) {
    return exec.run({ argv: [ "openssl", ...args ], timeout: 15 }).status == 0;
}

function write_private(path, value) {
    return fs.writefile(path, value) == length(value);
}

function pem_key(value, kind) {
    let lines = [];
    for (let i = 0; i < length(value); i += 64)
        push(lines, substr(value, i, 64));
    return "-----BEGIN " + kind + "-----\n" + join("\n", lines) +
        "\n-----END " + kind + "-----\n";
}

function rsa_decrypt(work, cipher, key, kind) {
    if (cipher == null || !write_private(work + "/key", pem_key(key, kind)) ||
        !write_private(work + "/cipher", cipher))
        return null;
    fs.unlink(work + "/plain");
    if (!run_openssl([ "pkeyutl", "-decrypt", "-inkey", work + "/key",
        "-pkeyopt", "rsa_padding_mode:pkcs1", "-in", work + "/cipher", "-out", work + "/plain" ]))
        return null;
    return fs.readfile(work + "/plain");
}

function little_endian_64(value) {
    let result = "";
    for (let i = 0; i < 8; i++) {
        result += chr(value & 255);
        value >>= 8;
    }
    return result;
}

function zeros(count) {
    let result = "";
    for (let i = 0; i < count; i++)
        result += chr(0);
    return result;
}

function chacha20(work, data, key, nonce, counter) {
    if (!write_private(work + "/cipher", data))
        return null;
    fs.unlink(work + "/plain");
    // OpenSSL's 16-byte IV is the raw counter/nonce state. For these bounded
    // messages counter32 || nonce96 is the RFC 8439 state (no counter wrap).
    let iv = substr(little_endian_64(counter), 0, 4) + nonce;
    if (!run_openssl([ "enc", "-chacha20", "-K", common.bytes_to_hex(key),
        "-iv", common.bytes_to_hex(iv), "-in", work + "/cipher", "-out", work + "/plain" ]))
        return null;
    return fs.readfile(work + "/plain");
}

function decrypt_aead(work, packed, key, nonce) {
    if (packed == null || length(packed) < 16)
        return null;
    let cipher = substr(packed, 0, length(packed) - 16);
    let tag = substr(packed, -16);
    let poly_key = chacha20(work, zeros(32), key, nonce, 0);
    if (poly_key == null || length(poly_key) != 32)
        return null;
    // RFC 8439, empty AAD: ciphertext || pad16 || aad_len64 || cipher_len64.
    let mac_input = cipher + zeros((16 - length(cipher) % 16) % 16) +
        little_endian_64(0) + little_endian_64(length(cipher));
    if (!write_private(work + "/mac-input", mac_input))
        return null;
    fs.unlink(work + "/tag");
    if (!run_openssl([ "dgst", "-mac", "POLY1305", "-macopt", "hexkey:" + common.bytes_to_hex(poly_key),
        "-binary", "-out", work + "/tag", work + "/mac-input" ]))
        return null;
    let actual = fs.readfile(work + "/tag");
    if (actual == null || length(actual) != 16)
        return null;
    let mismatch = 0;
    for (let i = 0; i < 16; i++)
        mismatch |= ord(substr(actual, i, 1)) ^ ord(substr(tag, i, 1));
    if (mismatch != 0)
        return null;
    return chacha20(work, cipher, key, nonce, 1);
}

function decrypt_crypt5_body(work, body, key, salted) {
    let start = salted ? 22 : 12;
    if (length(body) <= start)
        return null;
    let digits = match(substr(body, start), /^([0-9]{1,6})[^0-9]/);
    if (digits == null)
        return null;
    let size = int(digits[1], 10);
    let offset = start + length(digits[1]) + 1;
    if (size < 1 || offset + size >= length(body))
        return null;
    let cipher_key = decode64(substr(body, offset + size));
    if (cipher_key == null || length(cipher_key) != 512)
        return null;
    let recovered = rsa_decrypt(work, cipher_key, key, "PRIVATE KEY");
    if (recovered == null)
        return null;
    recovered = decode64(swap_pairs(recovered, false));
    if (recovered == null || length(recovered) != 32)
        return null;
    let chacha_key = "";
    for (let i = 0; i < 32; i++) {
        let byte = ord(substr(recovered, i, 1));
        if (salted)
            byte ^= ord(substr(body, 14 + i % 8, 1));
        chacha_key += chr(byte);
    }
    let plain = decrypt_aead(work, decode64(substr(body, offset, size)), chacha_key, substr(body, 0, 12));
    return plain == null ? null : decode64(swap_pairs(plain, false));
}

function decrypt_rsa(work, mode, payload) {
    if (key_table == null) {
        let path = (getenv("TACHYON_LIB") || "/usr/lib/tachyon") + "/subscription/happ-keys.json";
        try { key_table = json(fs.readfile(path)); } catch (e) { return null; }
    }
    if (mode == "crypt5") {
        let value = swap_pairs(payload, true);
        if (length(value) < 8)
            return null;
        let marker = substr(value, 0, 4) + substr(value, -4);
        let key = key_table.crypt5?.[marker];
        if (type(key) != "string")
            return null;
        let body = substr(value, 4, length(value) - 8);
        // A salted header can begin with a digit too: authenticate both layouts.
        return decrypt_crypt5_body(work, body, key, false) ??
            decrypt_crypt5_body(work, body, key, true);
    }
    let key = key_table[mode];
    let cipher = decode64(payload);
    let block = mode == "crypt" ? 128 : 512;
    if (type(key) != "string" || cipher == null || length(cipher) % block != 0)
        return null;
    let plain = "";
    for (let i = 0; i < length(cipher); i += block) {
        let part = rsa_decrypt(work, substr(cipher, i, block), key, "RSA PRIVATE KEY");
        if (part == null)
            return null;
        plain += part;
    }
    return plain;
}

function decrypt(value, ...legacy_keys) {
    value = trim(value);
    if (length(value) > MAX_LINK_BYTES)
        return null;
    let parsed = match(value, /^(happ:\/\/)?(crypt([2-5])?)\/(.+)$/i);
    if (parsed == null)
        return null;
    let mode = lc(parsed[2]);
    let plain = null;
    let work = trim(common.command_output_from_args([ "mktemp", "-d", "/tmp/tachyon-happ.XXXXXX" ]));
    if (match(work, /^\/tmp\/tachyon-happ\.[A-Za-z0-9]+$/)) {
        try { plain = decrypt_rsa(work, mode, parsed[4]); } catch (e) {}
        for (let path in (fs.glob(work + "/*") || []))
            fs.unlink(path);
        fs.rmdir(work);
    }
    // Preserve the older Tachyon AES/HWID dialect without confusing it with
    // Happ's RSA wire format. Only crypt4 ever accepted that dialect.
    if (plain == null && mode == "crypt4")
        plain = require("subscription.crypt4").decrypt(value, ...legacy_keys);
    if (plain == null || plain == "" || index(plain, chr(0)) >= 0)
        return null;
    return plain;
}

return { is_encrypted, decrypt };
