let connections = require("config.connections");

function validate_section(section) {
    if (!section)
        return { valid: false, error: "Section is missing" };

    // The same resolver the generator and the runtime dial with. The old copy
    // accepted a subscription-only section, which the engine then refused to
    // start — subscriptions never carry FPTN tokens.
    if (connections.fptn_section_token(section) == "")
        return { valid: false, error: "Missing or invalid FPTN access token or connection links" };

    return { valid: true };
}

return {
    validate_section
};
