#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

function contains(values, needle) {
    for (let value in values) {
        if (value == needle)
            return true;
    }
    return false;
}

function regex_matches(value, pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return false;

    try {
        return match(as_string(value), regexp(pattern)) != null;
    }
    catch (e) {
        return false;
    }
}

function normalized_country_list(values) {
    let result = [];
    for (let value in array_or_empty(values)) {
        value = uc(as_string(value));
        if (length(value) == 2)
            push(result, value);
    }
    return result;
}

function byte_at(value, index) {
    return ord(value, index);
}

function regional_indicator_letter(value, index) {
    if (index + 3 >= length(value))
        return "";

    if (byte_at(value, index) != 240 ||
        byte_at(value, index + 1) != 159 ||
        byte_at(value, index + 2) != 135)
        return "";

    let letter = byte_at(value, index + 3) - 166;
    if (letter < 0 || letter > 25)
        return "";

    return chr(65 + letter);
}

function fold_text_case(value) {
    value = as_string(value);
    let bytes = [];
    let i = 0;
    while (i < length(value)) {
        let b = byte_at(value, i);
        if (b >= 65 && b <= 90) {
            push(bytes, b + 32);
            i += 1;
        }
        else if (b == 0xD0 && i + 1 < length(value)) {
            let b2 = byte_at(value, i + 1);
            if (b2 >= 0x90 && b2 <= 0x9F)
                push(bytes, 0xD0, b2 + 0x20);
            else if (b2 >= 0xA0 && b2 <= 0xAF)
                push(bytes, 0xD1, b2 - 0x20);
            else if (b2 == 0x81)
                push(bytes, 0xD1, 0x91);
            else
                push(bytes, b, b2);
            i += 2;
        }
        else {
            push(bytes, b);
            i += 1;
        }
    }
    let result = "";
    for (let byte in bytes)
        result += chr(byte);
    return result;
}

