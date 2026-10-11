let common = require("core.common");
let as_string = common.as_string;
let list_option = common.list_option;

function is_valid_token(token) {
    token = trim(as_string(token));
    return length(token) > 0;
}

function validate_section(section) {
    if (!section)
        return { valid: false, error: "Section is missing" };

    let token = as_string(section.access_token || "");
    if (!is_valid_token(token)) {
        let manual_links = list_option(section, "selector_proxy_links");
        let sub_urls = list_option(section, "subscription_urls");
        let sub_url = as_string(section.subscription_url || "");
        if (length(manual_links) == 0 && length(sub_urls) == 0 && sub_url == "")
            return { valid: false, error: "Missing or invalid FPTN access token or connection links" };
    }

    return { valid: true };
}

return {
    is_valid_token,
    validate_section
};
