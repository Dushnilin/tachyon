# Smart Detect: automatic Direct → Zapret → VPN

The optional connection-time chain selects a working DNS address through the
existing Zapret section, then tries the selected VPN when the Zapret budget is
exhausted. It does not create sections, add domains to UCI, modify host lists,
or reload the routing engine when a domain changes routes.

This is opt-in and requires the architecture-specific `tachyon-smart-connect`
binary. Existing Smart Detect Default/Plus behavior stays unchanged when the
chain is disabled. The chain replaces their background domain additions while
enabled.

## Components and routing

`tachyon_core/smart_connect.uc` adds two SOCKS outbounds and five loopback-only
probe listeners to the generated core configuration. Three force probes through
Direct, the selected Zapret section, and the selected VPN. Two DNS listeners
force real DNS answers from Direct and the Zapret section's resolver, before
FakeIP rules. Credentials and VPN protocol handling remain in the core.

The helper has two loopback listeners: otherwise-Direct LAN web traffic starts
at Direct; traffic assigned to the selected Zapret section starts at Zapret.
Manual block, bypass and VPN rules retain their existing precedence. The generic
fallback follows all explicit section rules. Only TCP ports 80/443 participate;
UDP, QUIC/HTTP3, other ports and unselected Zapret sections retain their routes.
Connector rules preserve the selected section's complete condition, including
protocol and inverted filters. Destination-IP and rule-set conditions keep their
original DNS resolution step; only DNS-independent conditions can run earlier.
The additional LAN interception uses the existing Smart Detect Plus nft capture,
after client/local/priority exclusions. Router-originated traffic is not added
to this capture.

The connector accepts domain-form SOCKS destinations. When the core passes an
IP instead, it buffers a bounded original HTTP header or TLS ClientHello to
recover Host/SNI. Those bytes are forwarded unchanged to the eventual winner.
This does not decrypt the user's TLS connection or replace its certificate.
The sniffed name is used for selection, while excluded names and failed searches
retain the client's original destination IP. Only a verified choice replaces it
with a pinned address or a name resolved through the selected VPN.
Names unavailable through sniffing, excluded domains, and local destinations
use their original route. Root-domain expansion is intentionally not performed:
`api.example.com` and `www.example.com` can need different paths.

## Selection and limits

1. Use a fresh cached decision immediately.
2. Otherwise resolve A/AAAA through the forced resolver for that stage, filtering
   private, loopback, link-local and FakeIP destinations out of active probes.
   Without a public IPv6 interface address, query A only. DNS shares the full
   stage budget with probing; there is no shorter DNS-only deadline.
   Usable answers begin probing immediately while the other family is pending;
   a blackholed AAAA lookup cannot consume the working A answer's probe time.
3. Probe at most two candidates concurrently, sharing slots between address families.
   FIFO workers divide the remaining budget between candidate waves, so two
   TLS blackholes cannot occupy both workers for the entire stage. Normal
   budgets retain at least a one-second per-candidate allowance, subject to the
   stage deadline. Probe TLS uses X25519/P256 to avoid expensive hybrid key
   exchange on soft-float devices; forwarded client handshakes are unchanged.
   HTTPS probes complete a verified TLS handshake with the destination's SNI.
   HTTP probes send an independent HEAD to `/`; HTTP error status does not by
   itself count as transport failure. At most 16 DNS candidates are considered
   per stage and four probes run globally, including VPN verification.
4. Direct has a 1500 ms search budget; Zapret defaults to 3000 ms, including DNS.
   A VPN fallback is used only after its independent TLS/HTTP probe succeeds,
   with an additional timeout of up to four seconds. These are search budgets,
   not a guarantee of total browser page-load time. DNS failure or certificate
   verification failure does not become a learned VPN decision.
   The client search deadline accounts for configured stage budgets, VPN checks
   and one pre-forwarding reselection. Each final SOCKS dial is bounded to five
   seconds, so increasing the Zapret budget does not hit an unrelated 12 s cap.