const COUNTRY_NAME_PATTERNS = [
    [ "united kingdom", "GB" ],
    [ "great britain", "GB" ],
    [ "великобритания", "GB" ],
    [ "англия", "GB" ],
    [ "london", "GB" ],
    [ "лондон", "GB" ],
    [ "united states", "US" ],
    [ "america", "US" ],
    [ "америка", "US" ],
    [ "сша", "US" ],
    [ "netherlands", "NL" ],
    [ "holland", "NL" ],
    [ "нидерланды", "NL" ],
    [ "голландия", "NL" ],
    [ "amsterdam", "NL" ],
    [ "амстердам", "NL" ],
    [ "switzerland", "CH" ],
    [ "швейцария", "CH" ],
    [ "zurich", "CH" ],
    [ "цюрих", "CH" ],
    [ "geneva", "CH" ],
    [ "женева", "CH" ],
    [ "kazakhstan", "KZ" ],
    [ "казахстан", "KZ" ],
    [ "almaty", "KZ" ],
    [ "алматы", "KZ" ],
    [ "astana", "KZ" ],
    [ "астана", "KZ" ],
    [ "lithuania", "LT" ],
    [ "литва", "LT" ],
    [ "vilnius", "LT" ],
    [ "вильнюс", "LT" ],
    [ "singapore", "SG" ],
    [ "сингапур", "SG" ],
    [ "hong kong", "HK" ],
    [ "гонконг", "HK" ],
    [ "germany", "DE" ],
    [ "германия", "DE" ],
    [ "frankfurt", "DE" ],
    [ "франкфурт", "DE" ],
    [ "berlin", "DE" ],
    [ "берлин", "DE" ],
    [ "finland", "FI" ],
    [ "финляндия", "FI" ],
    [ "helsinki", "FI" ],
    [ "хельсинки", "FI" ],
    [ "estonia", "EE" ],
    [ "эстония", "EE" ],
    [ "tallinn", "EE" ],
    [ "таллин", "EE" ],
    [ "austria", "AT" ],
    [ "австрия", "AT" ],
    [ "vienna", "AT" ],
    [ "вена", "AT" ],
    [ "czechia", "CZ" ],
    [ "czech", "CZ" ],
    [ "чехия", "CZ" ],
    [ "prague", "CZ" ],
    [ "прага", "CZ" ],
    [ "ireland", "IE" ],
    [ "ирландия", "IE" ],
    [ "dublin", "IE" ],
    [ "дублин", "IE" ],
    [ "denmark", "DK" ],
    [ "дания", "DK" ],
    [ "copenhagen", "DK" ],
    [ "копенгаген", "DK" ],
    [ "albania", "AL" ],
    [ "албания", "AL" ],
    [ "tirana", "AL" ],
    [ "тирана", "AL" ],
    [ "vietnam", "VN" ],
    [ "вьетнам", "VN" ],
    [ "hanoi", "VN" ],
    [ "ханой", "VN" ],
    [ "ukraine", "UA" ],
    [ "украина", "UA" ],
    [ "kyiv", "UA" ],
    [ "kiev", "UA" ],
    [ "киев", "UA" ],
    [ "belarus", "BY" ],
    [ "беларусь", "BY" ],
    [ "белоруссия", "BY" ],
    [ "minsk", "BY" ],
    [ "минск", "BY" ],
    [ "france", "FR" ],
    [ "франция", "FR" ],
    [ "paris", "FR" ],
    [ "париж", "FR" ],
    [ "sweden", "SE" ],
    [ "швеция", "SE" ],
    [ "stockholm", "SE" ],
    [ "стокгольм", "SE" ],
    [ "poland", "PL" ],
    [ "польша", "PL" ],
    [ "warsaw", "PL" ],
    [ "варшава", "PL" ],
    [ "latvia", "LV" ],
    [ "латвия", "LV" ],
    [ "riga", "LV" ],
    [ "рига", "LV" ],
    [ "turkey", "TR" ],
    [ "турция", "TR" ],
    [ "istanbul", "TR" ],
    [ "стамбул", "TR" ],
    [ "norway", "NO" ],
    [ "норвегия", "NO" ],
    [ "oslo", "NO" ],
    [ "осло", "NO" ],
    [ "greece", "GR" ],
    [ "греция", "GR" ],
    [ "athens", "GR" ],
    [ "афины", "GR" ],
    [ "russia", "RU" ],
    [ "россия", "RU" ],
    [ "moscow", "RU" ],
    [ "москва", "RU" ],
    [ "питер", "RU" ],
    [ "japan", "JP" ],
    [ "япония", "JP" ],
    [ "tokyo", "JP" ],
    [ "токио", "JP" ],
    [ "spain", "ES" ],
    [ "испания", "ES" ],
    [ "madrid", "ES" ],
    [ "мадрид", "ES" ],
    [ "italy", "IT" ],
    [ "италия", "IT" ],
    [ "milan", "IT" ],
    [ "милан", "IT" ],
    [ "canada", "CA" ],
    [ "канада", "CA" ],
    [ "toronto", "CA" ],
    [ "торонто", "CA" ],
    [ "emirates", "AE" ],
    [ "оаэ", "AE" ],
    [ "эмираты", "AE" ],
    [ "dubai", "AE" ],
    [ "дубай", "AE" ],
    [ "georgia", "GE" ],
    [ "грузия", "GE" ],
    [ "tbilisi", "GE" ],
    [ "тбилиси", "GE" ],
    [ "armenia", "AM" ],
    [ "армения", "AM" ],
    [ "yerevan", "AM" ],
    [ "ереван", "AM" ],
    [ "moldova", "MD" ],
    [ "молдова", "MD" ],
    [ "serbia", "RS" ],
    [ "сербия", "RS" ],
    [ "belgrade", "RS" ],
    [ "белград", "RS" ],
    [ "bulgaria", "BG" ],
    [ "болгария", "BG" ],
    [ "sofia", "BG" ],
    [ "софия", "BG" ],
    [ "romania", "RO" ],
    [ "румыния", "RO" ],
    [ "hungary", "HU" ],
    [ "венгрия", "HU" ],
    [ "budapest", "HU" ],
    [ "будапешт", "HU" ],
    [ "slovakia", "SK" ],
    [ "словакия", "SK" ],
    [ "cyprus", "CY" ],
    [ "кипр", "CY" ],
    [ "israel", "IL" ],
    [ "израиль", "IL" ],
    [ "india", "IN" ],
    [ "индия", "IN" ],
    [ "korea", "KR" ],
    [ "корея", "KR" ],
    [ "seoul", "KR" ],
    [ "сеул", "KR" ],
    [ "usa", "US" ]
];

