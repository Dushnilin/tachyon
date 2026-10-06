# Smart Detect modes

Smart Detect is disabled by default. When enabled, **Settings → Services and access → Smart Detect mode** selects `default` or `plus`. An absent or unknown `smart_detect_mode` uses Default. The description next to the selector follows the selected mode immediately; Telegram notifications keep the **Smart Detect** name in either mode.

## Default

Default preserves the upstream detector: sing-box error logs, hostname correlation by trace ID, HTTPS HEAD probes, and repeated Direct failures confirmed at least 120 seconds apart against the shared HTTP/mixed proxy. Processing follows the watchdog's normal adaptive tier; 120 seconds is a confirmation floor, not an end-to-end detection guarantee. The detected hostname is saved.

## Plus

Plus also observes stalled LAN TCP connections on ports 80/443 using sing-box's existing Clash API. It detects requests with uploaded data but no response after two observations five seconds apart, or a partial response with no progress for 15 seconds. Empty browser preconnects, non-web ports, UDP and non-Direct outbounds are excluded.

Additional TPROXY capture is installed only when `smart_detect=1` and `smart_detect_mode=plus`. Existing exclusions, local/Tailscale bypass and priority routing rules retain precedence. Router-originated traffic is not captured. Applying a different mode changes the firewall signature and rebuilds the capture rules.

The detector verifies a full GET of the original hostname: two failed Direct GETs and a successful shared proxy GET are required. Direct probes use the existing WAN/bypass flags. Curl DNS resolution and local certificate/configuration failures defer processing instead of creating VPN rules. HTTP error status alone is not transport failure.

The saved rule uses the registrable main domain from the bundled Public Suffix List, including PRIVATE, wildcard and exception rules. A suffix itself cannot become an automatic wildcard rule. For example, `api.example.co.uk` becomes `example.co.uk`; sing-box's domain-suffix match covers it and its subdomains. If the list is unavailable, the narrower hostname is retained. The packaged snapshot is ASCII/Punycode-normalized and retains its MPL-2.0 attribution and source metadata.

Candidates use a bounded priority/FIFO queue (500 entries, 300-second TTL) and a five-minute cooldown file in RAM, `/var/run/tachyon/smart_detect_plus_seen.json`. At most one background probe is active, with at least ten seconds between starts. The old `/etc` cooldown file is read for migration but no longer updated. Restarting the watchdog retains the RAM cooldown; reboot clears it. Learned UCI domains remain persistent. Multiline/list UCI domain values and legacy text values are merged without exact case-insensitive domain duplicates, preserving comments and prefixed conditions. Pending UCI edits defer automatic writes; unchanged lists do not trigger reload. A failed commit/reload is not reported as a successful addition.

## Shared safeguards and limits

Both modes retain the upstream DNS/runtime guard: pause during known DNS failure or a reload/failover transaction, allow 30 seconds to settle after DNS/runtime changes, and recheck state after probes. Switching modes preserves learned domains. Automatic removal after Direct recovery is not implemented.

Plus requires sing-box TPROXY and its Clash API. QUIC/UDP and connections without a visible hostname are not covered. The GET checks `/`, not the client's exact path, and does not follow redirects. A successful root request does not prove that every API endpoint works. The shared mixed inbound follows its configured routes and does not prove every possible selected VPN is healthy. A bounded background worker performs the same probes (up to 26 seconds total), with a 35-second job deadline. The watchdog keeps polling while the probe runs; a DNS outage/change, changed section selection or disabled Plus invalidates its result. The worker never writes UCI. Cancellation verifies process identity before terminating its isolated process group. `setsid` must be available. A result is applied only after the next watchdog poll; adding a rule may reload the routing engine and interrupt active connections.

## Verification

Run `sh tests/watchdog_runtime_cleanup.sh`, `sh tests/watchdog_plus_async.sh`, `sh tests/watchdog_priority_timeout.sh`, `sh tests/smart_detect_modes.sh`, `sh tests/smart_detect_dns_guard.sh`, and `node tests/smart_detect_modes_ui.mjs`. Fixtures isolate DNS, probes, UCI and notifications. The exported controller is exercised directly to catch ucode closure declaration-order errors that compilation alone cannot detect.

For runtime verification, inspect watchdog logs as well as its PID, the `tachyon-smart-detect` nftables rules/counters, learned UCI domains and real sing-box connection chains. A running process alone does not prove that the polling callback is working.
