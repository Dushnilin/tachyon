// WG/AWG .conf and bounded Amnezia containers carried by vpn://.
let common = require('core.common');
let amnezia = require('subscription.amnezia');
let core_ip = require('core.ip');
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
    let addresses = core_ip.normalize_to_cidrs(list(v.address));
    if (!private_key || !public_key || !length(addresses) ||
        host == '' || match(host, /[ \t\r\n]/) || port < 1 || port > 65535) return null;
    let peer = {address:host, port, public_key,
        allowed_ips:v.allowed_ips ? core_ip.normalize_to_cidrs(list(v.allowed_ips)) : ['0.0.0.0/0', '::/0']};
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
// Parse a .conf into one endpoint per [Peer]: several servers in one file
// become several endpoints, so each peer can join a urltest pool separately.
// Fails closed as a whole — one bad peer rejects the file, like the old
// single-peer parser did.
function from_conf_endpoints(text, raw, name) {
    if (length(text) > 65536 || index(text, '\u0000') >= 0) return [];
    let interface = {}, peers = [], current = null;
    for (let line in split(text, '\n')) {
        line = trim(line);
        if (substr(line, 0, 1) == '#') {
            if (!name) name = trim(substr(line, 1));
            continue;
        }
        let lower_line = lc(line);
        if (lower_line == '[interface]') { current = interface; continue; }
        if (lower_line == '[peer]') { current = {}; push(peers, current); continue; }
        if (substr(line, 0, 1) == '[') return [];
        let eq = index(line, '=');
        if (eq < 1 || current == null) continue;
        let key = lc(trim(substr(line, 0, eq)));
        // Only data fields are read. PostUp/PreDown and other hooks are ignored.
        current[key] = trim(substr(line, eq + 1));
    }
    if (!length(peers) && (interface.publickey || interface.public_key || interface.peer_public_key) && interface.endpoint)
        push(peers, {});
    if (!length(peers)) return [];
    let endpoints = [];
    for (let i = 0; i < length(peers); i++) {
        let values = {};
        for (let k, v in interface) values[k] = v;
        for (let k, v in peers[i]) values[k] = v;
        let address = as_string(values.endpoint);
        let m = match(address, /^(\[[^]]+\]|[^:]+):([0-9]+)$/);
        if (!m) return [];
        let host = m[1];
        if (substr(host, 0, 1) == '[') host = substr(host, 1, length(host) - 2);
        // The second and later peers get a numbered display name so several
        // servers of one file stay distinguishable in the dashboard.
        let peer_name = i == 0 ? name : sprintf('%s (%d)', name || 'WireGuard', i + 1);
        let endpoint = build(values, host, int(m[2], 10), peer_name, raw);
        if (endpoint == null) return [];
        push(endpoints, endpoint);
    }
    return endpoints;
}
function from_conf(text, raw, name) {
    let endpoints = from_conf_endpoints(text, raw, name);
    return length(endpoints) ? endpoints[0] : null;
}
function from_vpn_endpoints(raw) {
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
    let endpoints = from_conf_endpoints(decoded.text, raw, decoded.name);
    if (!length(endpoints)) return null;
    // An AWG export without obfuscation fields must not silently become WG.
    if (decoded.awg && !has_awg(endpoints[0])) return null;
    return endpoints;
}
function from_vpn(raw) {
    let endpoints = from_vpn_endpoints(raw);
    return endpoints != null ? endpoints[0] : null;
}
return {from_vpn, from_vpn_endpoints, from_conf, from_conf_endpoints, has_awg, awg_fields:[...numbers, ...ranges, ...strings, ...flags]};
