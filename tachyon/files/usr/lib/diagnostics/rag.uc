let fs = require("fs");
let common = require("core.common");

let as_string = common.as_string;
let command_from_args = common.command_from_args;
let rag_index = null;
let rag_embed_cache = null;

let LIB_DIR = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
let INDEX_BUILTIN = LIB_DIR + "/rag_index.json";
let INDEX_CUSTOM = "/etc/tachyon/rag_index.json";
let EMBED_CACHE = "/tmp/tachyon_rag_embeddings.json";

let _sb_mod = null;
function sb_mod() {
    if (_sb_mod == null) {
        try { _sb_mod = require("service.support_bundle"); } catch (e) { _sb_mod = false; }
    }
    return _sb_mod || null;
}

function sanitize_query(query) {
    if (query == null || query == "")
        return "";
    let s = as_string(query);
    let sb = sb_mod();
    if (sb && sb.redact_for_llm)
        s = sb.redact_for_llm(s);
    else if (sb && sb.redact_string)
        s = sb.redact_string(s);
    // Fallback inline redaction so RAG never leaks secrets even if support_bundle is unavailable
    s = replace(s, /[0-9]{8,12}:[-_a-zA-Z0-9]{35}/g, "[REDACTED_TELEGRAM_TOKEN]");
    s = replace(s, /Bearer[ \t]+[-_a-zA-Z0-9.+=]{16,}/gi, "Bearer [REDACTED_TOKEN]");
    s = replace(s, /(sk-(or-v1-|ant-|proj-)?[-_a-zA-Z0-9]{16,}|AIza[-_a-zA-Z0-9]{20,}|gsk_[-_a-zA-Z0-9]{16,}|xai-[-_a-zA-Z0-9]{16,})/g, "[REDACTED_API_KEY]");
    s = replace(s, /(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|fptns?|warp|wireguard|wg|awg):\/\/[^ \t\r\n'"]+/gi, "$1://[REDACTED]");
    s = replace(s, /:\/\/([^:@ \t\r\n]+)(:[^@ \t\r\n]+)?@/g, "://[REDACTED]@");
    s = replace(s, /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/g, "[REDACTED_UUID]");
    s = replace(s, /([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/g, "[REDACTED_MAC]");
    return s;
}

function rag_index_path() {
    if (fs.stat(INDEX_CUSTOM))
        return INDEX_CUSTOM;
    if (fs.stat(INDEX_BUILTIN))
        return INDEX_BUILTIN;
    return "/usr/lib/tachyon/rag_index.json";
}

// Fingerprint of the active index file. Cached embeddings are only valid for
// the exact index they were computed from; without this check a rebuilt index
// with the same chunk count silently serves stale vectors forever.
function index_stamp() {
    let st = fs.stat(rag_index_path());
    if (!st)
        return "missing";
    return sprintf("%d-%d", int(st.st_mtime || 0), int(st.st_size || 0));
}

function load_raw_index() {
    if (rag_index)
        return rag_index;
    let path = rag_index_path();
    let raw = common.read_json_file(path);
    if (!raw || type(raw.chunks) != "array")
        return null;
    rag_index = raw;
    return rag_index;
}

function load_embedding_cache() {
    if (rag_embed_cache)
        return rag_embed_cache;
    let raw = common.read_json_file(EMBED_CACHE);
    if (raw && type(raw.embeddings) == "array" && length(raw.embeddings) > 0) {
        rag_embed_cache = raw;
        return rag_embed_cache;
    }
    return null;
}

function save_embedding_cache(embeddings, model) {
    let data = {
        model: model,
        index_stamp: index_stamp(),
        timestamp: time(),
        embeddings: embeddings
    };
    common.write_json_file(EMBED_CACHE, data);
}

function get_api_url(provider, api_key, custom_url) {
    provider = lc(trim(as_string(provider)));
    if (provider == "openai")
        return "https://api.openai.com/v1/embeddings";
    if (provider == "anthropic" || provider == "claude")
        return null;
    if (provider == "deepseek")
        return "https://api.deepseek.com/v1/embeddings";
    if (provider == "openrouter")
        return "https://openrouter.ai/api/v1/embeddings";
    if (provider == "ollama") {
        if (custom_url != "") {
            let base = replace(custom_url, /\/v1\/chat\/completions\/?$/, "");
            base = replace(base, /\/api\/generate\/?$/, "");
            if (index(base, "/embeddings") >= 0)
                return base;
            return base + "/api/embeddings";
        }
        return "http://192.168.1.100:11434/api/embeddings";
    }
    if (provider == "lmstudio") {
        if (custom_url != "") {
            let base = replace(custom_url, /\/v1\/chat\/completions\/?$/, "");
            if (index(base, "/embeddings") >= 0)
                return base;
            return base + "/v1/embeddings";
        }
        return "http://192.168.1.100:1234/v1/embeddings";
    }
    if (provider == "custom" && custom_url != "") {
        let base = replace(custom_url, /\/v1\/chat\/completions\/?$/, "");
        if (index(base, "/embeddings") >= 0)
            return base;
        return base + "/v1/embeddings";
    }
    return "https://api.openai.com/v1/embeddings";
}

function get_embedding_model(provider, model_override) {
    provider = lc(trim(as_string(provider)));
    model_override = trim(as_string(model_override));
    if (model_override != "" && index(lc(model_override), "embed") >= 0)
        return model_override;
    if (provider == "openai")
        return "text-embedding-3-small";
    if (provider == "deepseek")
        return "deepseek-embedding";
    if (provider == "openrouter")
        return "openai/text-embedding-3-small";
    if (provider == "ollama")
        return "nomic-embed-text";
    if (provider == "lmstudio")
        return "local-model";
    return "text-embedding-3-small";
}

function call_embedding_api(api_url, api_key, model, texts) {
    let payload = {
        model: model,
        input: texts
    };

    let payload_path = "/tmp/rag_embed_payload.json";
    common.write_json_file(payload_path, payload);

    let curl_args = [
        "curl", "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer " + api_key,
        "--connect-timeout", "10",
        "-m", "30",
        "-d", "@" + payload_path,
        api_url
    ];

    let result = common.command_capture(command_from_args(curl_args));
    common.remove_file(payload_path);

    if (result.status != 0 || result.output == "")
        return null;

    let data = null;
    try { data = json(result.output); } catch(e) {}
    if (!data)
        return null;

    if (type(data.data) == "array" && length(data.data) > 0) {
        let embeddings = [];
        for (let i = 0; i < length(data.data); i++)
            push(embeddings, data.data[i].embedding);
        return embeddings;
    }

    if (type(data.embeddings) == "array" && length(data.embeddings) > 0)
        return data.embeddings;

    return null;
}

function sqrt_val(x) {
    if (x <= 0)
        return 0.0;
    return x ** 0.5;
}

function cosine_similarity(a, b) {
    let len = length(a);
    if (len == 0 || length(b) != len)
        return 0;
    let dot = 0, norm_a = 0, norm_b = 0;
    for (let i = 0; i < len; i++) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }
    let denom = sqrt_val(norm_a) * sqrt_val(norm_b);
    if (denom == 0)
        return 0;
    return dot / denom;
}

function ensure_embeddings(index, provider, api_key, custom_url, model_override) {
    let cached = load_embedding_cache();
    let model = get_embedding_model(provider, model_override);
    let stamp = index_stamp();

    if (cached && length(cached.embeddings) == length(index.chunks) &&
        cached.model == model && cached.index_stamp == stamp) {
        for (let i = 0; i < length(index.chunks); i++)
            index.chunks[i].embedding = cached.embeddings[i];
        return true;
    }

    let api_url = get_api_url(provider, api_key, custom_url);
    if (!api_url)
        return false;

    let texts = [];
    for (let i = 0; i < length(index.chunks); i++)
        push(texts, index.chunks[i].text);

    let embeddings = call_embedding_api(api_url, api_key, model, texts);
    if (!embeddings || length(embeddings) != length(texts))
        return false;

    for (let i = 0; i < length(index.chunks); i++)
        index.chunks[i].embedding = embeddings[i];

    save_embedding_cache(embeddings, model);
    return true;
}

function embed_query(query, provider, api_key, custom_url, model_override) {
    query = sanitize_query(query);
    let api_url = get_api_url(provider, api_key, custom_url);
    if (!api_url)
        return null;

    let model = get_embedding_model(provider, model_override);
    let embeddings = call_embedding_api(api_url, api_key, model, [query]);
    if (!embeddings || length(embeddings) == 0)
        return null;

    return embeddings[0];
}

function search(query_embedding, index, top_k) {
    let scored = [];
    for (let i = 0; i < length(index.chunks); i++) {
        let chunk = index.chunks[i];
        if (length(chunk.embedding) == 0)
            continue;
        let score = cosine_similarity(query_embedding, chunk.embedding);
        push(scored, { chunk: chunk, score: score });
    }
    sort(scored, function(a, b) { return b.score - a.score; });
    let limit = top_k || 3;
    if (length(scored) > limit)
        scored = slice(scored, 0, limit);
    return scored;
}

const STOP_WORDS = {
    "the": true, "and": true, "for": true, "with": true, "from": true,
    "this": true, "that": true, "are": true, "was": true, "were": true,
    "have": true, "has": true, "had": true, "not": true, "but": true,
    "you": true, "all": true, "can": true, "her": true, "his": true,
    "one": true, "our": true, "out": true, "who": true, "get": true,
    "how": true, "why": true, "what": true, "when": true, "where": true,
    "into": true, "only": true, "other": true, "some": true, "such": true,
    "than": true, "then": true, "them": true, "they": true, "will": true,
    "check": true, "checks": true, "status": true, "active": true, "passed": true,
    "running": true, "info": true, "warn": true, "true": true, "false": true,
    "null": true, "none": true, "redacted": true, "redacted_uuid": true,
    "redacted_token": true, "redacted_mac": true, "redacted_api_key": true,
    "для": true, "как": true, "что": true, "при": true, "или": true,
    "нет": true, "все": true, "всё": true, "это": true, "так": true,
    "его": true, "она": true, "они": true, "мы": true, "вы": true,
    "над": true, "под": true, "без": true, "про": true, "через": true,
    "если": true, "когда": true, "почему": true, "зачем": true, "где": true,
    "работает": true, "проверка": true, "статус": true
};

const DOMAIN_BOOST_TERMS = {
    "zapret2": 1.8, "nfqws2": 1.8, "zapret": 1.5, "nfqws": 1.6,
    "byedpi": 1.7, "ciadpi": 1.7, "multisplit": 1.8, "seqovl": 1.8,
    "disorder2": 1.6, "split2": 1.5, "fooling": 1.5, "badseq": 1.5,
    "md5sig": 1.5, "wsize": 1.5, "sniext": 1.6, "midsld": 1.6,
    "fakeip": 1.7, "tproxy": 1.6, "dnsmasq": 1.6, "nftables": 1.6,
    "tachyontable": 1.8, "fwmark": 1.7, "nfqueue": 1.7, "conntrack": 1.7,
    "vless": 1.6, "reality": 1.6, "wireguard": 1.6, "amnezia": 1.7,
    "awg": 1.7, "hysteria2": 1.6, "shadowsocks": 1.5, "trojan": 1.5,
    "tailscale": 1.7, "fptn": 1.8, "wdtt": 1.8, "olcrtc": 1.8,
    "torrserver": 1.7, "urltest": 1.6, "balancer": 1.6,
    "condition": 1.6, "outbound_source": 1.8, "outbound_group": 1.8,
    "reconciler": 1.8, "known_good": 1.8, "transaction": 1.7, "watchdog": 1.6,
    "smart_detect": 1.8, "route_explain": 1.8, "config_plan": 1.8,
    "support_bundle": 1.8, "mcp": 1.7, "telegram": 1.5, "fuzzer": 1.7,
    "bootstrap": 1.6, "resolv": 1.6, "mtu": 1.6, "doh": 1.5, "oom": 1.6,
    "gomemlimit": 1.7, "youtube": 1.5, "googlevideo": 1.6, "discord": 1.5
};

function lexical_search(query, idx_obj, top_k) {
    if (!idx_obj || type(idx_obj.chunks) != "array" || length(idx_obj.chunks) == 0)
        return [];
    query = sanitize_query(query);
    let q_lc = lc(trim(as_string(query || "")));
    q_lc = replace(q_lc, /[,.;:!?()"'\/<>=]+/g, " ");
    q_lc = replace(q_lc, /[\][{}]/g, " ");
    let raw_words = split(q_lc, /[ \t\r\n]+/);
    let terms = [];
    let seen = {};
    for (let w in raw_words) {
        let t = trim(as_string(w));
        if (length(t) >= 2 && !STOP_WORDS[t] && !seen[t]) {
            seen[t] = true;
            push(terms, t);
        }
    }
    if (length(terms) == 0)
        return [];

    let eff_terms = length(terms) > 6 ? 6 : length(terms);
    let denom = eff_terms * 2.0;

    let scored = [];
    for (let i = 0; i < length(idx_obj.chunks); i++) {
        let chunk = idx_obj.chunks[i];
        let heading_lc = lc(as_string(chunk.heading || ""));
        let file_lc = lc(as_string(chunk.file || ""));
        let text_lc = lc(as_string(chunk.text || ""));
        let hits = 0.0;
        let matched_terms = 0;
        for (let t in terms) {
            let boost = DOMAIN_BOOST_TERMS[t] || 1.0;
            let term_hit = 0.0;
            if (index(heading_lc, t) >= 0)
                term_hit += 2.5 * boost;
            if (index(file_lc, t) >= 0)
                term_hit += 1.5 * boost;
            if (index(text_lc, t) >= 0)
                term_hit += 1.0 * boost;
            if (term_hit > 0) {
                hits += term_hit;
                matched_terms++;
            }
        }
        if (hits > 0) {
            // Bonus for matching multiple distinct query terms in the same chunk
            if (matched_terms > 1)
                hits += (matched_terms - 1) * 0.5;
            let norm_score = hits / denom;
            if (norm_score > 0.99) norm_score = 0.99;
            if (norm_score < 0.35) norm_score = 0.35 + (hits * 0.01);
            if (norm_score > 0.99) norm_score = 0.99;
            push(scored, { chunk: chunk, score: norm_score, raw_hits: hits });
        }
    }
    sort(scored, function(a, b) {
        if (b.raw_hits != a.raw_hits)
            return (b.raw_hits > a.raw_hits) ? 1 : -1;
        return (b.score > a.score) ? 1 : ((b.score < a.score) ? -1 : 0);
    });
    let limit = top_k || 3;
    if (length(scored) > limit)
        scored = slice(scored, 0, limit);
    return scored;
}

function has_valid_embedding_cache(idx_obj, provider, model_override) {
    let cached = load_embedding_cache();
    if (!cached || !idx_obj || type(idx_obj.chunks) != "array")
        return false;
    let model = get_embedding_model(provider, model_override);
    let stamp = index_stamp();
    return length(cached.embeddings) == length(idx_obj.chunks) &&
           cached.model == model &&
           cached.index_stamp == stamp;
}

function retrieve(query, provider, api_key, custom_url, model_override, top_k) {
    query = sanitize_query(query);
    let idx = load_raw_index();
    if (!idx)
        return "";

    let results = null;
    if (has_valid_embedding_cache(idx, provider, model_override) &&
        ensure_embeddings(idx, provider, api_key, custom_url, model_override)) {
        let query_emb = embed_query(query, provider, api_key, custom_url, model_override);
        if (query_emb)
            results = search(query_emb, idx, top_k || 3);
    }

    if (!results || length(results) == 0)
        results = lexical_search(query, idx, top_k || 3);

    let parts = [];
    for (let i = 0; i < length(results); i++) {
        let r = results[i];
        if (r.score < 0.3)
            continue;
        push(parts, sprintf("[Source: %s — %s] (relevance: %.0f%%)\n%s",
            r.chunk.file, r.chunk.heading, r.score * 100, r.chunk.text));
    }
    return join("\n\n---\n\n", parts);
}

function search_docs(query, top_k) {
    query = sanitize_query(query);
    let idx = load_raw_index();
    if (!idx)
        return [];
    let limit = int(top_k || 5);
    if (limit < 1) limit = 5;
    if (limit > 15) limit = 15;
    let results = lexical_search(query, idx, limit);
    let out = [];
    for (let i = 0; i < length(results); i++) {
        let r = results[i];
        push(out, {
            file: r.chunk.file,
            heading: r.chunk.heading,
            relevance: int(r.score * 100),
            text: r.chunk.text
        });
    }
    return out;
}

function invalidate_cache() {
    common.remove_file(EMBED_CACHE);
    rag_embed_cache = null;
    rag_index = null;
}

function status() {
    let idx = load_raw_index();
    let cached = load_embedding_cache();
    return {
        index_path: rag_index_path(),
        total_chunks: idx ? length(idx.chunks) : 0,
        embeddings_ready: cached ? length(cached.embeddings) : 0,
        embeddings_model: cached ? cached.model : "none",
        cache_age_hours: cached ? int((time() - cached.timestamp) / 3600) : -1
    };
}

return {
    retrieve: retrieve,
    search_docs: search_docs,
    sanitize_query: sanitize_query,
    invalidate_cache: invalidate_cache,
    status: status,
    load_raw_index: load_raw_index,
    get_embedding_model: get_embedding_model,
    search: search,
    lexical_search: lexical_search
};
