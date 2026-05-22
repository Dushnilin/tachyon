#!/usr/bin/env lua

local jsonc_ok, jsonc = pcall(require, "luci.jsonc")
local nixio_ok, nixio = pcall(require, "nixio")

local JSON_ARRAY_MT = { __jsontype = "array" }

local function json_array(value)
    return setmetatable(value or {}, JSON_ARRAY_MT)
end

local function is_json_array(value)
    return type(value) == "table" and getmetatable(value) == JSON_ARRAY_MT
end

local function json_escape(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
    value = value:gsub("\"", "\\\"")
    value = value:gsub("\b", "\\b")
    value = value:gsub("\f", "\\f")
    value = value:gsub("\n", "\\n")
    value = value:gsub("\r", "\\r")
    value = value:gsub("\t", "\\t")
    value = value:gsub("[%z\1-\31]", function(char)
        return string.format("\\u%04x", char:byte())
    end)
    return value
end

local function table_is_array(value)
    if is_json_array(value) then
        return true
    end

    local max = 0
    local count = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        if key > max then
            max = key
        end
        count = count + 1
    end

    return count > 0 and max == count
end

local function json_encode(value)
    local value_type = type(value)
    if value == nil then
        return "null"
    elseif value_type == "string" then
        return "\"" .. json_escape(value) .. "\""
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type ~= "table" then
        return "null"
    end

    if table_is_array(value) then
        local parts = {}
        for index = 1, #value do
            parts[#parts + 1] = json_encode(value[index])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key, _ in pairs(value) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = "\"" .. json_escape(key) .. "\":" .. json_encode(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function read_file(path)
    if not path or path == "" or path == "-" then
        return nil
    end

    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, data)
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end

local function json_decode_text(text)
    if not text or text == "" then
        return nil
    end

    if jsonc_ok then
        return jsonc.parse(text)
    end

    return nil
end

local function read_json(path)
    return json_decode_text(read_file(path))
end

local function is_array(value)
    return type(value) == "table" and table_is_array(value)
end

local function has_string_key(value)
    if type(value) ~= "table" then
        return false
    end

    for key, _ in pairs(value) do
        if type(key) == "string" then
            return true
        end
    end
    return false
end

local function object_or_empty(value)
    if type(value) ~= "table" then
        return {}
    end
    if is_array(value) and not has_string_key(value) then
        return {}
    end
    return value
end

local function array_or_empty(value)
    if type(value) ~= "table" then
        return json_array()
    end
    if is_array(value) then
        return value
    end
    return json_array()
end

local function object_key_count(value)
    if type(value) ~= "table" then
        return 0
    end

    local count = 0
    for key, _ in pairs(value) do
        if type(key) == "string" then
            count = count + 1
        end
    end
    return count
end

local function valid_metadata_object(value)
    return type(value) == "table" and object_key_count(value) > 1
end

local function safe_section(section)
    return type(section) == "string" and section:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function cache_path(cache_dir, section)
    return cache_dir .. "/" .. section .. ".json"
end

local function load_cache(cache_dir, section)
    local parsed = read_json(cache_path(cache_dir, section))
    if type(parsed) == "table" and not is_array(parsed) then
        return parsed
    end
    return {}
end

local function normalize_cache(cache, section, format_version)
    cache.version = tonumber(format_version) or format_version
    cache.section = section
    cache.links = object_or_empty(cache.links)
    cache.linkRefs = object_or_empty(cache.linkRefs)
    cache.outboundMetadata = object_or_empty(cache.outboundMetadata)
    cache.outboundMetadata.names = object_or_empty(cache.outboundMetadata.names)
    cache.outboundMetadata.countries = object_or_empty(cache.outboundMetadata.countries)
    cache.servers = object_or_empty(cache.servers)
    cache.subscriptionMetadata = array_or_empty(cache.subscriptionMetadata)
    return cache
end

local function save_cache(cache_dir, section, format_version, cache)
    normalize_cache(cache, section, format_version)

    local path = cache_path(cache_dir, section)
    local tmp_path = path .. "." .. tostring(os.time()) .. "." .. tostring(math.random(1000000)) .. ".tmp"
    write_file(tmp_path, json_encode(cache) .. "\n")
    assert(os.rename(tmp_path, path))
end

local function write_link_cache(cache_dir, format_version, section, links_path, link_refs_path)
    local cache = load_cache(cache_dir, section)
    cache.links = object_or_empty(read_json(links_path))
    cache.linkRefs = object_or_empty(read_json(link_refs_path))
    save_cache(cache_dir, section, format_version, cache)
end

local function write_outbound_metadata(cache_dir, format_version, section, names_path, countries_path, servers_path)
    local cache = load_cache(cache_dir, section)
    cache.outboundMetadata = {
        names = object_or_empty(read_json(names_path)),
        countries = object_or_empty(read_json(countries_path))
    }
    cache.servers = object_or_empty(read_json(servers_path))
    save_cache(cache_dir, section, format_version, cache)
end

local function metadata_array_from_file(metadata_path)
    local metadata = read_json(metadata_path)
    local result = json_array()

    if is_array(metadata) then
        for _, item in ipairs(metadata) do
            if valid_metadata_object(item) then
                result[#result + 1] = item
            end
        end
    elseif valid_metadata_object(metadata) then
        result[#result + 1] = metadata
    end

    return result
end

local function write_subscription_metadata(cache_dir, format_version, section, metadata_path)
    local cache = load_cache(cache_dir, section)
    cache.subscriptionMetadata = metadata_array_from_file(metadata_path)
    save_cache(cache_dir, section, format_version, cache)
end

local function read_metadata_items_from_cache(cache_dir, section, legacy_path)
    local cache = load_cache(cache_dir, section)
    local metadata = cache.subscriptionMetadata

    if type(metadata) ~= "table" then
        metadata = read_json(legacy_path)
    end

    local result = json_array()
    if is_array(metadata) then
        for _, item in ipairs(metadata) do
            if valid_metadata_object(item) then
                result[#result + 1] = item
            end
        end
    elseif valid_metadata_object(metadata) then
        result[#result + 1] = metadata
    end

    return result
end

local function metadata_source_index(item)
    return tonumber(item.sourceIndex or item.source_index)
end

local function metadata_source_section(item)
    return tostring(item.sourceSection or item.source_section or "")
end

local function metadata_items_have_source_markers(items)
    for _, item in ipairs(items) do
        if metadata_source_index(item) ~= nil or metadata_source_section(item) ~= "" then
            return true
        end
    end
    return false
end

local function metadata_matches_source(item, source_index, source_section, has_source_markers)
    if has_source_markers then
        local item_section = metadata_source_section(item)
        local item_index = metadata_source_index(item)
        return (item_section ~= "" and item_section == source_section) or
            (item_section == "" and item_index == source_index)
    end
    return false
end

local function attach_source_metadata(item, source_index, source_section)
    item.sourceIndex = source_index
    item.sourceSection = source_section
    return item
end

local function append_metadata_file(array_path, metadata_path, source_index, source_section)
    if not array_path or array_path == "" then
        return
    end

    local array = array_or_empty(read_json(array_path))
    local metadata = read_json(metadata_path)
    source_index = tonumber(source_index) or 0
    source_section = tostring(source_section or "")

    if valid_metadata_object(metadata) then
        array[#array + 1] = attach_source_metadata(metadata, source_index, source_section)
        write_file(array_path, json_encode(array) .. "\n")
    end
end

local function append_cached_metadata(array_path, cache_dir, section, legacy_path, source_index, source_section)
    if not array_path or array_path == "" then
        return
    end

    local array = array_or_empty(read_json(array_path))
    local items = read_metadata_items_from_cache(cache_dir, section, legacy_path)
    source_index = tonumber(source_index) or 0
    source_section = tostring(source_section or "")

    local has_source_markers = metadata_items_have_source_markers(items)
    local selected = nil
    if has_source_markers then
        for _, item in ipairs(items) do
            if metadata_matches_source(item, source_index, source_section, true) then
                selected = item
                break
            end
        end
    else
        selected = items[source_index]
    end

    if valid_metadata_object(selected) then
        array[#array + 1] = attach_source_metadata(selected, source_index, source_section)
        write_file(array_path, json_encode(array) .. "\n")
    end
end

local function write_source_metadata(cache_dir, format_version, section, source_index, source_section, metadata_path, legacy_path)
    local cache = load_cache(cache_dir, section)
    local items = read_metadata_items_from_cache(cache_dir, section, legacy_path)
    local kept = json_array()
    local has_source_markers = metadata_items_have_source_markers(items)
    source_index = tonumber(source_index) or 0
    source_section = tostring(source_section or "")

    for index, item in ipairs(items) do
        local keep
        if has_source_markers then
            keep = not metadata_matches_source(item, source_index, source_section, true)
        else
            keep = index ~= source_index
        end
        if keep and valid_metadata_object(item) then
            kept[#kept + 1] = item
        end
    end

    local metadata = read_json(metadata_path)
    if valid_metadata_object(metadata) then
        kept[#kept + 1] = attach_source_metadata(metadata, source_index, source_section)
    end

    table.sort(kept, function(first, second)
        return (metadata_source_index(first) or 999999) < (metadata_source_index(second) or 999999)
    end)

    cache.subscriptionMetadata = kept
    save_cache(cache_dir, section, format_version, cache)
end

local function starts_with(value, prefix)
    return value:sub(1, #prefix) == prefix
end

local function uri_encode(value)
    return tostring(value or ""):gsub("([^A-Za-z0-9%-%._~])", function(char)
        return string.format("%%%02X", char:byte())
    end)
end

local function base64_encode(value)
    if nixio_ok and nixio.bin and nixio.bin.b64encode then
        return (nixio.bin.b64encode(tostring(value or "")):gsub("=+$", ""))
    end
    return ""
end

local function host_port(server, port)
    server = tostring(server or "")
    if server:find(":", 1, true) and not starts_with(server, "[") then
        server = "[" .. server .. "]"
    end
    return server .. ":" .. tostring(port or "")
end

local function add_query(params, key, value)
    value = tostring(value or "")
    if value ~= "" then
        params[#params + 1] = uri_encode(key) .. "=" .. uri_encode(value)
    end
end

local function add_tls_query(params, outbound, trojan_default_tls)
    local tls = type(outbound.tls) == "table" and outbound.tls or nil
    if not tls or tls.enabled == false then
        if trojan_default_tls then
            add_query(params, "security", "tls")
        end
        return
    end

    local reality = type(tls.reality) == "table" and tls.reality or nil
    if reality and reality.enabled ~= false then
        add_query(params, "security", "reality")
        add_query(params, "pbk", reality.public_key)
        add_query(params, "sid", reality.short_id)
    else
        add_query(params, "security", "tls")
    end

    add_query(params, "sni", tls.server_name)
    if tls.insecure == true then
        add_query(params, "allowInsecure", "1")
    end
    if type(tls.utls) == "table" and tls.utls.enabled ~= false then
        add_query(params, "fp", tls.utls.fingerprint)
    end
    if type(tls.alpn) == "table" and #tls.alpn > 0 then
        add_query(params, "alpn", table.concat(tls.alpn, ","))
    end
end

local function add_transport_query(params, outbound)
    local transport = type(outbound.transport) == "table" and outbound.transport or nil
    if not transport then
        add_query(params, "type", "tcp")
        return
    end

    local transport_type = tostring(transport.type or "")
    add_query(params, "type", transport_type ~= "" and transport_type or "tcp")

    if transport_type == "ws" then
        add_query(params, "path", transport.path)
        if type(transport.headers) == "table" then
            add_query(params, "host", transport.headers.Host or transport.headers.host)
        end
    elseif transport_type == "grpc" then
        add_query(params, "serviceName", transport.service_name)
    elseif transport_type == "http" then
        add_query(params, "path", transport.path)
        if type(transport.host) == "table" and #transport.host > 0 then
            add_query(params, "host", table.concat(transport.host, ","))
        else
            add_query(params, "host", transport.host)
        end
    elseif transport_type == "xhttp" then
        add_query(params, "path", transport.path)
        add_query(params, "host", transport.host)
        add_query(params, "mode", transport.mode)
    end
end

local function query_string(params)
    if #params == 0 then
        return ""
    end
    return "?" .. table.concat(params, "&")
end

local function fragment(outbound)
    local tag = tostring(outbound.tag or "")
    if tag == "" then
        return ""
    end
    return "#" .. uri_encode(tag)
end

local function serialize_vless(outbound)
    if tostring(outbound.uuid or "") == "" or tostring(outbound.server or "") == "" or not outbound.server_port then
        return ""
    end

    local params = {}
    add_tls_query(params, outbound, false)
    add_transport_query(params, outbound)
    add_query(params, "flow", outbound.flow)
    add_query(params, "packetEncoding", outbound.packet_encoding)

    return "vless://" .. uri_encode(outbound.uuid) .. "@" ..
        host_port(outbound.server, outbound.server_port) .. query_string(params) .. fragment(outbound)
end

local function serialize_trojan(outbound)
    if tostring(outbound.password or "") == "" or tostring(outbound.server or "") == "" or not outbound.server_port then
        return ""
    end

    local params = {}
    add_tls_query(params, outbound, true)
    add_transport_query(params, outbound)

    return "trojan://" .. uri_encode(outbound.password) .. "@" ..
        host_port(outbound.server, outbound.server_port) .. query_string(params) .. fragment(outbound)
end

local function serialize_shadowsocks(outbound)
    if tostring(outbound.method or "") == "" or tostring(outbound.password or "") == "" or
        tostring(outbound.server or "") == "" or not outbound.server_port then
        return ""
    end

    local userinfo = base64_encode(tostring(outbound.method) .. ":" .. tostring(outbound.password))
    if userinfo == "" then
        return ""
    end

    return "ss://" .. userinfo .. "@" .. host_port(outbound.server, outbound.server_port) .. fragment(outbound)
end

local function serialize_socks(outbound)
    if tostring(outbound.server or "") == "" or not outbound.server_port then
        return ""
    end

    local scheme = "socks" .. tostring(outbound.version or "5")
    local auth = ""
    if tostring(outbound.username or "") ~= "" then
        auth = uri_encode(outbound.username)
        if tostring(outbound.password or "") ~= "" then
            auth = auth .. ":" .. uri_encode(outbound.password)
        end
        auth = auth .. "@"
    end

    return scheme .. "://" .. auth .. host_port(outbound.server, outbound.server_port) .. fragment(outbound)
end

local function serialize_hysteria2(outbound)
    if tostring(outbound.password or "") == "" or tostring(outbound.server or "") == "" or not outbound.server_port then
        return ""
    end

    local params = {}
    local tls = type(outbound.tls) == "table" and outbound.tls or nil
    if tls then
        add_query(params, "sni", tls.server_name)
        if tls.insecure == true then
            add_query(params, "insecure", "1")
        end
        if type(tls.alpn) == "table" and #tls.alpn > 0 then
            add_query(params, "alpn", table.concat(tls.alpn, ","))
        end
    end
    if type(outbound.obfs) == "table" then
        add_query(params, "obfs", outbound.obfs.type)
        add_query(params, "obfs-password", outbound.obfs.password)
    end

    return "hysteria2://" .. uri_encode(outbound.password) .. "@" ..
        host_port(outbound.server, outbound.server_port) .. query_string(params) .. fragment(outbound)
end

local function serialize_vmess(outbound)
    if tostring(outbound.uuid or "") == "" or tostring(outbound.server or "") == "" or not outbound.server_port then
        return ""
    end

    local vmess = {
        v = "2",
        ps = tostring(outbound.tag or ""),
        add = tostring(outbound.server or ""),
        port = tostring(outbound.server_port or ""),
        id = tostring(outbound.uuid or ""),
        aid = tostring(outbound.alter_id or 0),
        scy = tostring(outbound.security or "auto"),
        net = "tcp",
        type = "none",
        host = "",
        path = "",
        tls = "",
        sni = ""
    }

    if type(outbound.tls) == "table" and outbound.tls.enabled ~= false then
        vmess.tls = "tls"
        vmess.sni = tostring(outbound.tls.server_name or "")
        if type(outbound.tls.utls) == "table" then
            vmess.fp = tostring(outbound.tls.utls.fingerprint or "")
        end
    end

    if type(outbound.transport) == "table" then
        vmess.net = tostring(outbound.transport.type or "tcp")
        if vmess.net == "ws" then
            vmess.path = tostring(outbound.transport.path or "")
            if type(outbound.transport.headers) == "table" then
                vmess.host = tostring(outbound.transport.headers.Host or outbound.transport.headers.host or "")
            end
        elseif vmess.net == "grpc" then
            vmess.path = tostring(outbound.transport.service_name or "")
        elseif vmess.net == "http" then
            vmess.path = tostring(outbound.transport.path or "")
            if type(outbound.transport.host) == "table" and #outbound.transport.host > 0 then
                vmess.host = table.concat(outbound.transport.host, ",")
            else
                vmess.host = tostring(outbound.transport.host or "")
            end
        end
    end

    local encoded = base64_encode(json_encode(vmess))
    if encoded == "" then
        return ""
    end
    return "vmess://" .. encoded
end

local function serialize_outbound_link(outbound)
    if type(outbound) ~= "table" then
        return ""
    end

    local outbound_type = tostring(outbound.type or "")
    if outbound_type == "vless" then
        return serialize_vless(outbound)
    elseif outbound_type == "trojan" then
        return serialize_trojan(outbound)
    elseif outbound_type == "shadowsocks" then
        return serialize_shadowsocks(outbound)
    elseif outbound_type == "socks" then
        return serialize_socks(outbound)
    elseif outbound_type == "hysteria2" then
        return serialize_hysteria2(outbound)
    elseif outbound_type == "vmess" then
        return serialize_vmess(outbound)
    end

    return ""
end

local function is_copyable_link(value)
    value = tostring(value or ""):lower()
    local prefixes = {
        "vless://", "vmess://", "trojan://", "ss://", "ssr://",
        "hysteria2://", "hy2://", "tuic://",
        "socks4://", "socks4a://", "socks5://"
    }
    for _, prefix in ipairs(prefixes) do
        if starts_with(value, prefix) then
            return true
        end
    end
    return false
end

local function get_source_link(subscription_dir, ref)
    if type(ref) ~= "table" then
        return ""
    end

    local source_section = tostring(ref.sourceSection or ref.source_section or "")
    local source_index = tonumber(ref.sourceIndex or ref.source_index)
    if not safe_section(source_section) or not source_index or source_index < 1 then
        return ""
    end

    local source = read_json(subscription_dir .. "/" .. source_section .. ".json")
    if type(source) ~= "table" or type(source.outbounds) ~= "table" then
        return ""
    end

    local outbound = source.outbounds[source_index]
    if type(outbound) ~= "table" then
        return ""
    end

    local link = tostring(outbound.share_link or "")
    if link == "" then
        link = serialize_outbound_link(outbound)
    end
    if is_copyable_link(link) then
        return link
    end
    return ""
end

local function get_link(cache_dir, subscription_dir, section, tag, legacy_links_dir)
    local cache = load_cache(cache_dir, section)
    local links = object_or_empty(cache.links)
    local link_refs = object_or_empty(cache.linkRefs)
    local link = tostring(links[tag] or "")

    if not is_copyable_link(link) then
        link = get_source_link(subscription_dir, link_refs[tag])
    end

    if not is_copyable_link(link) and legacy_links_dir and legacy_links_dir ~= "" then
        local legacy = object_or_empty(read_json(legacy_links_dir .. "/" .. section .. ".json"))
        link = tostring(legacy[tag] or "")
    end

    if not is_copyable_link(link) then
        link = ""
    end

    print(json_encode({ link = link }))
end

local function get_link_states(cache_dir, section, legacy_links_dir)
    local cache = load_cache(cache_dir, section)
    local result = {}

    for tag, link in pairs(object_or_empty(cache.links)) do
        result[tag] = is_copyable_link(link)
    end
    for tag, _ in pairs(object_or_empty(cache.linkRefs)) do
        result[tag] = true
    end

    if next(result) == nil and legacy_links_dir and legacy_links_dir ~= "" then
        local legacy = object_or_empty(read_json(legacy_links_dir .. "/" .. section .. ".json"))
        for tag, link in pairs(legacy) do
            result[tag] = is_copyable_link(link)
        end
    end

    print(json_encode(result))
end

local function get_outbound_metadata(cache_dir, section, legacy_path)
    local cache = load_cache(cache_dir, section)
    local metadata = cache.outboundMetadata

    if type(metadata) ~= "table" then
        metadata = read_json(legacy_path)
    end
    metadata = object_or_empty(metadata)

    print(json_encode({
        names = object_or_empty(metadata.names),
        countries = object_or_empty(metadata.countries)
    }))
end

local function get_subscription_metadata(cache_dir, section, legacy_path)
    local items = read_metadata_items_from_cache(cache_dir, section, legacy_path)
    if #items > 0 then
        print(json_encode(items))
    else
        print("{}")
    end
end

local mode = arg[1] or ""

if mode == "write-link-cache" then
    local cache_dir, format_version, section = arg[2], arg[3], arg[4]
    if not safe_section(section) then os.exit(1) end
    write_link_cache(cache_dir, format_version, section, arg[5], arg[6])
elseif mode == "write-outbound-metadata" then
    local cache_dir, format_version, section = arg[2], arg[3], arg[4]
    if not safe_section(section) then os.exit(1) end
    write_outbound_metadata(cache_dir, format_version, section, arg[5], arg[6], arg[7])
elseif mode == "write-subscription-metadata" then
    local cache_dir, format_version, section = arg[2], arg[3], arg[4]
    if not safe_section(section) then os.exit(1) end
    write_subscription_metadata(cache_dir, format_version, section, arg[5])
elseif mode == "append-metadata-file" then
    append_metadata_file(arg[2], arg[3], arg[4], arg[5])
elseif mode == "append-cached-metadata" then
    append_cached_metadata(arg[2], arg[3], arg[4], arg[5], arg[6], arg[7])
elseif mode == "write-source-metadata" then
    local cache_dir, format_version, section = arg[2], arg[3], arg[4]
    if not safe_section(section) then os.exit(1) end
    write_source_metadata(cache_dir, format_version, section, arg[5], arg[6], arg[7], arg[8])
elseif mode == "get-link" then
    local cache_dir, subscription_dir, section = arg[2], arg[3], arg[4]
    if not safe_section(section) then
        print("{\"link\":\"\"}")
    else
        get_link(cache_dir, subscription_dir, section, arg[5] or "", arg[6] or "")
    end
elseif mode == "get-link-states" then
    local cache_dir, section = arg[2], arg[3]
    if not safe_section(section) then
        print("{}")
    else
        get_link_states(cache_dir, section, arg[4] or "")
    end
elseif mode == "get-outbound-metadata" then
    local cache_dir, section = arg[2], arg[3]
    if not safe_section(section) then
        print("{\"names\":{},\"countries\":{}}")
    else
        get_outbound_metadata(cache_dir, section, arg[4])
    end
elseif mode == "get-subscription-metadata" then
    local cache_dir, section = arg[2], arg[3]
    if not safe_section(section) then
        print("{}")
    else
        get_subscription_metadata(cache_dir, section, arg[4])
    end
else
    io.stderr:write("Usage: subscription_cache.lua <mode> ...\n")
    os.exit(1)
end
