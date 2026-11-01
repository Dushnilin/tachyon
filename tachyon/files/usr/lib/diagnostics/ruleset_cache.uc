// Prefer the committed core cache; explicitly identify a current-source fallback.
// Walking the live bbolt tree matters: scanning every leaf can return a deleted
// page containing a previous version of the same remote rule-set.
let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");

function iso_timestamp(value) {
    let parts = match(value || "", /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.[0-9]+)?Z$/);
    if (!parts)
        return null;
    let year = int(parts[1], 10);
    let days = 365 * (year - 1970) + int((year - 1) / 4) - 492 -
        int((year - 1) / 100) + 19 + int((year - 1) / 400) - 4;
    let months = [31, (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28,
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    for (let i = 1; i < int(parts[2], 10); i++)
        days += months[i - 1];
    return ((days + int(parts[3], 10) - 1) * 24 + int(parts[4], 10)) * 3600 +
        int(parts[5], 10) * 60 + int(parts[6], 10);
}

function request_provider(config, tag, folder) {
    let api = config?.experimental?.clash_api;
    let address = api?.external_controller || "";
    if (address == "")
        return null;
    address = replace(address, /^0\.0\.0\.0:/, "127.0.0.1:");
    address = replace(address, /^\[::\]:/, "[::1]:");
    let request = folder + "/request";
    let content = "silent\n";
    if (api.secret)
        content += "header = " + sprintf("%J", "Authorization: Bearer " + api.secret) + "\n";
    if (fs.writefile(request, content) == null)
        die("cannot prepare core API request");
    let result = exec.run({ argv: ["curl", "--config", request, "--fail", "--noproxy", "*",
        "--max-time", "3", "--url", "http://" + address + "/providers/rules/" + tag], timeout: 5 });
    fs.unlink(request);
    if (result.status != 0)
        die("cannot verify the loaded rule-set revision");
    try { return json(result.output); }
    catch (e) { die("invalid rule-set provider response"); }
}

function current_payload(config, selected, cached) {
    let folder = trim(exec.run({ argv: ["mktemp", "-d", "/tmp/tachyon-trace.XXXXXX"], timeout: 3 }).output || "");
    if (folder == "")
        die("cannot create rule-set diagnostic workspace");
    try {
        let provider = request_provider(config, selected.tag, folder);
        let updated = iso_timestamp(provider?.updatedAt);
        if (provider != null && updated == null)
            die("core API did not report the loaded rule-set timestamp");
        // A 304 after a manual API refresh can touch an older payload's date.
        // A timestamp newer than the live provider does not validate its content.
        if (cached != null && (updated == null || cached.updated == updated)) {
            if (updated == null)
                warn("Loaded rule-set revision could not be verified against the core API.\n");
            fs.rmdir(folder);
            return cached.data;
        }
        // Native cores can refresh the live provider without persisting its new
        // payload in cache.db. Do not silently match the old disk snapshot.
        let result = exec.run({ argv: ["curl", "--fail", "--silent", "--show-error", "--location",
            "--proto", "=http,https", "--proto-redir", "=http,https", "--noproxy", "*",
            "--connect-timeout", "3", "--max-time", "15", "--max-filesize", "134217728",
            "--remote-time", "--dump-header", folder + "/headers", "--output", folder + "/payload",
            "--url", selected.url], timeout: 20 });
        if (result.status != 0)
            die("loaded cache is unavailable or stale, and the remote source could not be read");
        let headers = "";
        for (let block in split(fs.readfile(folder + "/headers") || "", "\r\n\r\n"))
            if (substr(block, 0, 5) == "HTTP/")
                headers = block;
        if (updated != null && match(headers, /\nlast-modified:/i) && fs.stat(folder + "/payload").mtime > updated)
            die("remote list is newer than the loaded provider; update lists before tracing");
        let data = fs.readfile(folder + "/payload");
        if (data == null || length(data) == 0)
            die("empty remote rule-set response");
        warn("The loaded rule-set snapshot is unavailable. Checked the current remote source; it may differ from the active version.\n");
        fs.unlink(folder + "/headers");
        fs.unlink(folder + "/payload");
        fs.rmdir(folder);
        return data;
    }
    catch (e) {
        for (let name in ["request", "headers", "payload"])
            fs.unlink(folder + "/" + name);
        fs.rmdir(folder);
        die(e);
    }
}

function uint_le(data, offset, size) {
    if (offset < 0 || offset + size > length(data))
        die("truncated cache record");
    let value = 0;
    for (let i = size - 1; i >= 0; i--)
        value = value * 256 + ord(data, offset + i);
    return value;
}

function read_at(file, offset, size) {
    file.seek(offset);
    let data = file.read(size);
    if (data == null || length(data) != size)
        die("truncated cache page");
    return data;
}

function read_meta(file, offset, size) {
    let data = read_at(file, offset, 80);
    if (uint_le(data, 8, 2) != 4 || uint_le(data, 16, 4) != 0xed0cdaed ||
        uint_le(data, 20, 4) != 2)
        return null;
    // bbolt metadata uses FNV-1a over the 56 bytes preceding its checksum.
    let high = 0xcbf29ce4;
    let low = 0x84222325;
    for (let i = 16; i < 72; i++) {
        low = (low ^ ord(data, i)) & 0xffffffff;
        let product = low * 435;
        high = (high * 435 + low * 256 + int(product / 4294967296)) % 4294967296;
        low = product % 4294967296;
    }
    if (uint_le(data, 72, 4) != low || uint_le(data, 76, 4) != high)
        return null;
    let page_size = uint_le(data, 24, 4);
    let root = uint_le(data, 32, 8);
    let pages = uint_le(data, 56, 8);
    if (page_size < 1024 || page_size > 65536 || (page_size & (page_size - 1)) ||
        root < 2 || root >= pages || pages * page_size > size)
        return null;
    return { data, page_size, root, pages, txid: uint_le(data, 64, 8) };
}

function read_page(ctx, id) {
    if (id < 2 || id >= ctx.meta.pages)
        die("invalid cache page id");
    let offset = id * ctx.meta.page_size;
    let header = read_at(ctx.file, offset, 16);
    let pages = 1 + uint_le(header, 12, 4);
    if (id + pages > ctx.meta.pages || pages * ctx.meta.page_size > 134217728)
        die("invalid cache overflow page");
    return header + read_at(ctx.file, offset + 16, pages * ctx.meta.page_size - 16);
}

function lookup(ctx, id, key, inline_page) {
    let seen = {};
    for (let depth = 0; depth < 32; depth++) {
        if (inline_page == null && seen[id])
            die("cyclic cache tree");
        seen[id] = true;
        let page = inline_page != null ? inline_page : read_page(ctx, id);
        inline_page = null;
        let flags = uint_le(page, 8, 2);
        let count = uint_le(page, 10, 2);
        if ((flags != 1 && flags != 2) || 16 + count * 16 > length(page))
            die("invalid cache tree page");
        let child = null;
        for (let i = 0; i < count; i++) {
            let element = 16 + i * 16;
            let pos = element + uint_le(page, element + (flags == 2 ? 4 : 0), 4);
            let size = uint_le(page, element + (flags == 2 ? 8 : 4), 4);
            if (pos < 16 + count * 16 || pos + size > length(page))
                die("invalid cache key bounds");
            let candidate = substr(page, pos, size);
            if (flags == 1) {
                if (candidate > key && child != null)
                    break;
                child = uint_le(page, element + 8, 8);
            }
            else if (candidate == key) {
                let value_size = uint_le(page, element + 12, 4);
                if (pos + size + value_size > length(page))
                    die("invalid cache value bounds");
                return { flags: uint_le(page, element, 4), value: substr(page, pos + size, value_size) };
            }
        }
        if (flags == 2 || child == null)
            return null;
        id = child;
    }
    die("cache tree is too deep");
}

function cached_payload(path, tag) {
    // Retry if an ordinary bbolt commit changes the metadata during the read.
    for (let attempt = 0; attempt < 3; attempt++) {
        let file = fs.open(path, "r");
        if (!file)
            die("core rule-set cache is unavailable");
        try {
            let stat = fs.stat(path);
            let before_first = read_at(file, 0, 80);
            let first = read_meta(file, 0, stat.size);
            let page_size = first != null ? first.page_size : 4096;
            let before_second = read_at(file, page_size, 80);
            let second = read_meta(file, page_size, stat.size);
            let meta = second != null && (first == null || second.txid > first.txid) ? second : first;
            if (meta == null)
                die("invalid core cache metadata");
            let ctx = { file, meta };
            let bucket = lookup(ctx, meta.root, "rule_set", null);
            if (bucket == null || !(bucket.flags & 1) || length(bucket.value) < 16)
                die("core rule-set bucket is unavailable");
            let root = uint_le(bucket.value, 0, 8);
            let record = lookup(ctx, root, tag, root == 0 ? substr(bucket.value, 16) : null);
            let unchanged = read_at(file, 0, 80) == before_first &&
                read_at(file, page_size, 80) == before_second;
            let current = fs.stat(path);
            unchanged = unchanged && current != null && current.ino == stat.ino;
            file.close();
            if (!unchanged)
                continue;
            if (record == null || record.flags != 0)
                die("rule-set is not in the committed core cache");
            let value = record.value;
            if (length(value) < 2 || (ord(value, 0) != 1 && ord(value, 0) != 2))
                die("unsupported cached rule-set version");
            let size = 0;
            let offset = 1;
            let multiplier = 1;
            while (true) {
                if (offset >= length(value) || offset > 5)
                    die("invalid cached rule-set length");
                let byte = ord(value, offset++);
                size += (byte & 127) * multiplier;
                if (!(byte & 128))
                    break;
                multiplier *= 128;
            }
            if (size < 1 || size > 134217728 || offset + size > length(value))
                die("invalid cached rule-set payload");
            let updated = 0;
            if (offset + size + 8 <= length(value))
                for (let i = 0; i < 8; i++)
                    updated = updated * 256 + ord(value, offset + size + i);
            return { data: substr(value, offset, size), updated };
        }
        catch (e) {
            file.close();
            die(e);
        }
    }
    die("core cache changed while reading; retry the trace");
}

function extract(reference) {
    let config = common.read_json_file(common.singbox_config_path());
    let selected = null;
    for (let item in common.array_or_empty(config?.route?.rule_set)) {
        if (item.tag == reference || item.url == reference || item.path == reference) {
            selected = item;
            break;
        }
    }
    if (selected == null || !match(selected.tag || "", /^[A-Za-z0-9_-]+$/))
        die("rule-set is not in the generated core configuration");
    if (selected.type == "local") {
        if (fs.stat(selected.path)?.type != "file")
            die("configured rule-set file is unavailable");
        return selected.path;
    }
    if (selected.type != "remote")
        die("unsupported rule-set type");
    let cache = config?.experimental?.cache_file;
    let cached = null;
    if (cache?.enabled == true && cache.path) {
        try { cached = cached_payload(cache.path, selected.tag); }
        catch (e) {
            if (!config?.experimental?.clash_api?.external_controller)
                die(e);
        }
    }
    else if (!config?.experimental?.clash_api?.external_controller)
        die("core rule-set caching is disabled");
    let payload = current_payload(config, selected, cached);
    let folder = getenv("TMP_RULESET_FOLDER") || "/tmp/tachyon-core/rulesets";
    if (!common.ensure_dir(folder))
        die("cannot create rule-set diagnostic directory");
    let path = folder + "/trace-" + selected.tag + (selected.format == "source" ? ".json" : ".srs");
    let stamp = clock();
    let temporary = sprintf("%s.%d.%d.tmp", path, stamp[0], stamp[1]);
    if (fs.writefile(temporary, payload) != length(payload) || !fs.rename(temporary, path)) {
        fs.unlink(temporary);
        die("cannot write rule-set diagnostic snapshot");
    }
    return path;
}

return { extract };
