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
function inflate_stream(data, has_qt_header) {
    assert(length(data) >= (has_qt_header ? 12 : 8), 'short Qt/zlib payload');
    let declared = has_qt_header ? be32(data, 0) : 0;
    let is_amnezia_sig = has_qt_header && declared == 255;
    let expected = (!has_qt_header || is_amnezia_sig) ? max_size : declared;
    let cmf = byte(data, has_qt_header ? 4 : 0), flg = byte(data, has_qt_header ? 5 : 1);
    assert(expected > 0 && expected <= max_size && (cmf & 15) == 8 &&
        (cmf >> 4) <= 7 && !(flg & 32) && (cmf * 256 + flg) % 31 == 0, 'invalid Qt/zlib header');
    let s = {data, at:(has_qt_header ? 6 : 2), bit:0, end:length(data) - 4, expected, out:'', a:1, b:0};
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
    assert(s.at + (s.bit ? 1 : 0) == s.end && (has_qt_header && !is_amnezia_sig ? length(s.out) == expected : length(s.out) > 0), 'size mismatch or trailing data');
    assert(s.b * 65536 + s.a == be32(data, s.end), 'invalid Adler-32 checksum');
    return s.out;
}
function inflate(data) {
    return inflate_stream(data, true);
}
function object(value) {
    if (type(value) == 'string') {
        try { value = json(value); } catch (e) { return null; }
    }
    return type(value) == 'object' ? value : null;
}
let awg_json_keys = [
    'Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4',
    'H1', 'H2', 'H3', 'H4', 'I1', 'I2', 'I3', 'I4', 'I5',
    'J1', 'J2', 'J3', 'Itime', 'mtu',
    'HeaderProtectionKey', 'ContentPaddingAddition', 'RekeyAfterTime',
    'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout',
    'MaxHandshakeAttempts', 'RandomTrailers', 'DisableCookies'
];
function inject_awg_fields(conf_text, source_obj) {
    if (type(conf_text) != 'string' || type(source_obj) != 'object')
        return conf_text;
    let present = {};
    for (let line in split(conf_text, '\n')) {
        let eq = index(line, '=');
        if (eq > 0) {
            let k = lc(trim(substr(line, 0, eq)));
            let v = trim(substr(line, eq + 1));
            if (v != '' && substr(v, 0, 1) != '$')
                present[k] = true;
        }
    }
    let extra = [];
    let replaced_keys = {};
    for (let key in awg_json_keys) {
        let lk = lc(key);
        if (present[lk]) continue;
        let val = source_obj[key] != null ? source_obj[key] : source_obj[lk];
        if (val == null) continue;
        let sval = trim('' + val);
        if (sval == '' || substr(sval, 0, 1) == '$' || index(sval, '\n') >= 0 || index(sval, '\r') >= 0) continue;
        push(extra, (lk == 'mtu' ? 'MTU' : key) + ' = ' + sval);
        present[lk] = true;
        replaced_keys[lk] = true;
    }
    if (!length(extra))
        return conf_text;
    let out = [], injected = false;
    for (let line in split(conf_text, '\n')) {
        let eq = index(line, '=');
        if (eq > 0) {
            let k = lc(trim(substr(line, 0, eq)));
            let v = trim(substr(line, eq + 1));
            if (replaced_keys[k] && (v == '' || substr(v, 0, 1) == '$'))
                continue;
        }
        push(out, line);
        if (!injected && lc(trim(line)) == '[interface]') {
            for (let item in extra) push(out, item);
            injected = true;
        }
    }
    return join('\n', out);
}
function first_str(objs, keys) {
    for (let obj in objs) {
        if (type(obj) != 'object') continue;
        for (let k in keys) {
            let v = obj[k];
            if (type(v) == 'string' && trim(v) != '')
                return trim(v);
        }
    }
    return '';
}
function first_scalar(objs, keys) {
    for (let obj in objs) {
        if (type(obj) != 'object') continue;
        for (let k in keys) {
            let v = obj[k];
            if (type(v) == 'string' && trim(v) != '')
                return trim(v);
            if (type(v) == 'int')
                return '' + v;
        }
    }
    return '';
}
function clean_label(raw) {
    if (type(raw) != 'string' || length(raw) > 200) return '';
    let out = '';
    for (let i = 0; i < length(raw); i++) {
        let n = byte(raw, i);
        if (n >= 32 && n != 127) out += chr(n);
    }
    return out;
}
function finalize_conf_text(conf_text, last, settings, data) {
    if (type(conf_text) != 'string' || conf_text == '') return conf_text;
    let objs = [last, settings, data];
    let host = first_str(objs, ['hostName', 'hostname', 'host', 'server']);
    let endpoint_host = (host != '' && index(host, ':') >= 0 && substr(host, 0, 1) != '[') ? ('[' + host + ']') : host;
    if (endpoint_host != '') {
        conf_text = replace(conf_text, /\$REMOTE_HOST/g, endpoint_host);
        conf_text = replace(conf_text, /\$SERVER_IP_ADDRESS/g, endpoint_host);
    }
    let lower = lc(conf_text);
    if (index(lower, '[interface]') >= 0 && index(lower, '[peer]') < 0) {
        let pub = first_str(objs, ['server_pub_key', 'peer_public_key', 'public_key', 'publicKey', 'serverPublicKey']);
        let port = first_scalar(objs, ['port', 'server_port']);
        if (pub != '' && endpoint_host != '' && port != '') {
            let psk = first_str(objs, ['psk_key', 'preshared_key', 'presharedKey', 'pre_shared_key']);
            let allowed = first_str(objs, ['allowed_ips', 'allowedIps']);
            let ka = first_scalar(objs, ['persistent_keepalive', 'persistentKeepalive', 'keepalive']);
            if (substr(conf_text, length(conf_text) - 1) != '\n')
                conf_text += '\n';
            conf_text += '[Peer]\nPublicKey = ' + pub + '\n';
            if (psk != '' && substr(psk, 0, 1) != '$')
                conf_text += 'PresharedKey = ' + psk + '\n';
            conf_text += 'Endpoint = ' + endpoint_host + ':' + port + '\n';
            conf_text += 'AllowedIPs = ' + (allowed != '' ? allowed : '0.0.0.0/0, ::/0') + '\n';
            if (ka != '' && substr(ka, 0, 1) != '$')
                conf_text += 'PersistentKeepalive = ' + ka + '\n';
        }
    }
    return conf_text;
}
function synthesize_conf_from_object(last, settings, data) {
    if (type(last) != 'object') return null;
    let objs = [last, settings, data];
    let priv = first_str([last, settings], ['client_priv_key', 'private_key', 'privateKey']);
    let pub = first_str(objs, ['server_pub_key', 'peer_public_key', 'public_key', 'publicKey', 'serverPublicKey']);
    let addr = first_str([last, settings], ['client_ip', 'address', 'client_address']);
    let host = first_str(objs, ['hostName', 'hostname', 'host', 'server']);
    let port = first_scalar(objs, ['port', 'server_port']);
    let psk = first_str(objs, ['psk_key', 'preshared_key', 'presharedKey', 'pre_shared_key']);
    if (priv == '' || pub == '' || addr == '' || host == '' || port == '')
        return null;
    let endpoint_host = (index(host, ':') >= 0 && substr(host, 0, 1) != '[') ? ('[' + host + ']') : host;
    let mtu = first_scalar([last, settings], ['mtu']);
    let allowed = first_str(objs, ['allowed_ips', 'allowedIps']);
    let ka = first_scalar(objs, ['persistent_keepalive', 'persistentKeepalive', 'keepalive']);
    let lines = [
        '[Interface]',
        'PrivateKey = ' + priv,
        'Address = ' + addr
    ];
    if (mtu != '')
        push(lines, 'MTU = ' + mtu);
    push(lines, '[Peer]');
    push(lines, 'PublicKey = ' + pub);
    if (psk != '' && substr(psk, 0, 1) != '$')
        push(lines, 'PresharedKey = ' + psk);
    push(lines, 'Endpoint = ' + endpoint_host + ':' + port);
    push(lines, 'AllowedIPs = ' + (allowed != '' ? allowed : '0.0.0.0/0, ::/0'));
    if (ka != '' && substr(ka, 0, 1) != '$')
        push(lines, 'PersistentKeepalive = ' + ka);
    return join('\n', lines) + '\n';
}
function resolve_container_conf(settings, data) {
    if (type(settings) != 'object') return null;
    let raw_last = settings.last_config != null ? settings.last_config : settings.config;
    if (type(raw_last) == 'string' && substr(trim(raw_last), 0, 1) != '{' && index(lc(raw_last), '[interface]') >= 0) {
        let conf_out = inject_awg_fields(raw_last, settings);
        return finalize_conf_text(conf_out, settings, settings, data);
    }
    let last = object(raw_last) || settings;
    let conf_str = type(last.config) == 'string' ? last.config :
        (type(settings.config) == 'string' ? settings.config : synthesize_conf_from_object(last, settings, data));
    if (type(conf_str) != 'string' || conf_str == '')
        return null;
    conf_str = finalize_conf_text(conf_str, last, settings, data);
    conf_str = inject_awg_fields(conf_str, last);
    conf_str = inject_awg_fields(conf_str, settings);
    return conf_str;
}
function decompress(raw) {
    if (type(raw) != 'string' || substr(raw, 0, 6) != 'vpn://') return null;
    let payload = split(substr(raw, 6), '#')[0];
    if (length(payload) > 131072) return null;
    payload = replace(payload, /%([0-9A-Fa-f]{2})/g, (all, n) => chr(hex(n)));
    payload = replace(payload, /[\r\n\t ]+/g, '');
    payload = replace(replace(payload, /-/g, '+'), /_/g, '/');
    if (!match(payload, /^[A-Za-z0-9+\/]*={0,2}$/) || length(payload) % 4 == 1) return null;
    while (length(payload) % 4) payload += '=';
    let data = null;
    try { data = b64dec(payload); } catch(e) {}
    if (data == null) return null;
    try {
        if (length(data) >= 6 && byte(data, 0) == 0)
            data = inflate_stream(data, true);
        else if (length(data) >= 8 && substr(trim(data), 0, 1) != '{' && substr(trim(data), 0, 1) != '[' && substr(trim(data), 0, 1) != '#') {
            let cmf = byte(data, 0), flg = byte(data, 1);
            if ((cmf & 15) == 8 && (cmf >> 4) <= 7 && !(flg & 32) && (cmf * 256 + flg) % 31 == 0)
                data = inflate_stream(data, false);
        }
        if (length(data) > max_size || index(data, '\u0000') >= 0) return null;
        return data;
    } catch (e) { return null; }
}
function has_awg_hint_in_obj(data, conf_text) {
    return (data && (data.Jc != null || data.jc != null || data.H1 != null || data.h1 != null)) ||
        index(lc(conf_text), '\njc') >= 0 || index(lc(conf_text), '\nh1') >= 0;
}
function extract_single_obj(data, fallback_name) {
    let direct_conf = resolve_container_conf(data, data);
    if (!direct_conf) return null;
    let dname = type(data.description) == 'string' ? data.description : (type(data.name) == 'string' ? data.name : fallback_name);
    return {text:direct_conf, name:clean_label(dname), awg:has_awg_hint_in_obj(data, direct_conf)};
}
function extract_containers(data, fallback_name) {
    if (!length(data.containers) || length(data.containers) > 16) return null;
    let choices = [], selected = null;
    let def_kind = type(data.defaultContainer) == 'string' ? lc(trim(data.defaultContainer)) : '';
    let desc = clean_label(type(data.description) == 'string' ? data.description : (type(data.name) == 'string' ? data.name : fallback_name));
    for (let container in data.containers) {
        if (type(container) != 'object') return null;
        let kind_raw = type(container.container) == 'string' ? trim(container.container) : '';
        let kind = lc(kind_raw);
        let protocol = index(['amnezia-awg', 'amnezia-awg2', 'amnezia-awg3', 'amnezia-awg-v2', 'amnezia-awg-v3', 'amnezia-awg1.5', 'amnezia-awg3.1', 'awg', 'awg2', 'awg3'], kind) >= 0 ? 'awg' :
            index(['amnezia-wireguard', 'wireguard', 'wg'], kind) >= 0 ? 'wireguard' : null;
        if (!protocol && kind == '') {
            if (object(container.awg) || object(container.awg2) || object(container.awg3) ||
                object(container['amnezia-awg']) || object(container['amnezia-awg2']) || object(container['amnezia-awg3']))
                protocol = 'awg';
            else if (object(container.wireguard) || object(container.wg) || object(container['amnezia-wireguard']))
                protocol = 'wireguard';
        }
        if (!protocol) continue;
        let settings = object(container[protocol]) || object(container.awg) || object(container.awg2) ||
            object(container.awg3) || object(container['amnezia-awg']) || object(container['amnezia-awg2']) ||
            object(container['amnezia-awg3']) || object(container['amnezia-wireguard']) ||
            object(container[kind_raw]) || object(container[kind]) || object(container.params) ||
            ((container.last_config != null || container.config != null) ? container : null);
        let conf_text = resolve_container_conf(settings, data);
        if (!conf_text) continue;
        let candidate = {text:conf_text, name:desc, awg:protocol == 'awg'};
        push(choices, candidate);
        if (def_kind != '' && kind == def_kind) {
            if (selected) return null;
            selected = candidate;
        }
    }
    if (!selected) {
        if (!length(choices)) return null;
        for (let choice in choices) {
            if (choice.awg) {
                selected = choice;
                break;
            }
        }
        if (!selected) selected = choices[0];
    }
    return selected;
}
function extract(text) {
    if (length(text) > max_size || index(text, '\u0000') >= 0) return null;
    if (substr(trim(text), 0, 1) != '{') return {text, name:'', awg:false};
    let data = object(text);
    if (!data) return null;
    if (type(data.containers) != 'array') {
        let outer_name = type(data.description) == 'string' ? data.description : (type(data.name) == 'string' ? data.name : '');
        let wrapped = first_str([data], ['config', 'wg_config', 'awg_config']);
        if (substr(wrapped, 0, 6) == 'vpn://') {
            let inner = decompress(wrapped);
            if (type(inner) != 'string') return null;
            if (substr(trim(inner), 0, 1) != '{') {
                let conf_out = finalize_conf_text(inner, data, data, data);
                return {text:conf_out, name:clean_label(outer_name), awg:has_awg_hint_in_obj(data, conf_out)};
            }
            let inner_obj = object(inner);
            if (!inner_obj) return null;
            if (type(inner_obj.containers) == 'array')
                return extract_containers(inner_obj, outer_name);
            return extract_single_obj(inner_obj, outer_name);
        }
        return extract_single_obj(data, '');
    }
    return extract_containers(data, '');
}
function decode(data) {
    try {
        if (length(data) >= 6 && byte(data, 0) == 0)
            data = inflate_stream(data, true);
        else if (length(data) >= 8 && substr(trim(data), 0, 1) != '{' && substr(trim(data), 0, 1) != '[' && substr(trim(data), 0, 1) != '#') {
            let cmf = byte(data, 0), flg = byte(data, 1);
            if ((cmf & 15) == 8 && (cmf >> 4) <= 7 && !(flg & 32) && (cmf * 256 + flg) % 31 == 0)
                data = inflate_stream(data, false);
        }
        return extract(data);
    } catch (e) { return null; }
}
function diagnose(raw) {
    let text = decompress(raw);
    if (type(text) != 'string')
        return {reason:'invalid_vpn_link', detail:''};
    if (substr(trim(text), 0, 1) == '{') {
        let data = object(text);
        if (!data)
            return {reason:'invalid_vpn_link', detail:''};
        if (type(data.containers) != 'array') {
            if ((data.api_config != null || data.auth_data != null || data.api_key != null) &&
                data.config == null && data.client_priv_key == null && data.private_key == null)
                return {reason:'cloud_api_key', detail:''};
        } else if (length(data.containers) > 0) {
            let unsupported = [], has_supported = false;
            let supported = [
                'amnezia-awg', 'amnezia-awg2', 'amnezia-awg3', 'amnezia-awg-v2', 'amnezia-awg-v3',
                'amnezia-awg1.5', 'amnezia-awg3.1', 'awg', 'awg2', 'awg3',
                'amnezia-wireguard', 'wireguard', 'wg',
                'amnezia-xray', 'xray', 'xray-reality', 'amnezia-ssxray', 'ssxray',
                'amnezia-shadowsocks', 'shadowsocks', 'amnezia-ss', 'ss'
            ];
            for (let c in data.containers) {
                if (type(c) != 'object' || type(c.container) != 'string') continue;
                let cname = trim(c.container);
                let lcname = lc(cname);
                if (index(supported, lcname) >= 0)
                    has_supported = true;
                else if (lcname != 'amnezia-dns' && cname != '')
                    push(unsupported, cname);
            }
            if (!has_supported && length(unsupported) > 0)
                return {reason:'unsupported_container', detail:join(', ', unsupported)};
            if (has_supported)
                return {reason:'incomplete_container', detail:''};
        }
    }
    return {reason:'invalid_vpn_link', detail:''};
}
return {decode, decompress, diagnose};