5. Cache decisions by exact hostname, port and starting stage. A pinned IP never
   outlives the minimum DNS/CNAME TTL or the five-minute cache ceiling. Failed
   selections are not permanently cached. Concurrent requests for the same key
   share a single selection job.
6. While using a cached VPN, check for recovery on the next access after five
   minutes. Keep serving through VPN while this check runs. Require two matching
   successful lower-cost decisions, at least 30 seconds apart, before returning.
   Existing relays are not moved or interrupted.

The helper bounds its cache to 1024 entries and active relays to 128 across both
listeners. It rereads its atomic configuration and exports a private RAM status
file every two seconds. Strategy/source, route, DNS and exclusion changes clear
cached observations. Local address and Linux route-table changes also invalidate
them. No per-request writes are made to flash.

System trust roots are loaded once before accepting connections. Lifecycle
waits for both listener binds and the current configuration generation before
activating core routes; a five-second readiness timeout aborts activation.
The prepare and active phases use distinct generations: the final commit clears
decisions made while the old core or a restarting Zapret worker was still active.

Only probe traffic is sent to multiple addresses. The user's HTTP request, POST
body and TLS early data go only to the winning connection. A TCP connection
failure before forwarding can trigger one reselection. Once forwarding starts,
the request is never replayed: a failure specific to the actual browser
fingerprint or a later API response can still require a client retry. A TLS
probe is evidence of transport reachability, not proof every application path
or authorization flow will work. ECH without a usable name and QUIC are outside
this first implementation.

## Build and installation

The backend package remains architecture-independent. With Go 1.22 or newer:

```sh
cd tools/smart-connect
go test ./...
go build -trimpath -o tachyon-smart-connect .
```

`bash tools/build-smart-connect.sh 0.0.0 build-out/smart-connect` produces static
Linux archives and checksums for x86_64, i386, aarch64, armv5/6/7,
mips/mipsel, mips64/mips64el and riscv64. Release CI publishes these separately
alongside the backend packages. Cross-compilation does not establish performance
or memory usage on physical routers.

Users only need the updated backend and LuCI packages. On applying the enabled
chain, Tachyon automatically installs a missing helper for the router's userspace
architecture, before changing the running core, DNS or firewall. The first
download can take several minutes. The existing component downloader uses the
current VPN and direct/mirror fallbacks, so the old network remains available
during installation. A download error aborts activation and is reported in the
service action log; the previously running network remains active. Saved UCI
settings still describe the requested change, and applying them again retries.

The helper and SHA-256 manifest must come from the installed backend's matching
release in the configured Tachyon release repository. A newer unrelated release
is never substituted. Release metadata bypasses mirror-filled caches; metadata
and the checksum manifest are fetched only from GitHub over the existing VPN or
direct HTTPS. The archive may use mirrors after its trusted hash is available.
Installation verifies the archive hash, its single regular
file, and the helper's configuration-check command before an atomic rename into
`/usr/bin/tachyon-smart-connect` (0755). Unsupported architectures, missing assets,
bad checksums, incompatible executables and insufficient storage fail before
activation. Existing helpers are reused without downloading only after a bounded
configuration self-check; a damaged executable is repaired during preflight.
Cold-boot clock recovery runs before HTTPS downloads. Concurrent installs share
a lock that cannot be taken from a live owner just because a mirror is slow.

Development checkouts without a published matching release require building and
installing the helper manually. Service lifecycle remains owned by Tachyon; do
not enable or run the helper independently.

In Settings → Services and access, enable Smart Detect and **Automatic
Direct → Zapret → VPN**, then choose the existing Zapret and backup VPN sections.
The equivalent settings are:

```text
smart_detect='1'
smart_detect_chain='1'
smart_detect_chain_zapret='zapret'
smart_detect_chain_vpn='proxy'
smart_detect_chain_budget_ms='3000'
```

