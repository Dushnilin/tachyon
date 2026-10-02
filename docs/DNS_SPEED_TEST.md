# DNS speed test

In **Settings → DNS settings**, **Test DNS speed** measures the selected primary
DoH servers without saving the form, applying recommendations or restarting any
service. Bootstrap servers are not measured. UDP, DoT and DoQ are not supported
by this test; selecting them disables the button.

The gear beside the button edits 1–32 test domains. URLs are normalized to
hostnames, IDNs to punycode, and duplicates are removed. The list is saved in the
current browser's local storage, not in UCI. Changing it clears the displayed
results. The defaults are `google.com`, `youtube.com`, `facebook.com`,
`instagram.com`, `chatgpt.com`, `x.com`, `whatsapp.com`, `reddit.com`,
`wikipedia.org`, `amazon.com`, `tiktok.com`, and `pinterest.com`.

Each selected server gets a clickable median beside its existing DNS row. Its
dialog shows minimum, median, average, maximum, successful query count and a
result for every domain. Failed requests count as 5000 ms when calculating
statistics; if all requests fail, the UI shows **Unavailable**. HTTP, TLS, DNS
and timeout failures are shown separately. These are DNS resolution timings,
not ICMP pings or website load times.

The method is inspired by [DoHSpeedTest](https://github.com/BrainicHQ/DoHSpeedTest):
warm-up requests followed by a measured series of DNS `A` queries. Here the
requests originate from the router, run serially and reuse curl's connection
cache within each server's batch. The browser tool runs concurrent fetches, so
its numbers are not directly comparable. The router measures the full response
and verifies HTTPS certificates, HTTP status, content type and DNS wire data.
This is a short snapshot, not a long-term reliability or DNSSEC validation test.

The backend accepts 1–8 servers and uses a five-second deadline per request,
including warm-ups. With many unreachable servers or domains a run may take
several minutes. A lock and PID/start-time/boot-ID checks prevent concurrent
workers and identify stopped workers. Test state is stored in RAM under
`/var/run/tachyon/dns-speed-test/` with mode `0700`, since custom DoH URLs may
contain private profile identifiers. Results disappear after reboot.

```sh
tachyon dns_speed_test_start '{"protocol":"doh","servers":["https://dns.google/dns-query"],"domains":["google.com","youtube.com"]}'
tachyon dns_speed_test_status
```

Starting the test requires the write role. The status command is also exposed
through `tachyon-read`, allowing a read-only LuCI account to inspect completed
results without gaining access to the main CLI.

Regression checks are in `tests/dns_speed_test.sh` and
`fe-app-tachyon/src/helpers/tests/dnsSpeedTest.test.js`. The backend fixture
checks validation, DNS wire replies, failure penalties, warm-up exclusion,
TLS flags and asynchronous worker completion without contacting public DNS.