const COMMON_ISO_CODES = {
    RU: true, DE: true, NL: true, US: true, GB: true, FR: true, FI: true, SE: true,
    PL: true, TR: true, KZ: true, SG: true, JP: true, HK: true, CA: true, CH: true,
    AT: true, ES: true, IT: true, UA: true, AE: true, NO: true, CZ: true, EE: true,
    LV: true, LT: true, MD: true, BY: true, GE: true, AM: true, UZ: true, KG: true,
    RS: true, BG: true, RO: true, HU: true, GR: true, CY: true, IL: true, IN: true,
    KR: true, AU: true, BR: true, AR: true, MX: true, IS: true, IE: true, PT: true,
    BE: true, DK: true, SK: true, AL: true, VN: true
};

function is_iso_boundary_byte(b) {
    if (b == null)
        return true;
    return b == 32 || b == 9 || b == 45 || b == 95 || b == 46 ||
           b == 91 || b == 93 || b == 40 || b == 41 || b == 124 || b == 47;
}

function country_from_iso_token(value) {
    value = as_string(value);
    let len = length(value);
    for (let i = 0; i + 1 < len; i++) {
        let b1 = byte_at(value, i);
        let b2 = byte_at(value, i + 1);
        if (b1 < 65 || b1 > 90 || b2 < 65 || b2 > 90)
            continue;
        let prev = i > 0 ? byte_at(value, i - 1) : null;
        let next = (i + 2 < len) ? byte_at(value, i + 2) : null;
        if (!is_iso_boundary_byte(prev) || !is_iso_boundary_byte(next))
            continue;
        let code = chr(b1) + chr(b2);
        if (code == "UK")
            return "GB";
        if (COMMON_ISO_CODES[code])
            return code;
    }
    return "";
}

function country_from_text_name(value) {
    let raw = as_string(value);
    let text = fold_text_case(raw);
    if (text == "")
        return "";
    for (let entry in COUNTRY_NAME_PATTERNS) {
        if (index(text, entry[0]) >= 0)
            return entry[1];
    }
    return country_from_iso_token(raw);
}

let COUNTRY_BY_NAME_CACHE = {};

function country_from_flag_emoji(value) {
    value = as_string(value);
    if (value == "")
        return "";
    let cached = COUNTRY_BY_NAME_CACHE[value];
    if (cached != null)
        return cached;

    for (let i = 0; i + 7 < length(value); i++) {
        let first = regional_indicator_letter(value, i);
        if (first == "")
            continue;

        let second = regional_indicator_letter(value, i + 4);
        if (second != "") {
            let code = first + second;
            COUNTRY_BY_NAME_CACHE[value] = code;
            return code;
        }
    }

    let resolved = country_from_text_name(value);
    COUNTRY_BY_NAME_CACHE[value] = resolved;
    return resolved;
}

let _last_flag_names_ref = null;
let _last_flag_names_len = -1;
let _last_flag_countries_res = null;

function countries_from_flag_names(names) {
    names = object_or_empty(names);
    let n_len = length(names);
    if (names == _last_flag_names_ref && n_len == _last_flag_names_len && _last_flag_countries_res != null)
        return _last_flag_countries_res;

    let result = {};

    for (let tag, name in names) {
        let country = country_from_flag_emoji(name);
        if (country != "")
            result[tag] = country;
    }

    _last_flag_names_ref = names;
    _last_flag_names_len = n_len;
    _last_flag_countries_res = result;
    return result;
}

function regex_matching_tag_array(tags, names, regexes) {
    tags = array_or_empty(tags);
    names = object_or_empty(names);
    regexes = array_or_empty(regexes);
    
    let compiled = [];
    for (let pattern in regexes) {
        let pat_str = as_string(pattern);
        if (pat_str != "") {
            try {
                push(compiled, regexp(pat_str));
            }
            catch (e) {
                // The pattern comes from the user's own config. Dropping it
                // silently leaves a group that quietly matches fewer outbounds
                // than the config says it should — a routing change with no
                // visible cause. The remaining patterns still apply.
                warn("urltest: ignoring invalid regex " + pat_str + ": " + as_string(e) + "\n");
            }
        }
    }
    
    let result = [];
    for (let tag in tags) {
        let name = names[tag];
        name = name == null || as_string(name) == "" ? tag : as_string(name);

        for (let re in compiled) {
            if (match(name, re) != null) {
                push(result, tag);
                break;
            }
        }
    }

    return result;
}

const TELEMETRY_BYTE_UNITS = {
    "b": true, "kb": true, "kib": true, "mb": true, "mib": true,
    "gb": true, "gib": true, "tb": true, "tib": true, "pb": true, "pib": true,
    "byte": true, "bytes": true,
    "б": true, "кб": true, "киб": true, "мб": true, "миб": true,
    "гб": true, "гиб": true, "тб": true, "тиб": true,
    "байт": true, "кбайт": true, "мбайт": true, "гбайт": true, "тбайт": true
};

