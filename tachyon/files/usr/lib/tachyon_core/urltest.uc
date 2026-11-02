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

function country_from_flag_emoji(value) {
    value = as_string(value);

    for (let i = 0; i + 7 < length(value); i++) {
        let first = regional_indicator_letter(value, i);
        if (first == "")
            continue;

        let second = regional_indicator_letter(value, i + 4);
        if (second != "")
            return first + second;
    }

    return country_from_text_name(value);
}

function countries_from_flag_names(names) {
    names = object_or_empty(names);
    let result = {};

    for (let tag, name in names) {
        let country = country_from_flag_emoji(name);
        if (country != "")
            result[tag] = country;
    }

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
        let matched = contains(name_filter, name) ||
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
    filter_array,
    filter_mode
};