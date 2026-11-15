#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
set -eo pipefail

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/state"

cat >"$WORK_DIR/bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -eo pipefail
{
  printf 'curl'
  for arg in "$@"; do
    printf '\t%s' "$arg"
  done
  printf '\n'
} >> "${CURL_ARGS_LOG:?}"

case "${MOCK_CURL_MODE:-ok_256k}" in
  stall_64k)
    printf '206\t0.090\t0.140\t10900\t65536\t0.020'
    exit 28
    ;;
  ok_256k)
    printf '206\t0.090\t0.160\t614400\t262144\t0.020'
    exit 0
    ;;
  *)
    printf '200\t0.080\t0.120\t200000\t65536\t0.020'
    exit 0
    ;;
esac
CURL_STUB
chmod 0755 "$WORK_DIR/bin/curl"

export PATH="$WORK_DIR/bin:$PATH"
export TACHYON_FUZZER_STATE_DIR="$WORK_DIR/state"
export CURL_ARGS_LOG="$WORK_DIR/curl_args.log"

pass_count=0
ok() {
  pass_count=$((pass_count + 1))
}

# 1. probe.parse_curl_output streaming stall, shaping, unauth 404/429, and verified_256k tiers
ucode -L "$TACHYON_LIB" -e '
  let probe = require("diagnostics.fuzzer.probe");

  // Streaming stalls across 16 KiB / 64 KiB / 96 KiB / aborted HTTP 206 (< 128 KiB)
  let s16 = probe.parse_curl_output("206\t0.080\t0.120\t6500\t16384\t0.020\t1\t28", {}, { streaming: true });
  if (s16.success || s16.data_verified || s16.dpi_verdict != "throttled_16k") {
    warn(sprintf("unexpected s16: %J\n", s16));
    exit(1);
  }

  let s64 = probe.parse_curl_output("206\t0.090\t0.130\t10900\t65536\t0.020\t1\t28", {}, { streaming: true });
  if (s64.success || s64.data_verified || s64.score != 0 || s64.dpi_verdict != "throttled_stream") {
    warn(sprintf("unexpected s64: %J\n", s64));
    exit(1);
  }

  let s96 = probe.parse_curl_output("200\t0.080\t0.110\t46800\t98304\t0.020\t1\t56", {}, { streaming: true });
  if (s96.success || s96.data_verified || s96.dpi_verdict != "throttled_stream") {
    warn(sprintf("unexpected s96: %J\n", s96));
    exit(1);
  }

  let s18 = probe.parse_curl_output("206\t0.080\t0.120\t91000\t110000\t0.020\t1\t18", {}, { streaming: true });
  if (s18.success || s18.data_verified || s18.dpi_verdict != "throttled_stream") {
    warn(sprintf("unexpected s18: %J\n", s18));
    exit(1);
  }

  // Bandwidth shaping (<40 KB/s, <200 KB, TTFB > 2500ms)
  let shaped = probe.parse_curl_output("206\t0.090\t2.850\t15360\t80000\t0.020\t1\t0", {}, { streaming: true });
  if (shaped.success || shaped.data_verified || shaped.score != 0 || shaped.dpi_verdict != "throttled_stream") {
    warn(sprintf("unexpected shaped: %J\n", shaped));
    exit(1);
  }

  // Non-streaming tls_http preserves 16k verdict & verified_32k
  let w16 = probe.parse_curl_output("200\t0.080\t0.120\t6500\t16384\t0.020\t1\t28", {});
  if (w16.success || w16.dpi_verdict != "throttled_16k") {
    warn(sprintf("unexpected w16: %J\n", w16));
    exit(1);
  }
  let w64 = probe.parse_curl_output("200\t0.080\t0.120\t200000\t65536\t0.020\t1\t0", {});
  if (!w64.success || !w64.data_verified || w64.dpi_verdict != "verified_32k") {
    warn(sprintf("unexpected w64: %J\n", w64));
    exit(1);
  }

  // Unauthenticated 0-byte 401/403/404/429: availability only, no data_verified or fake data bonus
  for (let code in [401, 403, 404, 429]) {
    let r = probe.parse_curl_output(sprintf("%d\t0.060\t0.070\t0\t0\t0.020\t1\t0", code), {}, { streaming: true });
    if (!r.success || r.data_verified || r.dpi_verdict != "available") {
      warn(sprintf("unexpected %d unauth result: %J\n", code, r));
      exit(1);
    }
  }

  // Verified 256 KiB streaming clearly outranks verified_32k and 0-byte 404
  let r404 = probe.parse_curl_output("404\t0.050\t0.060\t0\t0\t0.020\t1\t0", {}, { streaming: true });
  let r32k = probe.parse_curl_output("206\t0.080\t0.100\t187000\t65536\t0.020\t1\t0", {}, { streaming: true });
  let r256k = probe.parse_curl_output("206\t0.090\t0.180\t614400\t262144\t0.020\t1\t0", {}, { streaming: true });
  if (!r256k.success || !r256k.data_verified || r256k.dpi_verdict != "verified_256k") {
    warn(sprintf("unexpected r256k: %J\n", r256k));
    exit(1);
  }
  if (!(r256k.score > r32k.score && r32k.score > r404.score)) {
    warn(sprintf("score ordering broken: 256k=%d, 32k=%d, 404=%d\n", r256k.score, r32k.score, r404.score));
    exit(1);
  }
' || fail "streaming parse_curl_output verification failed"
ok

