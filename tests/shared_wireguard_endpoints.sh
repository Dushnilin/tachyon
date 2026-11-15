#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

export SB_VARIANT_STATE_FILE="$WORK_DIR/variant"
export TACHYON_CONFIG_OWNERS_FILE="$WORK_DIR/owners.json"
export SB_VERSION_OVERRIDE=0.5.2
printf 'tachyon-core' >"$SB_VARIANT_STATE_FILE"

node - "$WORK_DIR" <<'JS'
const fs = require("fs");
const dir = process.argv[2];
const key = n => Buffer.alloc(32, n).toString("base64");
const source = (name, changes = {}) => ({
    ".name": name, ".type": "outbound_source", source_type: "amnezia_config",
    amnezia_configs: [JSON.stringify({name: "VPN", config: [
        "[Interface]", "PrivateKey = " + key(17), "Address = 10.0.0.2",
        "MTU = " + (changes.mtu || 1280), "S3 = " + (changes.padding || 40),
        "H1 = 100-200", "[Peer]", "PublicKey = " + key(23),
        "Endpoint = 192.0.2.1:51820", "AllowedIPs = 0.0.0.0/0",
    ].join("\n")})],
});
const section = (name, ref, overrides = {}) => ({
    ".name": name, ".type": "section", enabled: "1", action: "connection",
    outbound_source_refs: [ref], domain_suffix: [name + ".example"], ...overrides,
});
const fixture = {
    settings: {".name": "settings", ".type": "settings", dns_server: ["192.0.2.53"]},
    outbound_source: [
        source("shared"), source("equal"), source("mtu", {mtu: 1400}),
        source("padding", {padding: 41}),
    ],
    section: [
        section("a", "shared"), section("b", "shared"), section("c", "equal"),
        section("different_mtu", "mtu"), section("different_padding", "padding"),
        section("different_bind", "shared", {bind_interface: "eth9"}),
        section("different_detour", "shared", {
            outbound_detour_enabled: "1", outbound_detour_section: "different_mtu",
        }),
    ],
};
fs.writeFileSync(dir + "/fixture.json", JSON.stringify(fixture));
fixture.section.shift();
fs.writeFileSync(dir + "/removed.json", JSON.stringify(fixture));
fixture.section = [section("local", "", {action: "bypass", outbound_source_refs: []})];
fs.writeFileSync(dir + "/unused.json", JSON.stringify(fixture));
JS

for name in fixture removed unused; do
    ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
        "$WORK_DIR/$name.json" "$WORK_DIR/$name-config.json" "127.0.0.1" "0"
done

printf 'lx' >"$SB_VARIANT_STATE_FILE"
ucode -L "$TACHYON_LIB" "$TACHYON_LIB/tachyon_core/generator.uc" generate-config-fixture \
    "$WORK_DIR/fixture.json" "$WORK_DIR/lx-config.json" "127.0.0.1" "0"

node - "$WORK_DIR" <<'JS'
const assert = require("node:assert/strict");
const fs = require("fs");
const dir = process.argv[2];
const read = name => JSON.parse(fs.readFileSync(dir + "/" + name + "-config.json"));
function verify(name, sections) {
    const config = read(name);
    const endpoints = config.endpoints.filter(item => item.type === "wireguard");
    assert.equal(endpoints.length, 5, "only equivalent WireGuard endpoints are shared");
    const all = [...config.outbounds, ...config.endpoints];
    const items = new Map(all.map(item => [item.tag, item]));
    assert.equal(items.size, all.length, "tags remain unique");
    const leaf = name => {
        const selector = items.get(name + "-out");
        assert.equal(selector.type, "selector");
        return items.get(selector.outbounds.find(tag => {
            const candidate = items.get(tag);
            return candidate.type === "wireguard" || candidate.type === "selector";
        }));
    };
    const canonical = leaf(sections[0]);
    assert.equal(canonical.type, "wireguard");
    for (const section of sections.slice(1)) {
        const alias = leaf(section);
        assert.equal(alias.type, "selector");
        assert.deepEqual(alias.outbounds, [canonical.tag]);
        const metadata = JSON.parse(fs.readFileSync(
            dir + "/" + name + "-config.json.section-cache/" + section + ".json"
        ));
        assert.ok(metadata.urltestCandidateTags.includes(alias.tag));
        assert.equal(metadata.outboundMetadata.protocols[alias.tag], "amneziawg");
    }
    assert.equal(leaf("different_mtu").mtu, 1400);
    assert.equal(leaf("different_padding").s3, 41);
    assert.equal(leaf("different_bind").bind_interface, "eth9");
    assert.equal(leaf("different_detour").detour, "different_mtu-out");
}
verify("fixture", ["a", "b", "c"]);
verify("removed", ["b", "c"]);
assert.equal(read("lx").endpoints.filter(item => item.type === "wireguard").length, 7);
assert.equal((read("unused").endpoints || []).length, 0, "unused sources create no endpoint");
JS
echo "PASS: equivalent WireGuard transports are shared and section member tags still resolve"