const TELEMETRY_DURATION_UNITS = {
    "d": true, "day": true, "days": true,
    "h": true, "hr": true, "hrs": true, "hour": true, "hours": true,
    "m": true, "min": true, "mins": true,
    "д": true, "дн": true, "дн.": true, "день": true, "дня": true, "дней": true,
    "ч": true, "час": true, "часа": true, "часов": true, "мин": true
};

const TELEMETRY_WORDS = {
    "left": true, "rem": true, "remain": true, "remaining": true, "used": true, "free": true,
    "total": true, "limit": true, "quota": true, "traffic": true, "data": true, "usage": true,
    "balance": true, "bw": true, "of": true, "unlim": true, "unlimited": true, "inf": true,
    "exp": true, "expire": true, "expires": true, "until": true, "valid": true,
    "reset": true, "renew": true, "due": true, "days": true,
    "осталось": true, "остаток": true, "трафик": true, "из": true, "срок": true,
    "лимит": true, "доступно": true, "исп": true, "использовано": true, "безлимит": true,
    "до": true, "истекает": true, "сброс": true, "годен": true
};

const TELEMETRY_PROTECTED_TOKENS = {
    "ipv4": true, "ipv6": true, "http": true, "https": true,
    "vless": true, "vmess": true, "trojan": true, "hysteria": true,
    "hysteria2": true, "tuic": true, "wireguard": true, "amnezia": true,
    "amneziawg": true, "awg": true, "shadowsocks": true, "shadowtls": true,
    "reality": true, "xhttp": true, "grpc": true, "ws": true,
    "tcp": true, "udp": true, "quic": true, "tls": true, "lte": true
};

const TELEMETRY_DATE_PREFIXES = [
    "valid until",
    "expires",
    "expire",
    "exp",
    "until",
    "valid",
    "истекает",
    "годен до",
    "до"
];

function normalize_telemetry_text(value) {
    value = as_string(value);
    let len = length(value);
    let bytes = [];
    let i = 0;
    while (i < len) {
        let b = byte_at(value, i);
        if (b >= 65 && b <= 90) {
            push(bytes, b + 32);
            i += 1;
        }
        else if (b == 44) {
            let prev_digit = i > 0 && byte_at(value, i - 1) >= 48 && byte_at(value, i - 1) <= 57;
            let next_digit = i + 1 < len && byte_at(value, i + 1) >= 48 && byte_at(value, i + 1) <= 57;
            push(bytes, (prev_digit && next_digit) ? 46 : 44);
            i += 1;
        }
        else if (b >= 0x20 && b <= 0x7E) {
            push(bytes, b);
            i += 1;
        }
        else if (b == 0xD0 && i + 1 < len) {
            let b2 = byte_at(value, i + 1);
            if (b2 >= 0x90 && b2 <= 0x9F)
                push(bytes, 0xD0, b2 + 0x20);
            else if (b2 >= 0xA0 && b2 <= 0xAF)
                push(bytes, 0xD1, b2 - 0x20);
            else if (b2 == 0x81)
                push(bytes, 0xD1, 0x91);
            else if (b2 >= 0xB0 && b2 <= 0xBF)
                push(bytes, b, b2);
            else
                push(bytes, 32);
            i += 2;
        }
        else if (b == 0xD1 && i + 1 < len) {
            let b2 = byte_at(value, i + 1);
            if ((b2 >= 0x80 && b2 <= 0x8F) || b2 == 0x91)
                push(bytes, b, b2);
            else
                push(bytes, 32);
            i += 2;
        }
        else if ((b & 0xE0) == 0xC0) {
            push(bytes, 32);
            i += (i + 2 <= len) ? 2 : 1;
        }
        else if ((b & 0xF0) == 0xE0) {
            push(bytes, 32);
            i += (i + 3 <= len) ? 3 : 1;
        }
        else if ((b & 0xF8) == 0xF0) {
            push(bytes, 32);
            i += (i + 4 <= len) ? 4 : 1;
        }
        else {
            push(bytes, 32);
            i += 1;
        }
    }
    let result = "";
    for (let byte in bytes)
        result += chr(byte);
    return result;
}

