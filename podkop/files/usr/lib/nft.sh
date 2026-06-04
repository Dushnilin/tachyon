# Create an nftables table in the inet family
nft_create_table() {
    local name="$1"

    nft add table inet "$name"
}

# Create a set within a table for storing IPv4 addresses
nft_create_ipv4_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ipv4_addr; flags interval; auto-merge; }'
}

nft_create_inet_service_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type inet_service; flags interval; auto-merge; }'
}

nft_create_ipv4_port_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ipv4_addr . inet_service; flags interval; auto-merge; }'
}

nft_create_ifname_set() {
    local table="$1"
    local name="$2"

    nft add set inet "$table" "$name" '{ type ifname; flags interval; }'
}

# Add one or more elements to a set
nft_add_set_elements() {
    local table="$1"
    local set="$2"
    local elements="$3"

    nft add element inet "$table" "$set" "{ $elements }"
}

nft_log_prepared_invalid_elements() {
    local invalid_filepath="$1"

    [ -s "$invalid_filepath" ] || return 0

    while IFS="$(printf '\t')" read -r value message || [ -n "$value" ]; do
        [ -n "$value" ] || continue
        log "'$value' $message" "debug"
    done < "$invalid_filepath"
}

nft_add_prepared_chunks_to_set() {
    local chunks_filepath="$1"
    local nft_table_name="$2"
    local nft_set_name="$3"
    local count elements

    [ -s "$chunks_filepath" ] || return 0

    while read -r count elements || [ -n "$count" ]; do
        [ -n "$elements" ] || continue
        log "Adding $count elements to nft set $nft_set_name" "debug"
        nft_add_set_elements "$nft_table_name" "$nft_set_name" "$elements"
    done < "$chunks_filepath"
}

nft_add_file_chunks_to_set() {
    local filepath="$1"
    local nft_table_name="$2"
    local nft_set_name="$3"
    local kind="$4"
    local ports="$5"
    local chunk_size="$6"

    local chunks_filepath invalid_filepath status
    chunks_filepath="$(mktemp)" || return 1
    invalid_filepath="$(mktemp)" || {
        rm -f "$chunks_filepath"
        return 1
    }

    if ! rules_nft_runtime_ucode nft-prepare-chunks "$filepath" "$kind" "$ports" "$chunk_size" "$chunks_filepath" "$invalid_filepath"; then
        rm -f "$chunks_filepath" "$invalid_filepath"
        return 1
    fi

    nft_log_prepared_invalid_elements "$invalid_filepath"
    nft_add_prepared_chunks_to_set "$chunks_filepath" "$nft_table_name" "$nft_set_name"
    status=$?

    rm -f "$chunks_filepath" "$invalid_filepath"
    return "$status"
}

nft_add_port_set_elements_from_file_chunked() {
    nft_add_file_chunks_to_set "$1" "$2" "$3" "ports" "" "${4:-5000}"
}

nft_add_ip_port_set_elements_from_file_chunked() {
    nft_add_file_chunks_to_set "$1" "$2" "$3" "ip-ports" "" "${4:-5000}"
}

nft_add_ip_port_set_elements_from_ip_file_chunked() {
    nft_add_file_chunks_to_set "$1" "$2" "$3" "ip-port-from-ip" "$4" "${5:-5000}"
}

nft_add_set_elements_from_file_chunked() {
    nft_add_file_chunks_to_set "$1" "$2" "$3" "ips" "" "${4:-5000}"
}
