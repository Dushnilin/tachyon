// Bounded Qt qCompress/zlib decoder and Amnezia WG/AWG container extraction.
// No shell commands, external decoders, hooks or server-management credentials.
let max_size = 65536;
function byte(data, at) {
    assert(at >= 0 && at < length(data), 'truncated Amnezia data');
    return ord(data, at);
}
function be32(data, at) {
    return byte(data, at) * 16777216 + byte(data, at + 1) * 65536 +
        byte(data, at + 2) * 256 + byte(data, at + 3);
}
function bits(s, count) {
    let value = 0;
    for (let i = 0; i < count; i++) {
        assert(s.at < s.end, 'truncated deflate block');
        value |= ((byte(s.data, s.at) >> s.bit) & 1) << i;
        if (++s.bit == 8) { s.bit = 0; s.at++; }
    }
    return value;
}
function tree(lengths, complete) {
    let counts = [], next = [], levels = [], largest = 0, symbols = 0;
    for (let i = 0; i <= 15; i++) { counts[i] = 0; levels[i] = {}; }
    for (let n in lengths) {
        assert(n >= 0 && n <= 15, 'invalid Huffman length');
        if (n) { counts[n]++; symbols++; if (n > largest) largest = n; }
    }
    let left = 1, code = 0;
    for (let n = 1; n <= 15; n++) {
        left = left * 2 - counts[n];
        assert(left >= 0, 'oversubscribed Huffman tree');
        code = (code + counts[n - 1]) * 2;
        next[n] = code;
    }
    assert(left == 0 || (!complete && (symbols == 0 || largest == 1)), 'incomplete Huffman tree');
    for (let i = 0; i < length(lengths); i++) {
        let n = lengths[i];
        if (n) levels[n][next[n]++] = i;
    }
    return {levels, largest};
}
function symbol(s, t) {
    let code = 0;
    for (let n = 1; n <= t.largest; n++) {
        code = (code << 1) | bits(s, 1);
        let found = t.levels[n][code];
        if (found != null) return found;
    }
    assert(false, 'invalid Huffman symbol');
}
function emit(s, n) {
    assert(length(s.out) < s.expected, 'Amnezia output exceeds declared size');
    s.out += chr(n);
    s.a = (s.a + n) % 65521;
    s.b = (s.b + s.a) % 65521;
}
function inflate(data) {
    assert(length(data) >= 12, 'short Qt/zlib payload');
    let expected = be32(data, 0), cmf = byte(data, 4), flg = byte(data, 5);
    assert(expected > 0 && expected <= max_size && (cmf & 15) == 8 &&
        (cmf >> 4) <= 7 && !(flg & 32) && (cmf * 256 + flg) % 31 == 0, 'invalid Qt/zlib header');
    let s = {data, at:6, bit:0, end:length(data) - 4, expected, out:'', a:1, b:0};
    let length_base = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258];
    let length_extra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0];
    let dist_base = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577];
    let dist_extra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13];
    let final = 0;
    while (!final) {
        final = bits(s, 1);
        let kind = bits(s, 2);
        assert(kind != 3, 'reserved deflate block');
        if (kind == 0) {
            if (s.bit) { s.at++; s.bit = 0; }
            let size = bits(s, 16), inverse = bits(s, 16);
            assert((size ^ inverse) == 65535 && length(s.out) + size <= expected, 'invalid stored block');
            for (let i = 0; i < size; i++) emit(s, bits(s, 8));
            continue;
        }
        let lit_lengths = [], dist_lengths = [];
        if (kind == 1) {
            for (let i = 0; i < 288; i++) push(lit_lengths, i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8);
            for (let i = 0; i < 32; i++) push(dist_lengths, 5);
        } else {
            let hlit = bits(s, 5) + 257, hdist = bits(s, 5) + 1, hclen = bits(s, 4) + 4;
            assert(hlit <= 286, 'invalid literal count');
            // RFC 1951 code-length alphabet order (all 19 symbols).
            let order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15];
            let code_lengths = [], lengths = [];
            for (let i = 0; i < 19; i++) code_lengths[i] = 0;
            for (let i = 0; i < hclen; i++) code_lengths[order[i]] = bits(s, 3);
            let codes = tree(code_lengths, true);
            while (length(lengths) < hlit + hdist) {
                let n = symbol(s, codes);
                if (n < 16) { push(lengths, n); continue; }
                assert(n != 16 || length(lengths) > 0, 'repeat without previous length');
                let value = n == 16 ? lengths[length(lengths) - 1] : 0;
                let repeat = n == 16 ? bits(s, 2) + 3 : n == 17 ? bits(s, 3) + 3 : bits(s, 7) + 11;
                assert(length(lengths) + repeat <= hlit + hdist, 'code-length repeat overflow');
                for (let i = 0; i < repeat; i++) push(lengths, value);
            }
            lit_lengths = slice(lengths, 0, hlit);
            dist_lengths = slice(lengths, hlit);
        }
        assert(lit_lengths[256] > 0, 'missing end-of-block symbol');
        let literals = tree(lit_lengths, false), distances = tree(dist_lengths, false);
        while (true) {
            let n = symbol(s, literals);
            if (n < 256) { emit(s, n); continue; }
            if (n == 256) break;
            assert(n <= 285, 'invalid length symbol');
            let size = length_base[n - 257] + bits(s, length_extra[n - 257]);
            let d = symbol(s, distances);
            assert(d < 30, 'invalid distance symbol');
            let distance = dist_base[d] + bits(s, dist_extra[d]);
            assert(distance <= length(s.out) && distance <= (1 << ((cmf >> 4) + 8)) &&
                length(s.out) + size <= expected, 'invalid back-reference');
            for (let i = 0; i < size; i++) emit(s, byte(s.out, length(s.out) - distance));
        }
    }
    assert(s.at + (s.bit ? 1 : 0) == s.end && length(s.out) == expected, 'size mismatch or trailing data');
    assert(s.b * 65536 + s.a == be32(data, s.end), 'invalid Adler-32 checksum');
    return s.out;
}
function object(value) {
    if (type(value) == 'string') {
        try { value = json(value); } catch (e) { return null; }
    }
    return type(value) == 'object' ? value : null;
}
function extract(text) {
    if (length(text) > max_size || index(text, '\u0000') >= 0) return null;
    if (substr(trim(text), 0, 1) != '{') return {text, name:'', awg:false};
    let data = object(text);
    if (!data || type(data.containers) != 'array' || !length(data.containers) || length(data.containers) > 16) return null;
    let choices = [], selected = null;
    for (let container in data.containers) {
        if (type(container) != 'object') return null;
        let kind = container.container, protocol = index(['amnezia-awg', 'amnezia-awg2'], kind) >= 0 ? 'awg' :
            kind == 'amnezia-wireguard' ? 'wireguard' : null;
        if (!protocol) continue;
        let settings = object(container[protocol]);
        let last = settings ? object(settings.last_config) : null;
        // Use the exported INI as the source of truth: preserve all AWG fields.
        if (!last || type(last.config) != 'string') return null;
        let candidate = {text:last.config, name:type(data.description) == 'string' ? data.description : '', awg:protocol == 'awg'};
        push(choices, candidate);
        if (kind == data.defaultContainer) {
            if (selected) return null;
            selected = candidate;
        }
    }
    if (!selected) {
        if (type(data.defaultContainer) == 'string' && data.defaultContainer != '') return null;
        if (length(choices) != 1) return null;
        selected = choices[0];
    }
    let name = '';
    if (length(selected.name) > 200) selected.name = '';
    for (let i = 0; i < length(selected.name); i++) {
        let n = byte(selected.name, i);
        if (n >= 32 && n != 127) name += chr(n);
    }
    selected.name = name;
    return selected;
}
function decode(data) {
    try {
        if (length(data) >= 6 && byte(data, 0) == 0)
            data = inflate(data);
        return extract(data);
    } catch (e) { return null; }
}
return {decode};