function split_leading_telemetry_number(tok) {
    let len = length(tok);
    if (len == 0)
        return null;
    let b0 = byte_at(tok, 0);
    if (b0 < 48 || b0 > 57)
        return null;
    let idx = 0;
    let seen_dot = false;
    while (idx < len) {
        let b = byte_at(tok, idx);
        if (b >= 48 && b <= 57) {
            idx++;
        }
        else if (b == 46 && !seen_dot && idx + 1 < len &&
                 byte_at(tok, idx + 1) >= 48 && byte_at(tok, idx + 1) <= 57) {
            seen_dot = true;
            idx++;
        }
        else {
            break;
        }
    }
    if (idx == 0 || idx >= len)
        return null;
    return [ substr(tok, 0, idx), substr(tok, idx) ];
}

function is_dynamic_telemetry_segment(raw_seg) {
    let norm = trim(normalize_telemetry_text(raw_seg));
    if (norm == "")
        return false;

    if (index(norm, "#") >= 0)
        return false;

    if (index(norm, "bps") >= 0 || index(norm, "bit") >= 0 || index(norm, "бит") >= 0 ||
        index(norm, "/s") >= 0 || index(norm, "/c") >= 0 || index(norm, "/с") >= 0 ||
        index(norm, "/сек") >= 0 || index(norm, "/sec") >= 0)
        return false;

    for (let kw in [
        "ipv4", "ipv6", "http", "vless", "vmess", "trojan", "hysteria",
        "tuic", "wireguard", "amnezia", "shadowsocks", "reality", "xhttp",
        "grpc", "quic"
    ]) {
        if (index(norm, kw) >= 0)
            return false;
    }

    let date_candidate = norm;
    let had_date_prefix = false;
    for (let pfx in TELEMETRY_DATE_PREFIXES) {
        let plen = length(pfx);
        if (length(date_candidate) > plen && substr(date_candidate, 0, plen) == pfx) {
            let next_ch = substr(date_candidate, plen, 1);
            if (next_ch == ":" || next_ch == " " || next_ch == "\t") {
                date_candidate = trim(replace(substr(date_candidate, plen), /^[: \t]+/, ""));
                had_date_prefix = true;
                break;
            }
        }
    }
    if (match(date_candidate, /^20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]([ ]+[0-2][0-9]:[0-5][0-9])?$/) != null ||
        match(date_candidate, /^[0-3][0-9]\.[0-1][0-9]\.20[0-9][0-9]([ ]+[0-2][0-9]:[0-5][0-9])?$/) != null)
        return true;
    if (had_date_prefix &&
        (match(date_candidate, /^[0-3][0-9][.\/-][0-1][0-9]$/) != null ||
         match(date_candidate, /^[0-1][0-9][.\/-][0-3][0-9]$/) != null))
        return true;

    let spaced = replace(norm, /[\/|:;+(),-]/g, " ");
    let raw_tokens = split(spaced, /[ \t]+/);
    let tokens = [];
    for (let tok in raw_tokens) {
        tok = trim(tok);
        if (tok != "")
            push(tokens, tok);
    }
    if (length(tokens) == 0)
        return false;

    let has_value_unit = false;
    let has_telemetry_word = false;
    let has_percent = false;
    let prev_was_number = false;
    for (let tok in tokens) {
        if (TELEMETRY_PROTECTED_TOKENS[tok])
            return false;
        if (match(tok, /^[0-9]+(\.[0-9]+)?%?$/) != null) {
            if (substr(tok, length(tok) - 1) == "%") {
                has_percent = true;
                prev_was_number = false;
            }
            else {
                prev_was_number = true;
            }
            continue;
        }
        if (tok == "%" && prev_was_number) {
            has_percent = true;
            prev_was_number = false;
            continue;
        }
        let split_num = split_leading_telemetry_number(tok);
        if (split_num != null) {
            let unit = split_num[1];
            if (!TELEMETRY_BYTE_UNITS[unit] && !TELEMETRY_DURATION_UNITS[unit])
                return false;
            if (length(tokens) == 1 && (tok == "2d" || tok == "3d"))
                return false;
            has_value_unit = true;
            prev_was_number = false;
            continue;
        }
        if (TELEMETRY_BYTE_UNITS[tok] || TELEMETRY_DURATION_UNITS[tok]) {
            if (prev_was_number)
                has_value_unit = true;
            prev_was_number = false;
            continue;
        }
        if (TELEMETRY_WORDS[tok]) {
            has_telemetry_word = true;
            prev_was_number = false;
            continue;
        }
        return false;
    }

    return has_value_unit || (has_telemetry_word && has_percent);
}