No site-specific section is needed. Existing separate exceptions are not deleted
automatically. Applying the initial feature/configuration change can reload or
restart the core in the usual way; later automatic IP/route selections do not.
The feature supports the tachyon-core/sing-box configuration pipeline, not Steer.

## Diagnostics and verification

`tachyon smart_connect_status` prints the bounded RAM cache: starting stage,
hostname/port, route, selected IP, reason, check/expiry time and pending jobs.
Files live in `/var/run/tachyon/smart-connect`, private to root. They contain no
VPN credentials. Cache state is intentionally lost on helper restart/reboot.

Local tests, with no router access:

```sh
cd tools/smart-connect
go vet ./...
go test -race ./...
cd ../..
bash tests/smart_connect.sh
bash tests/smart_detect_modes.sh
bash tests/dpi_routed_dns.sh
```

The Go tests use local SOCKS/DNS/TLS fixtures: multiple IPs, TCP-success/TLS
blackholes, VPN fallback, recovery hysteresis, TTL, cache isolation/single-flight,
certificate/DNS failures, SNI recovery, fragmented ClientHello, and forwarding a
POST exactly once. Dual-stack regressions cover a hanging and a late DNS family;
an end-to-end maximum-budget case verifies that VPN remains reachable after a
long Zapret search. Offline installer tests cover origin-only trust, release and
architecture matching, hashes, archive members, damaged/foreign executables,
storage failure, concurrency, owner-aware locks, clock recovery and preserving
the running network. Backend tests exercise the real generator, route precedence,
forced probe listeners, exclusions, port collisions and reload signatures.
Set `TACHYON_TEST_CORE` to a local core binary to additionally preflight the full
generated fixture.

### Isolated router trial, 2026-10-31

Tested on OpenWrt 25.12.2, MT7621 / mipsel_24kc with 256 MB RAM, using a second
loopback-only core and helper. The original service, UCI and LAN capture were
left unchanged. The canary reused the existing VPN through its loopback SOCKS
listener. Trial limits were 16 relays and two global probes.

The final build became ready in 0.78 s and used about 9.1 MiB RSS. Gofile selected
45.112.123.126 through the generic Zapret route: HTTP 200 in 1.96 s on first
access and 0.69 s on repeat. An otherwise-Direct example.com request took
1.18 / 0.49 s. API GitHub took 2.97 / 0.54 s and selected Zapret after Direct
exhausted its budget. These are individual request samples, not latency bounds.

A controlled failure of the canary Zapret endpoint selected VPN and returned
HTTP 200. Restoring it demonstrated the two-confirmation recovery back to
Zapret without restarting either process. Manual Direct, VPN and block rules
kept precedence. A 2 MiB relay completed intact; loopback helper throughput was
about 25 MB/s, which does not establish real WAN throughput. Household LAN
interception and a global configuration apply were not exercised in this trial.

### LAN activation verification, 2026-10-31

The feature was subsequently enabled on the same router with a verified backup
and an independent rollback deadline. Installed files and configuration were
preflighted before activation; the helper's live PID and generation were checked
before disarming rollback. Tachyon autostart remains enabled and owns the helper.
The previous Gofile-specific section was disabled so it no longer selects its
own Zapret strategy. Existing manual block, bypass and VPN rules kept precedence.

Unproxied HTTPS requests from a Windows LAN client succeeded for example.com,
Gofile, its API, API GitHub, YouTube and Wikipedia. Repeated requests took
0.15–0.72 s in the recorded sample, and a 2 MiB HTTPS transfer completed intact
in 1.34 s. These include existing explicit routes, not only helper decisions.
The helper cache showed all three routes under real LAN traffic, with 11 Direct,
22 Zapret and 13 VPN decisions at one snapshot. Helper RSS was about 10.6 MiB.
No new core errors appeared during verification. The rollback deadline was
disarmed after success; the backup and manual restore script were retained.

These router measurements precede the automatic installer and subsequent review
fixes. Those additions were verified with local fixtures and CI and were not
reapplied to the router as part of PR preparation.
