// WG/AWG .conf and bounded Amnezia containers carried by vpn://.
let common = require('core.common');
let amnezia = require('subscription.amnezia');
let as_string = common.as_string;
let numbers = ['jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4'];
let ranges = ['h1', 'h2', 'h3', 'h4', 'content_padding_addition',
    'rekey_after_time', 'rekey_timeout', 'reject_after_time',
    'keepalive_timeout', 'max_handshake_attempts'];
let strings = ['i1', 'i2', 'i3', 'i4', 'i5', 'header_protection_key'];
let flags = ['random_trailers', 'disable_cookies'];
let aliases = {
    privatekey:'private_key', publickey:'public_key', peer_public_key:'public_key',
    presharedkey:'pre_shared_key', preshared_key:'pre_shared_key', psk:'pre_shared_key',
    local_address:'address', ip:'address', persistentkeepalive:'keepalive',
    persistent_keepalive:'keepalive', persistent_keepalive_interval:'keepalive',
    allowedips:'allowed_ips', headerprotectionkey:'header_protection_key',
    contentpaddingaddition:'content_padding_addition', rekeyaftertime:'rekey_after_time',
    rekeytimeout:'rekey_timeout', rejectaftertime:'reject_after_time',
    keepalivetimeout:'keepalive_timeout', maxhandshakeattempts:'max_handshake_attempts',
    randomtrailers:'random_trailers', disablecookies:'disable_cookies'
};
function fields(values) {
    let result = {};
    for (let k, v in values) {
        k = lc(k);
        result[aliases[k] || k] = trim(as_string(v));
    }
    return result;
}
function key32(value) {
    // The generic URI parser treats '+' as a space; restore it only in keys.
    value = replace(as_string(value), / /g, '+');
    if (!match(value, /^[A-Za-z0-9+\/]{43}=$/)) return null;
    let bytes = null;
    try { bytes = b64dec(value); } catch(e) {}
    return bytes != null && length(bytes) == 32 ? value : null;
}
function range(value) {
    value = trim(as_string(value));
    let m = match(value, /^([0-9]+)(-([0-9]+))?$/);
    if (!m) return null;
    let low = int(m[1], 10), high = m[3] != null ? int(m[3], 10) : low;
    if (low > high || high > 4294967295) return null;
    return m[3] != null ? sprintf('%d-%d', low, high) : low;
}
function list(value) {
    let result = [];
    for (let item in split(as_string(value), /[, \t]+/)) {
        if (item != '') push(result, item);
    }
    return result;
}
function has_awg(endpoint) {
    for (let k in [...numbers, ...ranges, ...strings, ...flags])
        if (endpoint[k] != null) return true;
    let peer = type(endpoint.peers) == 'array' ? endpoint.peers[0] : null;
    return type(peer) == 'object' && type(peer.persistent_keepalive_interval) == 'string' &&
        index(peer.persistent_keepalive_interval, '-') >= 0;
}
function build(input, host, port, name, raw) {
    let v = fields(input);
    let private_key = key32(v.private_key), public_key = key32(v.public_key);
    let addresses = list(v.address);
    if (!private_key || !public_key || !length(addresses) ||
        host == '' || match(host, /[ \t\r\n]/) || port < 1 || port > 65535) return null;
    let peer = {address:host, port, public_key,
        allowed_ips:v.allowed_ips ? list(v.allowed_ips) : ['0.0.0.0/0', '::/0']};
    if (v.pre_shared_key) {
        peer.pre_shared_key = key32(v.pre_shared_key);
        if (!peer.pre_shared_key) return null;
    }
    if (v.keepalive != null && v.keepalive != '') {
        peer.persistent_keepalive_interval = range(v.keepalive);
        if (peer.persistent_keepalive_interval == null) return null;
    }
    let endpoint = {type:'wireguard', private_key, address:addresses, peers:[peer], mtu:1280};
    if (v.mtu != null) {
        if (!match(v.mtu, /^[0-9]+$/)) return null;
        endpoint.mtu = int(v.mtu, 10);
        if (endpoint.mtu < 576 || endpoint.mtu > 65535) return null;
    }
    for (let k in numbers) {
        if (v[k] == null) continue;
        let n = range(v[k]);
        if (type(n) != 'int') return null;
        endpoint[k] = n;
    }
    for (let k in ranges) {
        if (v[k] == null || v[k] == '') continue;
        endpoint[k] = range(v[k]);
        if (endpoint[k] == null) return null;
    }
    for (let k in strings) {
        if (v[k] != null && v[k] != '') endpoint[k] = v[k];
    }
    if (endpoint.header_protection_key != null) {
        endpoint.header_protection_key = key32(endpoint.header_protection_key);
        if (!endpoint.header_protection_key) return null;
    }
    for (let k in flags) {
        if (v[k] == null) continue;
        let value = lc(v[k]);
        if (index(['1','true','on','yes','0','false','off','no'], value) < 0) return null;
        endpoint[k] = index(['1','true','on','yes'], value) >= 0;
    }
    endpoint.tag = name || (has_awg(endpoint) ? 'AmneziaWG' : 'WireGuard');
    endpoint.share_link = raw;
    return endpoint;
}
function from_conf(text, raw, name) {
    if (length(text) > 65536 || index(text, '\u0000') >= 0) return null;
    let values = {}, block = '', peers = 0;
    for (let line in split(text, '\n')) {
        line = trim(line);
        if (substr(line, 0, 1) == '#') {
            if (!name) name = trim(substr(line, 1));
            continue;
        }
        if (line == '[Interface]') { block = 'interface'; continue; }
        if (line == '[Peer]') { block = 'peer'; peers++; continue; }
        if (substr(line, 0, 1) == '[') return null;
        let eq = index(line, '=');
        if (eq < 1 || block == '') continue;
        let key = lc(trim(substr(line, 0, eq)));
        // Only data fields are read. PostUp/PreDown and other hooks are ignored.
        values[key] = trim(substr(line, eq + 1));
    }
    if (peers != 1) return null;
    let address = as_string(values.endpoint);
    let m = match(address, /^(\[[^]]+\]|[^:]+):([0-9]+)$/);
    if (!m) return null;
    let host = m[1];
    if (substr(host, 0, 1) == '[') host = substr(host, 1, length(host) - 2);
    return build(values, host, int(m[2], 10), name, raw);
}
function from_vpn(raw) {
    let payload = split(substr(raw, 6), '#')[0];
    if (length(payload) > 131072) return null;
    payload = replace(payload, /%([0-9A-Fa-f]{2})/g, (all, n) => chr(hex(n)));
    payload = replace(replace(payload, /-/g, '+'), /_/g, '/');
    if (!match(payload, /^[A-Za-z0-9+\/]*={0,2}$/) || length(payload) % 4 == 1) return null;
    while (length(payload) % 4) payload += '=';
    let text = null;
    try { text = b64dec(payload); } catch(e) {}
    if (text == null) return null;
    let decoded = amnezia.decode(text);
    if (!decoded) return null;
    let endpoint = from_conf(decoded.text, raw, decoded.name);
    // An AWG export without obfuscation fields must not silently become WG.
    if (decoded.awg && endpoint && !has_awg(endpoint)) return null;
    return endpoint;
}
return {from_vpn, from_conf, has_awg, awg_fields:[...numbers, ...ranges, ...strings, ...flags]};