function strip_dynamic_server_telemetry(value) {
    let orig = trim(as_string(value));
    if (orig == "")
        return "";

    let out = "";
    let i = 0;
    let len = length(orig);
    let removed_bracket = false;
    while (i < len) {
        let ch = substr(orig, i, 1);
        if (ch == "[" || ch == "(") {
            let close_ch = ch == "[" ? "]" : ")";
            let depth = 0;
            let close_idx = -1;
            for (let j = i; j < len; j++) {
                let cj = substr(orig, j, 1);
                if (cj == ch)
                    depth++;
                else if (cj == close_ch) {
                    depth--;
                    if (depth == 0) {
                        close_idx = j;
                        break;
                    }
                }
            }
            if (close_idx > i) {
                let inner = substr(orig, i + 1, close_idx - i - 1);
                if (is_dynamic_telemetry_segment(inner)) {
                    removed_bracket = true;
                    i = close_idx + 1;
                    continue;
                }
                out += substr(orig, i, close_idx - i + 1);
                i = close_idx + 1;
                continue;
            }
        }
        out += ch;
        i++;
    }

    out = trim(replace(out, /[ \t]+/g, " "));
    if (removed_bracket) {
        for (let d_tail in [ " |", " •", " —", " –", " -" ]) {
            let dlen = length(d_tail);
            if (length(out) > dlen && substr(out, length(out) - dlen) == d_tail) {
                out = trim(substr(out, 0, length(out) - dlen));
                break;
            }
        }
    }

    let delimiters = [ " | ", " • ", " — ", " – ", " - " ];
    while (true) {
        let best_idx = -1;
        let best_sep = "";
        for (let sep in delimiters) {
            let idx = rindex(out, sep);
            if (idx > best_idx) {
                best_idx = idx;
                best_sep = sep;
            }
        }
        if (best_idx <= 0)
            break;
        let tail = substr(out, best_idx + length(best_sep));
        if (!is_dynamic_telemetry_segment(tail))
            break;
        out = trim(substr(out, 0, best_idx));
    }

    out = trim(replace(out, /[ \t]+/g, " "));
    return out != "" ? out : orig;
}

function name_filter_contains(values, needle) {
    values = array_or_empty(values);
    if (length(values) == 0)
        return false;
    if (contains(values, needle))
        return true;
    let canon = strip_dynamic_server_telemetry(needle);
    if (canon == "")
        return false;
    for (let value in values) {
        if (value == canon || strip_dynamic_server_telemetry(value) == canon)
            return true;
    }
    return false;
}

function filter_array(mode, tags, names, countries, name_filter, regex_tags, country_filter) {
    tags = array_or_empty(tags);
    names = object_or_empty(names);
    countries = object_or_empty(countries);
    name_filter = array_or_empty(name_filter);
    regex_tags = array_or_empty(regex_tags);
    country_filter = array_or_empty(country_filter);
    let result = [];

    for (let tag in tags) {
        let name = as_string(names[tag] || tag);
        let country = uc(as_string(countries[tag] || ""));
        let matched = name_filter_contains(name_filter, name) ||
            contains(name_filter, tag) ||
            (country != "" && contains(country_filter, country)) ||
            contains(regex_tags, tag);

        if ((mode == "include" && matched) || (mode == "exclude" && !matched))
            push(result, tag);
    }

    return result;
}

function filter_mode(mode, tags, names, countries, include_names, include_regexes, include_countries, exclude_names, exclude_regexes, exclude_countries) {
    include_countries = normalized_country_list(include_countries);
    exclude_countries = normalized_country_list(exclude_countries);

    let include_regex_tags = regex_matching_tag_array(tags, names, include_regexes);
    let exclude_regex_tags = regex_matching_tag_array(tags, names, exclude_regexes);

    if (mode == "include")
        return filter_array("include", tags, names, countries, include_names, include_regex_tags, include_countries);
    if (mode == "exclude")
        return filter_array("exclude", tags, names, countries, exclude_names, exclude_regex_tags, exclude_countries);
    if (mode == "mixed") {
        let included = filter_array("include", tags, names, countries, include_names, include_regex_tags, include_countries);
        return filter_array("exclude", included, names, countries, exclude_names, exclude_regex_tags, exclude_countries);
    }
    return array_or_empty(tags);
}

return {
    normalized_country_list,
    countries_from_flag_names,
    regex_matching_tag_array,
    strip_dynamic_server_telemetry,
    name_filter_contains,
    filter_array,
    filter_mode
};
