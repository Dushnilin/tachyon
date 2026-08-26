let fs = require("fs");
let common = require("core.common");

let command_from_args = common.command_from_args;
let rag_index = null;
let rag_embed_cache = null;

let INDEX_BUILTIN = "/usr/lib/tachyon/rag_index.json";
let INDEX_CUSTOM = "/etc/tachyon/rag_index.json";
let EMBED_CACHE = "/tmp/tachyon_rag_embeddings.json";

function rag_index_path() {
    if (fs.stat(INDEX_CUSTOM))
        return INDEX_CUSTOM;
    return INDEX_BUILTIN;
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
    if (model_override != "")
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
    let denom = sqrt(norm_a) * sqrt(norm_b);
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
        push({ chunk: chunk, score: score }, scored);
    }
    sort(scored, function(a, b) { return b.score - a.score; });
    let limit = top_k || 3;
    if (length(scored) > limit)
        scored = scored.slice(0, limit);
    return scored;
}

function retrieve(query, provider, api_key, custom_url, model_override, top_k) {
    let idx = load_raw_index();
    if (!idx)
        return "";

    if (!ensure_embeddings(idx, provider, api_key, custom_url, model_override))
        return "";

    let query_emb = embed_query(query, provider, api_key, custom_url, model_override);
    if (!query_emb)
        return "";

    let results = search(query_emb, idx, top_k || 3);
    let parts = [];
    for (let i = 0; i < length(results); i++) {
        let r = results[i];
        if (r.score < 0.3)
            continue;
        push(sprintf("[Source: %s — %s] (relevance: %.0f%%)\n%s",
            r.chunk.file, r.chunk.heading, r.score * 100, r.chunk.text), parts);
    }
    return join("\n\n---\n\n", parts);
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
    invalidate_cache: invalidate_cache,
    status: status,
    load_raw_index: load_raw_index
};
