#!/usr/bin/env bash
# #424: Tachyon's own odhcpd setup (dns/apply.uc) clears dhcp.lan.dns in every
# active IPv6 mode and sets ra_dns=1, so odhcpd announces the router itself as
# IPv6 DNS. Doctor flagged that as "dhcp.lan.dns is empty" and its --fix (the
# same configure) could never satisfy it.
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

DNS_APPLY="$TACHYON_LIB/dns/apply.uc"

# The premise: dns/apply.uc clears dhcp.lan.dns and sets ra_dns=1 for tunnel_over_v4.
grep -A25 'eff_v6.ipv6_mode == "tunnel_over_v4"' "$DNS_APPLY" | grep -q 'uci_delete("dhcp.lan.dns")' &&
  grep -A25 'eff_v6.ipv6_mode == "tunnel_over_v4"' "$DNS_APPLY" | grep -q 'uci_set("dhcp.lan.ra_dns", "1")' ||
  fail "dns/apply.uc changed how it announces IPv6 DNS for tunnel_over_v4: revisit this test"

ucode -L "$TACHYON_LIB" -e '
let d = require("diagnostics.doctor");
function check(lan, want, why) {
    let got = d.odhcpd_ipv6_dns_announced(lan);
    if ((got != "") != want)
        die(sprintf("%s: odhcpd_ipv6_dns_announced(%J) = %J\n", why, lan, got));
}
// tunnel_over_v4 / full, exactly as dns/apply.uc leaves dhcp.lan
check({ dhcpv6: "server", ra: "server", ra_dns: "1", ra_default: "2" }, true, "tunnel_over_v4 (#424)");
check({ dhcpv6: "server", ra: "server", ra_dns: "1" }, true, "full IPv6");
check({ dhcpv6: "server" }, true, "odhcpd defaults announce the router");
check({ dhcpv6: "server", dns: [ "fd00::1" ] }, true, "explicit dhcp.lan.dns");
check({ dhcpv6: "server", dns: "fd00::1 fd00::2" }, true, "explicit dhcp.lan.dns as a string");
// genuinely nothing announced
check({ dhcpv6: "server", ra_dns: "0", dns_service: "0" }, false, "ra_dns and dns_service off");
check({ dhcpv6: "server", dns_service: "0" }, false, "dns_service off");
check({ dhcpv6: "server", ra_dns: "0" }, false, "ra_dns off");
' || fail "doctor misjudges the odhcpd IPv6 DNS that Tachyon configures"

printf 'PASS: doctor_odhcpd_ipv6_dns\n'