# 2. probe.uc and targets.uc issue -r 0-262143 and max-time 6 for streaming endpoints, and 0-65535 for tls_http
: > "$CURL_ARGS_LOG"
MOCK_CURL_MODE="stall_64k" ucode -L "$TACHYON_LIB" -e '
  let targets = require("diagnostics.fuzzer.targets");
  let res = targets.probe_single_target_dpi({
    name: "GoogleVideo Stream CDN",
    url: "https://rr1.googlevideo.com/videoplayback",
    probe_kind: "streaming"
  }, "");
  if (res.type != "throttle") {
    warn(sprintf("expected throttle for 64 KiB streaming stall, got: %J\n", res));
    exit(1);
  }

  let web = targets.probe_single_target_dpi({
    name: "Web Interface",
    url: "https://www.youtube.com/",
    probe_kind: "tls_http"
  }, "");
  if (web.type != "none") {
    warn(sprintf("unexpected tls_http classification: %J\n", web));
    exit(1);
  }
' || fail "targets.probe_single_target_dpi streaming classification failed"
ok

grep -Fq -- $'\t-r\t0-262143\t' "$CURL_ARGS_LOG" || fail "streaming target did not request -r 0-262143"
grep -Fq -- $'\t--max-time\t6\t' "$CURL_ARGS_LOG" || fail "streaming target did not set --max-time 6"
awk -F'\t' '/www\.youtube\.com/ && /-r\t0-262143/ { exit 1 }' "$CURL_ARGS_LOG" ||
  fail "tls_http target must not receive -r 0-262143"
ok

# 3. Structural check on probe.uc for streaming flags and watchdog
grep -Fq 'extra_flags = "-r 0-262143 ";' "$TACHYON_LIB/diagnostics/fuzzer/probe.uc" ||
  fail "probe.uc must request -r 0-262143 for streaming targets"
grep -Fq '(p_kind == "streaming") ? 8 :' "$TACHYON_LIB/diagnostics/fuzzer/probe.uc" ||
  fail "probe.uc must set watchdog_sec = 8 for streaming targets"
ok

# 4. ISP DNS priority for googlevideo hosts in binaries.uc
ucode -L "$TACHYON_LIB" - <<'UCODE'
let fs_mod = require("fs");
let orig_readfile = fs_mod.readfile;
let orig_popen = fs_mod.popen;
let queried = [];

fs_mod.readfile = function(p) {
    if (p == "/tmp/resolv.conf.d/resolv.conf.auto")
        return "nameserver 192.168.1.1\nnameserver 85.21.192.3\nnameserver 10.0.0.1\n";
    return orig_readfile(p);
};

fs_mod.popen = function(cmd, mode) {
    if (index(cmd, "uci -q get tachyon.settings.bootstrap_dns_server") >= 0) {
        return { read: function() { return "77.88.8.8\n"; }, close: function() {} };
    }
    let m = match(cmd, /nslookup '([^']+)' ([0-9.]+)/);
    if (m) {
        let qhost = m[1], qsrv = m[2];
        push(queried, qhost + "@" + qsrv);
        if (qhost == "redirector.googlevideo.com") {
            return { read: function() { return ""; }, close: function() {} };
        }
        let ans = (index(qhost, "googlevideo.com") >= 0) ? "79.133.77.44" : "142.251.142.238";
        return {
            read: function() { return sprintf("Name:\t%s\nAddress: %s\n", qhost, ans); },
            close: function() {}
        };
    }
    return orig_popen(cmd, mode);
};

let binaries = require("diagnostics.fuzzer.binaries");

let f_rr = binaries.get_resolved_host_flags("https://rr1.googlevideo.com/videoplayback");
if (index(f_rr, "--resolve rr1.googlevideo.com:443:79.133.77.44") < 0) {
    warn(sprintf("unexpected rr1 flags: %J\n", f_rr));
    exit(1);
}
if (length(queried) < 2 || queried[0] != "redirector.googlevideo.com@85.21.192.3") {
    warn(sprintf("expected ISP DNS first for redirector.googlevideo.com, got: %J\n", queried));
    exit(1);
}
let saw_gv_isp = false;
for (let q in queried) {
    if (index(q, "googlevideo.com@") == 0) {
        if (q != "googlevideo.com@85.21.192.3") {
            warn(sprintf("googlevideo.com must query ISP DNS first, got: %J\n", queried));
            exit(1);
        }
        saw_gv_isp = true;
        break;
    }
}
if (!saw_gv_isp) {
    warn(sprintf("missing googlevideo.com lookup after redirector fallback: %J\n", queried));
    exit(1);
}

queried = [];
let ipv4 = binaries.resolve_host_ipv4("rr4---sn-test.googlevideo.com");
if (ipv4 != "79.133.77.44" || length(queried) == 0 || queried[0] != "rr4---sn-test.googlevideo.com@85.21.192.3") {
    warn(sprintf("resolve_host_ipv4 must query ISP DNS first: ip=%J queried=%J\n", ipv4, queried));
    exit(1);
}

queried = [];
let f_yt = binaries.get_resolved_host_flags("https://www.youtube.com/");
if (index(f_yt, "--resolve www.youtube.com:443:142.251.142.238") < 0 ||
    length(queried) == 0 || queried[0] != "www.youtube.com@77.88.8.8") {
    warn(sprintf("non-googlevideo host must keep uci_bootstrap DNS first: flags=%J queried=%J\n", f_yt, queried));
    exit(1);
}
UCODE
ok

printf 'fuzzer streaming verification: %d checks passed\n' "$pass_count"
printf 'PASS: fuzzer_streaming_verification\n'
