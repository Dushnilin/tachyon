# Constructs and returns a ruleset tag using section, name, optional type, and a fixed postfix
get_ruleset_tag() {
    local section="$1"
    local name="$2"
    local type="$3"
    local postfix="ruleset"

    if [ -n "$type" ]; then
        echo "$section-$name-$type-$postfix"
    else
        echo "$section-$name-$postfix"
    fi
}

# Creates a new ruleset JSON file if it doesn't already exist
create_source_rule_set() {
    local ruleset_filepath="$1"

    if file_exists "$ruleset_filepath"; then
        return 3
    fi

    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" create-source "$ruleset_filepath"
}

#######################################
# Patch a source ruleset JSON file for sing-box by appending a new ruleset object containing the provided key
# and value.
# Arguments:
#   filepath: path to the JSON file to patch
#   key: the ruleset key to insert (e.g., "ip_cidr")
#   value: a JSON array of values to assign to the key
# Example:
#   patch_source_ruleset_rules "/tmp/sing-box/ruleset.json" "ip_cidr" '["1.1.1.1","2.2.2.2"]'
#######################################
patch_source_ruleset_rules() {
    local filepath="$1"
    local key="$2"
    local value="$3"

    local tmpfile
    tmpfile="$(mktemp)" || return 1

    cp "$filepath" "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }

    if ! ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" patch-source "$tmpfile" "$key" "$value"; then
        rm -f "$tmpfile"
        return 1
    fi

    mv "$tmpfile" "$filepath"
}

log_plain_ruleset_import_counts() {
    local counts_filepath="$1"
    local ruleset_filepath="$2"
    local noun="$3"

    [ -s "$counts_filepath" ] || return 0

    while IFS= read -r count; do
        [ -z "$count" ] && continue
        log "Adding $count elements to $noun at $ruleset_filepath" "debug"
    done < "$counts_filepath"
}

log_plain_ruleset_import_invalid() {
    local invalid_filepath="$1"
    local message="$2"

    [ -s "$invalid_filepath" ] || return 0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        log "'$line' $message" "debug"
    done < "$invalid_filepath"
}

# Imports a plain domain list into a ruleset in chunks, validating domains and appending them as domain_suffix rules
import_plain_domain_list_to_local_source_ruleset_chunked() {
    local plain_list_filepath="$1"
    local ruleset_filepath="$2"
    local chunk_size="${3:-5000}"

    local invalid_filepath counts_filepath
    invalid_filepath="$(mktemp)" || return 1
    counts_filepath="$(mktemp)" || {
        rm -f "$invalid_filepath"
        return 1
    }

    if ! ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" import-plain-list \
        "$plain_list_filepath" "$ruleset_filepath" "domain_suffix" "domains" "$chunk_size" \
        "$invalid_filepath" "$counts_filepath"; then
        rm -f "$invalid_filepath" "$counts_filepath"
        return 1
    fi

    log_plain_ruleset_import_counts "$counts_filepath" "$ruleset_filepath" "rule set"
    log_plain_ruleset_import_invalid "$invalid_filepath" "is not a valid domain"

    rm -f "$invalid_filepath" "$counts_filepath"
}

# Imports a plain IPv4/CIDR list into a ruleset in chunks, validating entries and appending them as ip_cidr rules
import_plain_subnet_list_to_local_source_ruleset_chunked() {
    local plain_list_filepath="$1"
    local ruleset_filepath="$2"
    local chunk_size="${3:-5000}"

    local invalid_filepath counts_filepath
    invalid_filepath="$(mktemp)" || return 1
    counts_filepath="$(mktemp)" || {
        rm -f "$invalid_filepath"
        return 1
    }

    if ! ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" import-plain-list \
        "$plain_list_filepath" "$ruleset_filepath" "ip_cidr" "subnets" "$chunk_size" \
        "$invalid_filepath" "$counts_filepath"; then
        rm -f "$invalid_filepath" "$counts_filepath"
        return 1
    fi

    log_plain_ruleset_import_counts "$counts_filepath" "$ruleset_filepath" "ruleset"
    log_plain_ruleset_import_invalid "$invalid_filepath" "is not IPv4 or IPv4 CIDR"

    rm -f "$invalid_filepath" "$counts_filepath"
}

# Decompiles a sing-box SRS binary file into a JSON ruleset file
decompile_binary_ruleset() {
    local binary_filepath="$1"
    local output_filepath="$2"

    log "Decompiling $binary_filepath to $output_filepath" "debug"
    sing-box rule-set decompile "$binary_filepath" -o "$output_filepath"
    if [ $? -ne 0 ]; then
        log "Decompilation command failed for $binary_filepath" "error"
        return 1
    fi
}

# Extracts all ip_cidr entries from a JSON ruleset file and writes them to an output file.
extract_ip_cidr_from_json_ruleset_to_file() {
    local json_file="$1"
    local output_file="$2"

    log "Extracting ip_cidr entries from $json_file to $output_file" "debug"
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" extract-ip-cidr "$json_file" "$output_file"
}

extract_ip_cidr_nft_elements_from_json_ruleset_to_files() {
    local json_file="$1"
    local unscoped_output_file="$2"
    local scoped_output_file="$3"
    local ports_json="${4:-[]}"
    local port_ranges_json="${5:-[]}"

    log "Extracting ip_cidr nft elements from $json_file to $unscoped_output_file and $scoped_output_file" "debug"
    ucode "${PODKOP_LIB:-/usr/lib/podkop-plus}/rulesets.uc" extract-ip-cidr-nft \
        "$json_file" "$unscoped_output_file" "$scoped_output_file" "$ports_json" "$port_ranges_json"
}
