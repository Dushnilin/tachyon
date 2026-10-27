"use strict";
"require baseclass";
"require form";
"require fs";
"require uci";
"require ui";
"require view.tachyon.main as main";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE || "tachyon";
const SECTION_CACHE_DIR = "/var/run/tachyon/section-cache";

const COMMON_COUNTRIES = [
  ["NL", "🇳🇱 NL"],
  ["DE", "🇩🇪 DE"],
  ["FI", "🇫🇮 FI"],
  ["FR", "🇫🇷 FR"],
  ["GB", "🇬🇧 GB"],
  ["US", "🇺🇸 US"],
  ["SE", "🇸🇪 SE"],
  ["PL", "🇵🇱 PL"],
  ["EE", "🇪🇪 EE"],
  ["LV", "🇱🇻 LV"],
  ["LT", "🇱🇹 LT"],
  ["CH", "🇨🇭 CH"],
  ["AT", "🇦🇹 AT"],
  ["CZ", "🇨🇿 CZ"],
  ["TR", "🇹🇷 TR"],
  ["KZ", "🇰🇿 KZ"],
  ["SG", "🇸🇬 SG"],
  ["JP", "🇯🇵 JP"],
  ["RU", "🇷🇺 RU"],
  ["UA", "🇺🇦 UA"],
  ["BY", "🇧🇾 BY"],
];

const PROTOCOL_CHOICES = [
  "vless",
  "hysteria2",
  "tuic",
  "trojan",
  "vmess",
  "shadowsocks",
  "anytls",
  "naive",
  "amneziawg",
  "wireguard",
  "openvpn",
  "fptn",
  "mieru",
  "trusttunnel",
  "masque",
  "openconnect",
  "shadowtls",
  "snell",
  "sudoku",
  "socks",
  "http",
  "direct",
];

const TRANSPORT_CHOICES = [
  "tcp",
  "ws",
  "grpc",
  "http",
  "httpupgrade",
  "quic",
  "xhttp",
];

const SECURITY_CHOICES = ["none", "tls", "reality"];

const PORT_CHOICES = [
  "443",
  "80",
  "8443",
  "2053",
  "2083",
  "2087",
  "2096",
  "8080",
];

const DPI_SOURCE_TYPES = new Set(["zapret", "zapret2", "byedpi", "desync"]);

const ZAPRET_DEFAULT_NFQWS_OPT =
  "--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin";

const ZAPRET2_DEFAULT_NFQWS2_OPT =
  "--filter-tcp=80 --filter-l7=http --payload=http_req --lua-desync=fake:blob=fake_default_http:tcp_md5 --lua-desync=multisplit:pos=method+2 --new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 --lua-desync=multidisorder:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6";

const BYEDPI_DEFAULT_CMD_OPTS = "-o 2 --auto=t,r,a,s -d 2";

function isoToFlagEmoji(iso) {
  const code = String(iso || "")
    .trim()
    .toUpperCase();
  if (!/^[A-Z]{2}$/.test(code)) return "";
  return String.fromCodePoint(
    0x1f1e6 + (code.charCodeAt(0) - 65),
    0x1f1e6 + (code.charCodeAt(1) - 65),
  );
}

function loadGlobalPoolChoices() {
  const secNames = (uci.sections(UCI_PACKAGE, "section") || [])
    .map((s) => s[".name"])
    .filter((n) => n && /^[A-Za-z0-9_-]+$/.test(n));
  if (!secNames.includes("Main")) secNames.unshift("Main");

  const readCache = (secName) => {
    const path = `${SECTION_CACHE_DIR}/${secName}.json`;
    return fs
      .read(path)
      .catch(() =>
        typeof fs.read_direct === "function"
          ? fs.read_direct(path, "text")
          : Promise.resolve("{}"),
      )
      .then((raw) => JSON.parse(raw || "{}"))
      .catch(() => ({}));
  };

  return Promise.all(secNames.map(readCache)).then((caches) => {
    const serverMap = new Map();
    const countrySet = new Set();
    const prefixSet = new Set();

    (uci.sections(UCI_PACKAGE, "outbound_source") || []).forEach((src) => {
      if (src.node_prefix) prefixSet.add(String(src.node_prefix).trim());
      const stype = String(src.source_type || "subscription").toLowerCase();
      if (DPI_SOURCE_TYPES.has(stype)) return;
      const sname = String(src.name || src[".name"] || "").trim();
      asArray(src.proxy_links || src.selector_proxy_links).forEach((link) => {
        const lname =
          (typeof main.getProxyUrlName === "function" &&
            main.getProxyUrlName(link)) ||
          link;
        if (lname && !serverMap.has(lname)) {
          serverMap.set(lname, lname);
        }
      });
      if (stype !== "subscription" && stype !== "proxy_links" && sname) {
        const badge = stype.toUpperCase();
        if (!serverMap.has(sname)) {
          serverMap.set(sname, `${sname} [${badge}]`);
        }
      }
    });

    caches.forEach((c) => {
      const meta = (c && c.outboundMetadata) || {};
      const groups = (c && c.urltestGroups) || {};
      const pgroups = (c && c.priorityGroups) || {};
      const rawHidden = (c && c.hiddenOutboundTags) || {};
      const hiddenSet = new Set(
        Array.isArray(rawHidden) ? rawHidden : Object.keys(rawHidden),
      );
      const names = meta.names || {};
      const countries = meta.countries || {};
      const protocols = meta.protocols || {};
      const transports = meta.transports || {};
      const prefixes = meta.prefixes || {};

      Object.entries(names).forEach(([tag, rawName]) => {
        if (groups[tag] || pgroups[tag] || hiddenSet.has(tag)) return;
        const name = String(rawName || "").trim();
        if (!name) return;
        const proto = String(protocols[tag] || "").toUpperCase();
        if (proto === "URLTEST" || proto === "SELECTOR") return;
        const trans = String(transports[tag] || "").toUpperCase();
        const badge =
          proto && trans && proto !== trans
            ? `${proto}+${trans}`
            : proto || trans;
        const label = badge ? `${name} [${badge}]` : name;
        if (!serverMap.has(name)) {
          serverMap.set(name, label);
        }
      });

      Object.values(countries).forEach((cc) => {
        const code = String(cc || "")
          .trim()
          .toUpperCase();
        if (code.length === 2) countrySet.add(code);
      });

      Object.values(prefixes).forEach((p) => {
        const pfx = String(p || "").trim();
        if (pfx) prefixSet.add(pfx);
      });
    });

    const servers = Array.from(serverMap.entries())
      .map(([value, label]) => ({ value, label }))
      .sort((a, b) => a.label.localeCompare(b.label));

    const countryMap = new Map(COMMON_COUNTRIES);
    countrySet.forEach((cc) => {
      if (!countryMap.has(cc)) {
        countryMap.set(cc, `${isoToFlagEmoji(cc)} ${cc}`);
      }
    });
    const countries = Array.from(countryMap.entries()).map(
      ([value, label]) => ({ value, label }),
    );

    const prefixes = Array.from(prefixSet).filter(Boolean);
    return { servers, countries, prefixes };
  });
}

function createChipToggleBar(inputEl, choices, isUpper) {
  const bar = E("div", {
    style: "display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px;",
  });
  const render = () => {
    bar.innerHTML = "";
    const current = new Set(
      asArray(inputEl.value).map((v) => (isUpper ? v.toUpperCase() : v)),
    );
    choices.forEach((ch) => {
      const val = typeof ch === "string" ? ch : ch.value;
      const lbl = typeof ch === "string" ? ch : ch.label;
      const norm = isUpper ? val.toUpperCase() : val;
      const active = current.has(norm);
      bar.appendChild(
        E(
          "button",
          {
            type: "button",
            class: "btn cbi-button",
            style: `padding: 2px 8px; font-size: 11px; line-height: 1.4; border-radius: 999px; ${
              active
                ? "background: rgba(59,130,246,0.22); border-color: #3b82f6; font-weight: 600;"
                : "opacity: 0.78;"
            }`,
            click: () => {
              const list = asArray(inputEl.value);
              const idx = list.findIndex(
                (x) => (isUpper ? x.toUpperCase() : x) === norm,
              );
              if (idx >= 0) list.splice(idx, 1);
              else list.push(norm);
              inputEl.value = list.join(", ");
              render();
            },
          },
          lbl,
        ),
      );
    });
  };
  inputEl.addEventListener("input", render);
  render();
  return { bar, render };
}

function createServerChecklistPicker(inputEl) {
  const container = E("div", { style: "margin-top: 6px;" });
  const searchInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: _("Search servers in pool..."),
    style: "width: 100%; margin-bottom: 6px; font-size: 12px;",
  });
  const listBox = E("div", {
    style:
      "max-height: 140px; overflow-y: auto; border: 1px solid rgba(128,128,128,0.25); border-radius: 6px; padding: 6px; display: flex; flex-wrap: wrap; gap: 4px;",
  });
  let allServers = [];

  const renderList = () => {
    listBox.innerHTML = "";
    if (!allServers.length) {
      listBox.appendChild(
        E(
          "span",
          { style: "font-size: 11px; opacity: 0.65;" },
          _(
            "No cached servers found yet — enter server names above or update subscriptions.",
          ),
        ),
      );
      return;
    }
    const q = searchInput.value.trim().toLowerCase();
    const selected = new Set(asArray(inputEl.value));
    const filtered = q
      ? allServers.filter(
          (s) =>
            s.label.toLowerCase().includes(q) ||
            s.value.toLowerCase().includes(q),
        )
      : allServers;

    filtered.slice(0, 120).forEach((srv) => {
      const active = selected.has(srv.value);
      listBox.appendChild(
        E(
          "button",
          {
            type: "button",
            class: "btn cbi-button",
            style: `padding: 2px 7px; font-size: 11px; line-height: 1.35; border-radius: 6px; ${
              active
                ? "background: rgba(59,130,246,0.22); border-color: #3b82f6; font-weight: 600;"
                : "opacity: 0.82;"
            }`,
            click: () => {
              const cur = asArray(inputEl.value);
              const idx = cur.indexOf(srv.value);
              if (idx >= 0) cur.splice(idx, 1);
              else cur.push(srv.value);
              inputEl.value = cur.join(", ");
              renderList();
            },
          },
          srv.label,
        ),
      );
    });
  };

  searchInput.addEventListener("input", renderList);
  inputEl.addEventListener("input", renderList);
  container.appendChild(searchInput);
  container.appendChild(listBox);

  return {
    node: container,
    setServers(servers) {
      allServers = servers || [];
      renderList();
    },
  };
}

function asArray(val) {
  if (!val) return [];
  if (Array.isArray(val))
    return val.map((v) => String(v).trim()).filter(Boolean);
  return String(val)
    .split(/[\s,]+/)
    .map((v) => v.trim())
    .filter(Boolean);
}

function shortenMiddle(str, maxLen) {
  const s = String(str || "").trim();
  if (s.length <= maxLen) return s;
  const head = Math.max(16, Math.floor(maxLen * 0.72));
  const tail = Math.max(6, maxLen - head - 1);
  return `${s.slice(0, head)}…${s.slice(-tail)}`;
}

function summarizeOutboundSource(sectionId) {
  const stype = (
    uci.get(UCI_PACKAGE, sectionId, "source_type") || "subscription"
  ).toLowerCase();
  const prefix = uci.get(UCI_PACKAGE, sectionId, "node_prefix") || "";
  const prefixTag = prefix ? ` [${_("Prefix")}: ${prefix}]` : "";

  if (stype === "subscription") {
    const url = uci.get(UCI_PACKAGE, sectionId, "url") || "";
    const shortUrl = url ? shortenMiddle(url, 48) : _("Not set");
    return `${_("Subscription")}: ${shortUrl}${prefixTag}`;
  }
  if (stype === "proxy_links" || stype === "links") {
    const links = asArray(
      uci.get(UCI_PACKAGE, sectionId, "proxy_links") ||
        uci.get(UCI_PACKAGE, sectionId, "selector_proxy_links"),
    );
    return `${_("Proxy Links")}: ${links.length}${prefixTag}`;
  }
  if (stype === "amnezia_config") {
    const cfgs = asArray(
      uci.get(UCI_PACKAGE, sectionId, "amnezia_configs") ||
        uci.get(UCI_PACKAGE, sectionId, "selector_amnezia_configs"),
    );
    return `Amnezia: ${cfgs.length || 1}${prefixTag}`;
  }
  if (stype === "awg") {
    const srv =
      uci.get(UCI_PACKAGE, sectionId, "awg_server_address") ||
      uci.get(UCI_PACKAGE, sectionId, "server") ||
      "";
    const port =
      uci.get(UCI_PACKAGE, sectionId, "awg_server_port") ||
      uci.get(UCI_PACKAGE, sectionId, "server_port") ||
      "51820";
    return `AmneziaWG: ${srv ? `${srv}:${port}` : _("Configured")}${prefixTag}`;
  }
  if (stype === "fptn") {
    const tok = uci.get(UCI_PACKAGE, sectionId, "access_token") || "";
    return `FPTN: ${tok ? tok.slice(0, 22) + "…" : _("Not set")}${prefixTag}`;
  }
  if (stype === "tor") {
    const port = uci.get(UCI_PACKAGE, sectionId, "tor_socks_port") || "9050";
    return `Tor SOCKS5 (127.0.0.1:${port})${prefixTag}`;
  }
  if (stype === "tailscale") {
    const iface =
      uci.get(UCI_PACKAGE, sectionId, "interface_name") || "tailscale0";
    return `Tailscale Mesh (${iface})${prefixTag}`;
  }
  if (stype === "interface") {
    const iface =
      uci.get(UCI_PACKAGE, sectionId, "interface_name") ||
      uci.get(UCI_PACKAGE, sectionId, "interface") ||
      "";
    return `${_("Network Interface")}: ${iface || _("Not set")}${prefixTag}`;
  }
  if (stype === "outbound_json" || stype === "json") {
    const jsons = asArray(uci.get(UCI_PACKAGE, sectionId, "outbound_jsons"));
    return `${_("JSON Outbounds")}: ${jsons.length || 1}${prefixTag}`;
  }
  if (stype === "zapret2") {
    const direct =
      uci.get(UCI_PACKAGE, sectionId, "direct_nfqws") === "1"
        ? " [Direct NFQUEUE]"
        : "";
    return `Zapret2 (nfqws2)${direct}`;
  }
  if (stype === "zapret") {
    const direct =
      uci.get(UCI_PACKAGE, sectionId, "direct_nfqws") === "1"
        ? " [Direct NFQUEUE]"
        : "";
    return `Zapret (nfqws)${direct}`;
  }
  if (stype === "byedpi") {
    const opts =
      uci.get(UCI_PACKAGE, sectionId, "byedpi_cmd_opts") ||
      BYEDPI_DEFAULT_CMD_OPTS;
    return `ByeDPI: ${shortenMiddle(opts, 42)}`;
  }
  if (stype === "desync") {
    const preset =
      uci.get(UCI_PACKAGE, sectionId, "desync_preset") || "google_youtube";
    return `Desync (${preset})`;
  }
  const srv =
    uci.get(UCI_PACKAGE, sectionId, "server") ||
    uci.get(UCI_PACKAGE, sectionId, `${stype}_server`) ||
    "";
  const port =
    uci.get(UCI_PACKAGE, sectionId, "server_port") ||
    uci.get(UCI_PACKAGE, sectionId, `${stype}_port`) ||
    "";
  return `${stype.toUpperCase()}${srv ? `: ${srv}${port ? ":" + port : ""}` : ""}${prefixTag}`;
}

function summarizeOutboundGroup(groupObj) {
  const parts = [];
  const srcs = asArray(groupObj.source_refs);
  parts.push(
    srcs.length
      ? `${_("Sources")}: ${srcs.join(", ")}`
      : `${_("Sources")}: ${_("All pool sources")}`,
  );
  const incPfx = asArray(groupObj.include_prefixes);
  if (incPfx.length) parts.push(`+${_("Prefix")}: ${incPfx.join(", ")}`);
  const excPfx = asArray(groupObj.exclude_prefixes);
  if (excPfx.length) parts.push(`-${_("Prefix")}: ${excPfx.join(", ")}`);
  const incC = asArray(groupObj.include_countries);
  if (incC.length)
    parts.push(`+${_("Flags")}: ${incC.join(", ").toUpperCase()}`);
  const excC = asArray(groupObj.exclude_countries);
  if (excC.length)
    parts.push(`-${_("Flags")}: ${excC.join(", ").toUpperCase()}`);
  const incSrv = asArray(groupObj.include_outbounds);
  if (incSrv.length) parts.push(`+${_("Servers")}: ${incSrv.length}`);
  const excSrv = asArray(groupObj.exclude_outbounds);
  if (excSrv.length) parts.push(`-${_("Servers")}: ${excSrv.length}`);
  const incRx = asArray(groupObj.include_regex);
  if (incRx.length) parts.push(`+${_("Regex")}: ${incRx.join(", ")}`);
  const excRx = asArray(groupObj.exclude_regex);
  if (excRx.length) parts.push(`-${_("Regex")}: ${excRx.join(", ")}`);
  const incProto = asArray(groupObj.include_protocols);
  if (incProto.length) parts.push(`+${_("Proto")}: ${incProto.join(", ")}`);
  const excProto = asArray(groupObj.exclude_protocols);
  if (excProto.length) parts.push(`-${_("Proto")}: ${excProto.join(", ")}`);
  const incTrans = asArray(groupObj.include_transports);
  if (incTrans.length) parts.push(`+${_("Transport")}: ${incTrans.join(", ")}`);
  const excTrans = asArray(groupObj.exclude_transports);
  if (excTrans.length) parts.push(`-${_("Transport")}: ${excTrans.join(", ")}`);
  const incSec = asArray(groupObj.include_securities);
  if (incSec.length) parts.push(`+${_("Security")}: ${incSec.join(", ")}`);
  const excSec = asArray(groupObj.exclude_securities);
  if (excSec.length) parts.push(`-${_("Security")}: ${excSec.join(", ")}`);
  const incPorts = asArray(groupObj.include_ports);
  if (incPorts.length) parts.push(`+${_("Ports")}: ${incPorts.join(", ")}`);
  const excPorts = asArray(groupObj.exclude_ports);
  if (excPorts.length) parts.push(`-${_("Ports")}: ${excPorts.join(", ")}`);
  return parts.join(" & ");
}

function showOutboundGroupModal(existingId, onSaved) {
  const isNew = !existingId;
  const grp = existingId ? uci.get(UCI_PACKAGE, existingId) || {} : {};

  const idInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: existingId || "",
    disabled: !isNew ? "disabled" : null,
    placeholder: _("e.g. Unlim_RU or Fast_EU"),
    style: "width: 100%;",
  });

  const nameInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: grp.name || existingId || "",
    placeholder: _("Display name, e.g. Unlim RU Servers"),
    style: "width: 100%;",
  });

  const modeSelect = E(
    "select",
    { class: "cbi-input-select", style: "width: 100%;" },
    [
      E(
        "option",
        { value: "mixed" },
        _("Include + Exclude (Intersection AND)"),
      ),
      E("option", { value: "include" }, _("Include Only (Intersection AND)")),
      E("option", { value: "exclude" }, _("Exclude Only")),
      E(
        "option",
        { value: "disabled" },
        _("No Filter (All nodes from selected sources)"),
      ),
    ],
  );
  modeSelect.value = grp.filter_mode || "mixed";

  const countryDetectSelect = E(
    "select",
    { class: "cbi-input-select", style: "width: 100%;" },
    [
      E("option", { value: "flag_emoji" }, _("By flag emoji from name")),
      E("option", { value: "country_is" }, _("Via country.is")),
    ],
  );
  countryDetectSelect.value = grp.detect_server_country || "flag_emoji";

  const srcRefsInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.source_refs).join(", "),
    placeholder: _(
      "Comma-separated Outbound Source IDs (leave empty for all sources)",
    ),
    style: "width: 100%;",
  });

  const incPfxInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_prefixes).join(", "),
    placeholder: _("e.g. Unlim, MainSub"),
    style: "width: 100%;",
  });

  const excPfxInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_prefixes).join(", "),
    placeholder: _("e.g. Backup"),
    style: "width: 100%;",
  });

  const incCountriesInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_countries).join(", "),
    placeholder: _("2-letter ISO codes, e.g. RU, NL, DE"),
    style: "width: 100%;",
  });

  const excCountriesInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_countries).join(", "),
    placeholder: _("e.g. US, GB"),
    style: "width: 100%;",
  });

  const incOutboundsInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_outbounds).join(", "),
    placeholder: _(
      "Select servers below or enter comma-separated server names",
    ),
    style: "width: 100%;",
  });

  const excOutboundsInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_outbounds).join(", "),
    placeholder: _(
      "Select servers below or enter comma-separated server names",
    ),
    style: "width: 100%;",
  });

  const incRegexInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_regex).join(", "),
    placeholder: _("e.g. torrent|gaming, VIP"),
    style: "width: 100%;",
  });

  const excRegexInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_regex).join(", "),
    placeholder: _("e.g. \\|WL\\|, Bypass"),
    style: "width: 100%;",
  });

  const incProtoInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_protocols).join(", "),
    placeholder: _("e.g. vless, hysteria2, amneziawg"),
    style: "width: 100%;",
  });

  const excProtoInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_protocols).join(", "),
    placeholder: _("e.g. shadowsocks, socks"),
    style: "width: 100%;",
  });

  const incTransInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_transports).join(", "),
    placeholder: _("e.g. tcp, ws, grpc, xhttp"),
    style: "width: 100%;",
  });

  const excTransInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_transports).join(", "),
    placeholder: _("e.g. ws, grpc"),
    style: "width: 100%;",
  });

  const incSecInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_securities).join(", "),
    placeholder: _("e.g. reality, tls, none"),
    style: "width: 100%;",
  });

  const excSecInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_securities).join(", "),
    placeholder: _("e.g. none"),
    style: "width: 100%;",
  });

  const incPortsInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.include_ports).join(", "),
    placeholder: _("e.g. 443, 8443, 2000-3000"),
    style: "width: 100%;",
  });

  const excPortsInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: asArray(grp.exclude_ports).join(", "),
    placeholder: _("e.g. 80, 8080"),
    style: "width: 100%;",
  });

  const sourceChoices = (uci.sections(UCI_PACKAGE, "outbound_source") || [])
    .filter(
      (s) =>
        s[".name"] &&
        !DPI_SOURCE_TYPES.has(
          String(s.source_type || "subscription").toLowerCase(),
        ),
    )
    .map((s) => ({
      value: s[".name"],
      label: `${s.name || s[".name"]}${s.node_prefix ? " [" + s.node_prefix + "]" : ""}`,
    }));
  const srcChips = createChipToggleBar(srcRefsInput, sourceChoices, false);
  const incCountryChips = createChipToggleBar(
    incCountriesInput,
    COMMON_COUNTRIES.map(([value, label]) => ({ value, label })),
    true,
  );
  const excCountryChips = createChipToggleBar(
    excCountriesInput,
    COMMON_COUNTRIES.map(([value, label]) => ({ value, label })),
    true,
  );
  const protoChips = createChipToggleBar(
    incProtoInput,
    PROTOCOL_CHOICES.map((p) => ({ value: p, label: p.toUpperCase() })),
    false,
  );
  const excProtoChips = createChipToggleBar(
    excProtoInput,
    PROTOCOL_CHOICES.map((p) => ({ value: p, label: p.toUpperCase() })),
    false,
  );
  const incTransChips = createChipToggleBar(
    incTransInput,
    TRANSPORT_CHOICES.map((t) => ({ value: t, label: t.toUpperCase() })),
    false,
  );
  const excTransChips = createChipToggleBar(
    excTransInput,
    TRANSPORT_CHOICES.map((t) => ({ value: t, label: t.toUpperCase() })),
    false,
  );
  const incSecChips = createChipToggleBar(
    incSecInput,
    SECURITY_CHOICES.map((s) => ({ value: s, label: s.toUpperCase() })),
    false,
  );
  const excSecChips = createChipToggleBar(
    excSecInput,
    SECURITY_CHOICES.map((s) => ({ value: s, label: s.toUpperCase() })),
    false,
  );
  const incPortsChips = createChipToggleBar(
    incPortsInput,
    PORT_CHOICES.map((p) => ({ value: p, label: p })),
    false,
  );
  const excPortsChips = createChipToggleBar(
    excPortsInput,
    PORT_CHOICES.map((p) => ({ value: p, label: p })),
    false,
  );
  const incPfxWrap = E("div", {});
  const excPfxWrap = E("div", {});
  const incServerPicker = createServerChecklistPicker(incOutboundsInput);
  const excServerPicker = createServerChecklistPicker(excOutboundsInput);

  loadGlobalPoolChoices().then((pool) => {
    incServerPicker.setServers(pool.servers);
    excServerPicker.setServers(pool.servers);
    if (pool.prefixes.length) {
      incPfxWrap.appendChild(
        createChipToggleBar(incPfxInput, pool.prefixes, false).bar,
      );
      excPfxWrap.appendChild(
        createChipToggleBar(excPfxInput, pool.prefixes, false).bar,
      );
    }
  });

  const fieldRow = (label, input, hint, extraNode) =>
    E("div", { class: "cbi-value" }, [
      E("label", { class: "cbi-value-title" }, label),
      E("div", { class: "cbi-value-field" }, [
        input,
        extraNode || "",
        hint ? E("div", { class: "cbi-value-description" }, hint) : "",
      ]),
    ]);

  ui.showModal(
    isNew
      ? _("Add Outbound Server Group")
      : `${_("Edit Outbound Group")}: ${existingId}`,
    [
      E("div", { class: "cbi-section-node" }, [
        fieldRow(
          _("Group ID (UCI)"),
          idInput,
          _("Unique identifier (letters, digits, underscores)."),
        ),
        fieldRow(_("Display Name"), nameInput),
        fieldRow(
          _("Source Pool References"),
          srcRefsInput,
          _(
            "Click sources below or leave empty to include all Global Outbound Sources.",
          ),
          srcChips.bar,
        ),
        fieldRow(
          _("Filter Mode"),
          modeSelect,
          _(
            "Non-empty include categories (Prefix, Country Flag, Servers, Regex, Protocol) are combined via logical AND (intersection).",
          ),
        ),
        fieldRow(_("Detect server country"), countryDetectSelect),
        fieldRow(
          _("Include Subscription Prefixes"),
          incPfxInput,
          null,
          incPfxWrap,
        ),
        fieldRow(
          _("Exclude Subscription Prefixes"),
          excPfxInput,
          null,
          excPfxWrap,
        ),
        fieldRow(
          _("Include Country Flags (ISO)"),
          incCountriesInput,
          null,
          incCountryChips.bar,
        ),
        fieldRow(
          _("Exclude Country Flags (ISO)"),
          excCountriesInput,
          null,
          excCountryChips.bar,
        ),
        fieldRow(
          _("Include Servers"),
          incOutboundsInput,
          _("Click servers from the pool below to include them in this group."),
          incServerPicker.node,
        ),
        fieldRow(
          _("Exclude Servers"),
          excOutboundsInput,
          _(
            "Click servers from the pool below to exclude them from this group.",
          ),
          excServerPicker.node,
        ),
        fieldRow(_("Include Name Regex"), incRegexInput),
        fieldRow(_("Exclude Name Regex"), excRegexInput),
        fieldRow(_("Include Protocols"), incProtoInput, null, protoChips.bar),
        fieldRow(
          _("Exclude Protocols"),
          excProtoInput,
          null,
          excProtoChips.bar,
        ),
        fieldRow(
          _("Include Transports"),
          incTransInput,
          null,
          incTransChips.bar,
        ),
        fieldRow(
          _("Exclude Transports"),
          excTransInput,
          null,
          excTransChips.bar,
        ),
        fieldRow(
          _("Include Security Types"),
          incSecInput,
          null,
          incSecChips.bar,
        ),
        fieldRow(
          _("Exclude Security Types"),
          excSecInput,
          null,
          excSecChips.bar,
        ),
        fieldRow(_("Include Ports"), incPortsInput, null, incPortsChips.bar),
        fieldRow(_("Exclude Ports"), excPortsInput, null, excPortsChips.bar),
      ]),
      E(
        "div",
        {
          class: "right",
          style:
            "margin-top: 12px; display: flex; justify-content: flex-end; gap: 8px;",
        },
        [
          E(
            "button",
            {
              type: "button",
              class: "btn cbi-button",
              click: () => ui.hideModal(),
            },
            _("Cancel"),
          ),
          E(
            "button",
            {
              type: "button",
              class: "btn cbi-button cbi-button-positive",
              click: () => {
                const rawId = (isNew ? idInput.value : existingId || "")
                  .trim()
                  .replace(/[^A-Za-z0-9_]/g, "_");
                if (!rawId) {
                  ui.addNotification(
                    null,
                    E("p", {}, _("Please enter a valid Group ID.")),
                    "error",
                  );
                  return;
                }
                if (isNew && uci.get(UCI_PACKAGE, rawId)) {
                  ui.addNotification(
                    null,
                    E("p", {}, _("A section with this ID already exists.")),
                    "error",
                  );
                  return;
                }
                if (isNew) {
                  uci.add(UCI_PACKAGE, "outbound_group", rawId);
                }
                uci.set(UCI_PACKAGE, rawId, "enabled", "1");
                uci.set(
                  UCI_PACKAGE,
                  rawId,
                  "name",
                  nameInput.value.trim() || rawId,
                );
                uci.set(UCI_PACKAGE, rawId, "filter_mode", modeSelect.value);
                uci.set(
                  UCI_PACKAGE,
                  rawId,
                  "detect_server_country",
                  countryDetectSelect.value || "flag_emoji",
                );

                const setListOrUnset = (key, rawText, upper) => {
                  const arr = asArray(rawText).map((v) =>
                    upper ? v.toUpperCase() : v,
                  );
                  if (arr.length) uci.set(UCI_PACKAGE, rawId, key, arr);
                  else uci.unset(UCI_PACKAGE, rawId, key);
                };

                setListOrUnset("source_refs", srcRefsInput.value, false);
                setListOrUnset("include_prefixes", incPfxInput.value, false);
                setListOrUnset("exclude_prefixes", excPfxInput.value, false);
                setListOrUnset(
                  "include_countries",
                  incCountriesInput.value,
                  true,
                );
                setListOrUnset(
                  "exclude_countries",
                  excCountriesInput.value,
                  true,
                );
                const splitCsv = (val) =>
                  String(val || "")
                    .split(",")
                    .map((s) => s.trim())
                    .filter(Boolean);
                const incSrvs = splitCsv(incOutboundsInput.value);
                if (incSrvs.length)
                  uci.set(UCI_PACKAGE, rawId, "include_outbounds", incSrvs);
                else uci.unset(UCI_PACKAGE, rawId, "include_outbounds");

                const excSrvs = splitCsv(excOutboundsInput.value);
                if (excSrvs.length)
                  uci.set(UCI_PACKAGE, rawId, "exclude_outbounds", excSrvs);
                else uci.unset(UCI_PACKAGE, rawId, "exclude_outbounds");

                setListOrUnset("include_regex", incRegexInput.value, false);
                setListOrUnset("exclude_regex", excRegexInput.value, false);

                const incProtos = asArray(incProtoInput.value).map((p) =>
                  p.toLowerCase(),
                );
                const incTrans = asArray(incTransInput.value).map((t) =>
                  t.toLowerCase(),
                );
                const incSecs = asArray(incSecInput.value).map((s) =>
                  s.toLowerCase(),
                );
                const incPorts = asArray(incPortsInput.value);
                if (incProtos.length)
                  uci.set(UCI_PACKAGE, rawId, "include_protocols", incProtos);
                else uci.unset(UCI_PACKAGE, rawId, "include_protocols");
                if (incTrans.length)
                  uci.set(UCI_PACKAGE, rawId, "include_transports", incTrans);
                else uci.unset(UCI_PACKAGE, rawId, "include_transports");
                if (incSecs.length)
                  uci.set(UCI_PACKAGE, rawId, "include_securities", incSecs);
                else uci.unset(UCI_PACKAGE, rawId, "include_securities");
                if (incPorts.length)
                  uci.set(UCI_PACKAGE, rawId, "include_ports", incPorts);
                else uci.unset(UCI_PACKAGE, rawId, "include_ports");

                if (
                  incProtos.length ||
                  incTrans.length ||
                  incSecs.length ||
                  incPorts.length
                ) {
                  uci.set(UCI_PACKAGE, rawId, "include_proxy_parameters", "1");
                } else {
                  uci.unset(UCI_PACKAGE, rawId, "include_proxy_parameters");
                }

                const excProtos = asArray(excProtoInput.value).map((p) =>
                  p.toLowerCase(),
                );
                const excTrans = asArray(excTransInput.value).map((t) =>
                  t.toLowerCase(),
                );
                const excSecs = asArray(excSecInput.value).map((s) =>
                  s.toLowerCase(),
                );
                const excPorts = asArray(excPortsInput.value);
                if (excProtos.length)
                  uci.set(UCI_PACKAGE, rawId, "exclude_protocols", excProtos);
                else uci.unset(UCI_PACKAGE, rawId, "exclude_protocols");
                if (excTrans.length)
                  uci.set(UCI_PACKAGE, rawId, "exclude_transports", excTrans);
                else uci.unset(UCI_PACKAGE, rawId, "exclude_transports");
                if (excSecs.length)
                  uci.set(UCI_PACKAGE, rawId, "exclude_securities", excSecs);
                else uci.unset(UCI_PACKAGE, rawId, "exclude_securities");
                if (excPorts.length)
                  uci.set(UCI_PACKAGE, rawId, "exclude_ports", excPorts);
                else uci.unset(UCI_PACKAGE, rawId, "exclude_ports");

                if (
                  excProtos.length ||
                  excTrans.length ||
                  excSecs.length ||
                  excPorts.length
                ) {
                  uci.set(UCI_PACKAGE, rawId, "exclude_proxy_parameters", "1");
                } else {
                  uci.unset(UCI_PACKAGE, rawId, "exclude_proxy_parameters");
                }

                ui.hideModal();
                if (typeof onSaved === "function") onSaved();
              },
            },
            _("Save Group"),
          ),
        ],
      ),
    ],
  );
}

function createOutboundGroupsAndProberPanel(sectionRef) {
  const wrapper = E("div", {});

  // Layer 2: Outbound Server Groups panel
  const groupsTableBody = E("tbody", {});

  function renderGroupsRows() {
    groupsTableBody.innerHTML = "";
    const groups = uci.sections(UCI_PACKAGE, "outbound_group") || [];
    if (!groups.length) {
      groupsTableBody.appendChild(
        E("tr", { class: "tr cbi-section-table-descr" }, [
          E(
            "td",
            { class: "td", colspan: "4" },
            E(
              "em",
              {},
              _(
                "No Outbound Groups defined yet. Create reusable filtered groups (by prefix, country flag, regex, protocol) to use in Sections and Priority Balancers.",
              ),
            ),
          ),
        ]),
      );
      return;
    }

    groups.forEach((g) => {
      const gid = g[".name"];
      groupsTableBody.appendChild(
        E("tr", { class: "tr" }, [
          E("td", { class: "td" }, E("strong", {}, g.name || gid)),
          E("td", { class: "td" }, E("code", {}, gid)),
          E("td", { class: "td" }, summarizeOutboundGroup(g)),
          E(
            "td",
            {
              class: "td cbi-section-table-cell",
              style: "white-space: nowrap;",
            },
            [
              E(
                "button",
                {
                  type: "button",
                  class: "btn cbi-button cbi-button-edit",
                  style: "margin-right: 6px;",
                  click: () =>
                    showOutboundGroupModal(gid, () => {
                      renderGroupsRows();
                      refreshProberGroupOptions();
                    }),
                },
                _("Edit"),
              ),
              E(
                "button",
                {
                  type: "button",
                  class: "btn cbi-button cbi-button-remove",
                  click: () => {
                    uci.remove(UCI_PACKAGE, gid);
                    renderGroupsRows();
                    refreshProberGroupOptions();
                  },
                },
                _("Delete"),
              ),
            ],
          ),
        ]),
      );
    });
  }

  const groupsSection = E(
    "div",
    { class: "cbi-section", style: "margin-top: 14px;" },
    [
      E("h3", {}, _("Layer 2: Reusable Outbound Server Groups")),
      E(
        "div",
        { class: "cbi-section-descr" },
        _(
          "Filter servers from the global pool by subscription prefix, country flag, regular expression, or protocol. Multiple include filters in a group act as an intersection (AND).",
        ),
      ),
      E("div", { class: "cbi-section-node" }, [
        E("table", { class: "table cbi-section-table" }, [
          E("thead", {}, [
            E("tr", { class: "tr cbi-section-table-titles" }, [
              E("th", { class: "th" }, _("Group Name")),
              E("th", { class: "th" }, _("ID")),
              E("th", { class: "th" }, _("Intersection Filter Criteria (AND)")),
              E("th", { class: "th" }, _("Actions")),
            ]),
          ]),
          groupsTableBody,
        ]),
        E("div", { class: "cbi-section-create", style: "padding: 8px 0;" }, [
          E(
            "button",
            {
              type: "button",
              class: "btn cbi-button cbi-button-add",
              click: () =>
                showOutboundGroupModal(null, () => {
                  renderGroupsRows();
                  refreshProberGroupOptions();
                }),
            },
            _("Add Outbound Group"),
          ),
        ]),
      ]),
    ],
  );

  // Manual URL Reachability Tester panel
  const urlInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    value: "https://www.gstatic.com/generate_204",
    placeholder: _(
      "Target URL to test (e.g. https://rutracker.org or https://www.gstatic.com/generate_204)",
    ),
    style: "flex: 2; min-width: 240px;",
  });

  const groupSelect = E("select", {
    class: "cbi-input-select",
    style: "min-width: 180px;",
  });

  function refreshProberGroupOptions() {
    const prev = groupSelect.value;
    groupSelect.innerHTML = "";
    groupSelect.appendChild(
      E("option", { value: "" }, _("All Active Outbound Servers")),
    );
    (uci.sections(UCI_PACKAGE, "outbound_source") || []).forEach((src) => {
      const sid = src[".name"];
      if (!sid) return;
      const stypeRaw = String(src.source_type || "subscription").toLowerCase();
      if (["zapret", "zapret2", "byedpi", "desync"].includes(stypeRaw)) return;
      const stype = stypeRaw.toUpperCase();
      groupSelect.appendChild(
        E(
          "option",
          { value: `src:${sid}` },
          `${_("Source")}: ${src.name || sid} [${stype}]`,
        ),
      );
    });
    (uci.sections(UCI_PACKAGE, "balancer") || []).forEach((bal) => {
      const bid = bal[".name"];
      if (!bid) return;
      groupSelect.appendChild(
        E(
          "option",
          { value: `bal:${bid}` },
          `${_("Auto-Select")}: ${bal.name || bid}`,
        ),
      );
    });
    (uci.sections(UCI_PACKAGE, "outbound_group") || []).forEach((g) => {
      const gid = g[".name"];
      groupSelect.appendChild(
        E("option", { value: gid }, `${_("Group")}: ${g.name || gid}`),
      );
    });
    if (prev) groupSelect.value = prev;
  }

  const probeResults = E("div", { style: "margin-top: 10px; display: none;" });

  const probeBtn = E(
    "button",
    {
      type: "button",
      class: "btn cbi-button cbi-button-action",
      click: async () => {
        const targetUrl = urlInput.value.trim();
        if (!targetUrl) return;
        probeBtn.disabled = true;
        probeResults.style.display = "block";
        probeResults.innerHTML = "";
        probeResults.appendChild(
          E("em", {}, _("Probing URL reachability across servers...")),
        );
        try {
          const probeArgs = [
            "probe_outbound_url",
            targetUrl,
            groupSelect.value || "all",
            "1800",
          ];
          let data = null;
          if (typeof fs.exec_direct === "function") {
            const rawOut = await fs.exec_direct(
              "/usr/bin/tachyon",
              probeArgs,
              "text",
            );
            data = rawOut ? JSON.parse(rawOut) : null;
          } else {
            const res = await fs.exec("/usr/bin/tachyon", probeArgs);
            data = res && res.stdout ? JSON.parse(res.stdout) : null;
          }
          probeResults.innerHTML = "";
          if (!data || !Array.isArray(data.results)) {
            probeResults.appendChild(
              E(
                "p",
                { class: "alert-message warning" },
                _(
                  "Could not probe servers. Make sure Tachyon service is running.",
                ),
              ),
            );
            return;
          }

          probeResults.appendChild(
            E(
              "p",
              {},
              _("Reachable servers: %d / %d for %s").format(
                data.reachable_count || 0,
                data.total_count || 0,
                data.url || targetUrl,
              ),
            ),
          );

          const rows = data.results.map((r) => {
            const cc = String(r.country || "").trim();
            const countryText = /^[A-Z]{2}$/.test(cc)
              ? `${isoToFlagEmoji(cc)} ${cc}`
              : cc || "—";
            return E("tr", { class: "tr" }, [
              E("td", { class: "td" }, r.name || r.tag),
              E("td", { class: "td" }, countryText),
              E("td", { class: "td" }, r.prefix || r.source || "—"),
              E(
                "td",
                { class: "td" },
                r.reachable
                  ? E(
                      "span",
                      {
                        style:
                          "color: var(--success-color, #27ae60); font-weight: bold;",
                      },
                      `✓ ${r.delay_ms} ms`,
                    )
                  : E(
                      "span",
                      { style: "color: var(--error-color, #e74c3c);" },
                      _("Unreachable"),
                    ),
              ),
            ]);
          });

          probeResults.appendChild(
            E("table", { class: "table cbi-section-table" }, [
              E("thead", {}, [
                E("tr", { class: "tr cbi-section-table-titles" }, [
                  E("th", { class: "th" }, _("Server")),
                  E("th", { class: "th" }, _("Country")),
                  E("th", { class: "th" }, _("Prefix / Source")),
                  E("th", { class: "th" }, _("Status / Latency")),
                ]),
              ]),
              E("tbody", {}, rows),
            ]),
          );
        } catch (err) {
          probeResults.innerHTML = "";
          probeResults.appendChild(
            E(
              "p",
              { class: "alert-message danger" },
              _("Probe error") + ": " + (err?.message || String(err)),
            ),
          );
        } finally {
          probeBtn.disabled = false;
        }
      },
    },
    _("Check URL Reachability"),
  );

  const proberSection = E(
    "div",
    { class: "cbi-section", style: "margin-top: 14px;" },
    [
      E("h3", {}, _("Manual URL Reachability Tester")),
      E(
        "div",
        { class: "cbi-section-descr" },
        _(
          "Test which servers in the pool or in a specific Outbound Group can reach a given URL right now.",
        ),
      ),
      E("div", { class: "cbi-section-node", style: "padding: 10px;" }, [
        E(
          "div",
          {
            style:
              "display: flex; flex-wrap: wrap; gap: 8px; align-items: center;",
          },
          [urlInput, groupSelect, probeBtn],
        ),
        probeResults,
      ]),
    ],
  );

  renderGroupsRows();
  refreshProberGroupOptions();

  wrapper.appendChild(groupsSection);
  wrapper.appendChild(proberSection);
  return wrapper;
}

function configureOutboundsSection(sectionRef) {
  const origAdd = sectionRef.handleAdd;
  sectionRef.handleAdd = function (ev, name) {
    const res = origAdd.apply(this, arguments);
    const sources = uci.sections(UCI_PACKAGE, "outbound_source") || [];
    const last = sources[sources.length - 1];
    if (last && last[".name"]) {
      const sid = last[".name"];
      if (!last.name) {
        uci.set(UCI_PACKAGE, sid, "name", sid);
      }
    }
    return res;
  };

  const origRender = sectionRef.render;
  sectionRef.render = function () {
    return origRender.apply(this, arguments).then((node) => {
      if (node) {
        node.appendChild(createOutboundGroupsAndProberPanel(sectionRef));
      }
      return node;
    });
  };
}

function escapeHtml(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function parseOpenvpnConfig(text) {
  const result = {};
  if (!text) return result;
  const extractTag = (tag) => {
    const re = new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`, "i");
    const m = text.match(re);
    return m ? m[1].trim() : null;
  };
  result.ca = extractTag("ca");
  result.cert = extractTag("cert");
  result.key = extractTag("key");
  result.tls_auth = extractTag("tls-auth");
  result.tls_crypt = extractTag("tls-crypt");

  const lines = text.split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    if (line.startsWith("<")) continue;
    const parts = line.split(/\s+/);
    const directive = parts[0].toLowerCase();
    if (directive === "remote" && parts.length >= 2) {
      result.server = parts[1];
      if (parts[2] && /^\d+$/.test(parts[2])) result.port = parts[2];
      if (parts[3])
        result.proto = parts[3].toLowerCase().startsWith("tcp") ? "tcp" : "udp";
    } else if (directive === "proto" && parts[1]) {
      result.proto = parts[1].toLowerCase().startsWith("tcp") ? "tcp" : "udp";
    } else if (directive === "port" && parts[1]) {
      result.port = parts[1];
    } else if (directive === "cipher" && parts[1]) {
      result.cipher = parts[1];
    } else if (directive === "auth" && parts[1]) {
      result.auth = parts[1];
    } else if (directive === "tun-mtu" && parts[1]) {
      result.mtu = parts[1];
    } else if (directive === "key-direction" && parts[1]) {
      result.key_direction = parts[1];
    }
  }
  return result;
}

function parseAwgConfigText(text) {
  const kv = {};
  String(text || "")
    .split(/\r?\n/)
    .forEach((raw) => {
      const line = raw.replace(/#.*$/, "").trim();
      const eq = line.indexOf("=");
      if (eq > 0) {
        const k = line.slice(0, eq).trim().toLowerCase();
        const v = line.slice(eq + 1).trim();
        kv[k] = v;
      }
    });
  return kv;
}

const PREFIX_COLOR_PRESETS = [
  { label: "Default", bg: "", color: "" },
  { label: "Blue", bg: "#dbeafe", color: "#1e40af" },
  { label: "Green", bg: "#dcfce7", color: "#166534" },
  { label: "Amber", bg: "#fef3c7", color: "#92400e" },
  { label: "Red", bg: "#fee2e2", color: "#991b1b" },
  { label: "Purple", bg: "#f3e8ff", color: "#6b21a8" },
  { label: "Cyan", bg: "#cffafe", color: "#155e75" },
  { label: "Pink", bg: "#fce7f3", color: "#9d174d" },
  { label: "Dark", bg: "#1e293b", color: "#f8fafc" },
];

const WDTT_DEFAULT_NFQWS2_OPT =
  "--filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5 --lua-desync=multisplit:pos=1,midsld --new --filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=fake_default_quic:repeats=6";

const OLCRTC_DEFAULT_NFQWS2_OPT =
  "--filter-udp=50000-65535 --filter-l7=stun,discord --lua-desync=fake:repeats=6 --new --filter-tcp=443 --filter-l7=tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_md5 --lua-desync=multidisorder:pos=1,midsld";

function setModalFieldValue(sectionRef, sectionId, optName, value) {
  uci.set(UCI_PACKAGE, sectionId, optName, value);
  try {
    const mapNode = document.querySelector(".cbi-modal") || document.body;
    const fieldId = `cbid.${UCI_PACKAGE}.${sectionId}.${optName}`;
    const el =
      mapNode.querySelector(`[id="${fieldId}"]`) ||
      mapNode.querySelector(`[name="${fieldId}"]`) ||
      mapNode.querySelector(
        `[data-field="${fieldId}"] input, [data-field="${fieldId}"] textarea, [data-field="${fieldId}"] select`,
      );
    if (el) {
      el.value = Array.isArray(value) ? value.join(", ") : String(value ?? "");
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    }
    const optObj =
      sectionRef &&
      Array.isArray(sectionRef.children) &&
      sectionRef.children.find((c) => c.option === optName);
    if (optObj && typeof optObj.getUIElement === "function") {
      const uiEl = optObj.getUIElement(sectionId);
      if (uiEl && typeof uiEl.setValue === "function") {
        uiEl.setValue(value);
      }
    }
  } catch (_e) {}
}

function createOutboundsContent(section) {
  section.tab("general", _("Source Settings"));
  section.tab("advanced", _("Advanced & Subscription Options"));

  let o = section.taboption("general", form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "5rem";

  o = section.taboption(
    "general",
    form.Value,
    "name",
    _("Connection Name"),
    _("Display name of this connection or server source in the global pool."),
  );
  o.rmempty = false;
  o.placeholder = _("e.g. Main Subscription, YouTube Zapret2, EU AWG");

  o = section.taboption(
    "general",
    form.ListValue,
    "source_type",
    _("Connection / Source Type"),
  );
  o.modalonly = true;
  o.default = "subscription";
  o.value("subscription", _("Subscription URL"));
  o.value(
    "proxy_links",
    _("Proxy Share Links (vless://, hysteria2://, ss://, etc.)"),
  );
  o.value(
    "amnezia_config",
    _("Amnezia / AmneziaWG Multi-Config (vpn:// or .conf files)"),
  );
  o.value("awg", _("AmneziaWG / WireGuard (Tunnel Parameters)"));
  o.value("warp", "Cloudflare WARP");
  o.value("fptn", _("FPTN VPN (fptn:// Access Token)"));
  o.value("openvpn", "OpenVPN (.ovpn)");
  o.value("anytls", "AnyTLS");
  o.value("naive", "NaiveProxy (HTTPS / QUIC)");
  o.value("mieru", "Mieru");
  o.value("snell", "Snell");
  o.value("sudoku", "Sudoku");
  o.value("masque", "MASQUE (HTTP/3 QUIC)");
  o.value("openconnect", "OpenConnect (Cisco AnyConnect / ocserv)");
  o.value("shadowtls", "ShadowTLS v3");
  o.value("trusttunnel", "TrustTunnel");
  o.value("tewfai", "TewFai");
  o.value("zapret2", _("Zapret2 (nfqws2 DPI Desync)"));
  o.value("zapret", _("Zapret (nfqws DPI Desync)"));
  o.value("byedpi", _("ByeDPI (ciadpi SOCKS5 Desync)"));
  o.value("desync", _("Desync (Built-in TCP/UDP DPI Fragmentation)"));
  o.value("wdtt", _("WDTT (nfqws2 Preset)"));
  o.value("olcrtc", _("OlcRTC (Discord / WebRTC nfqws2)"));
  o.value("tor", _("Tor Network (SOCKS5)"));
  o.value("tailscale", _("Tailscale Mesh VPN"));
  o.value("interface", _("Network Interface (WireGuard / OpenVPN / TUN)"));
  o.value("outbound_json", _("Sing-box Outbound JSON"));

  o = section.taboption(
    "general",
    form.DummyValue,
    "_used_in",
    _("Used in Sections"),
  );
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const used = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (sid && asArray(s.outbound_source_refs).includes(sectionId)) {
        used.push(s.name || sid);
      }
    });
    return used.length ? used.join(", ") : "—";
  };

  o = section.taboption(
    "general",
    form.DynamicList,
    "_target_sections",
    _("Used in Sections"),
    _(
      "Optional: select which routing Sections directly use this connection (you can also pick connections inside each Section).",
    ),
  );
  o.modalonly = true;
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    const used = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (!sid) return;
      this.value(sid, `${s.name || sid} (${sid})`);
      if (asArray(s.outbound_source_refs).includes(sectionId)) {
        used.push(sid);
      }
    });
    return used;
  };
  o.cfgvalue = function (sectionId) {
    const used = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (sid && asArray(s.outbound_source_refs).includes(sectionId)) {
        used.push(sid);
      }
    });
    return used;
  };
  o.write = function (sectionId, value) {
    const want = new Set(asArray(value));
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (!sid) return;
      const cur = asArray(s.outbound_source_refs);
      const has = cur.includes(sectionId);
      if (want.has(sid) && !has) {
        uci.set(UCI_PACKAGE, sid, "outbound_source_refs", [...cur, sectionId]);
      } else if (!want.has(sid) && has) {
        const next = cur.filter((id) => id !== sectionId);
        if (next.length)
          uci.set(UCI_PACKAGE, sid, "outbound_source_refs", next);
        else uci.unset(UCI_PACKAGE, sid, "outbound_source_refs");
      }
    });
  };
  o.remove = function (sectionId) {
    this.write(sectionId, []);
  };

  o = section.taboption("general", form.DummyValue, "_summary", _("Details"));
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const text = summarizeOutboundSource(sectionId);
    const fullUrl = uci.get(UCI_PACKAGE, sectionId, "url") || text;
    return `<span style="display:inline-block;max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom;" title="${escapeHtml(fullUrl)}">${escapeHtml(text)}</span>`;
  };
  o.textvalue = function (sectionId) {
    return this.cfgvalue(sectionId);
  };

  // ── 1. Subscription URL ───────────────────────────────────────────────────
  o = section.taboption(
    "general",
    form.Value,
    "url",
    _("Subscription URL"),
    _("HTTP/HTTPS subscription link imported into the global connection pool."),
  );
  o.modalonly = true;
  o.placeholder = "https://example.com/sub";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "general",
    form.Flag,
    "prefix_nodes",
    _("Add Prefix to Server Names"),
    _(
      "Prepend a custom badge/prefix to every server imported from this subscription.",
    ),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "subscription");
  o.cfgvalue = function (sectionId) {
    const explicit = uci.get(UCI_PACKAGE, sectionId, "prefix_nodes");
    if (explicit !== undefined && explicit !== null && explicit !== "")
      return explicit;
    return uci.get(UCI_PACKAGE, sectionId, "node_prefix") ? "1" : "0";
  };

  o = section.taboption(
    "general",
    form.Value,
    "node_prefix",
    _("Server Name Prefix"),
    _(
      "Prefix prepended to servers from this subscription (e.g. 'Unlim') so Outbound Groups and Balancers can filter by prefix.",
    ),
  );
  o.modalonly = true;
  o.placeholder = _("e.g. Unlim");
  o.depends({ source_type: "subscription", prefix_nodes: "1" });

  o = section.taboption(
    "general",
    form.Value,
    "node_prefix_bg",
    _("Prefix Badge Background Color"),
  );
  o.modalonly = true;
  o.placeholder = "#dbeafe";
  o.depends({ source_type: "subscription", prefix_nodes: "1" });

  o = section.taboption(
    "general",
    form.Value,
    "node_prefix_color",
    _("Prefix Badge Text Color"),
  );
  o.modalonly = true;
  o.placeholder = "#1e40af";
  o.depends({ source_type: "subscription", prefix_nodes: "1" });

  o = section.taboption(
    "general",
    form.DummyValue,
    "_prefix_color_presets",
    _("Prefix Color Presets"),
  );
  o.modalonly = true;
  o.depends({ source_type: "subscription", prefix_nodes: "1" });
  o.cfgvalue = function (sectionId) {
    const wrap = E("div", {
      style: "display: flex; flex-wrap: wrap; gap: 6px; align-items: center;",
    });
    PREFIX_COLOR_PRESETS.forEach((preset) => {
      const btn = E(
        "button",
        {
          type: "button",
          class: "btn cbi-button",
          style: `padding: 2px 10px; font-size: 12px; border-radius: 999px; ${
            preset.bg
              ? `background:${preset.bg};color:${preset.color};border-color:${preset.color};`
              : ""
          }`,
          click: () => {
            setModalFieldValue(section, sectionId, "node_prefix_bg", preset.bg);
            setModalFieldValue(
              section,
              sectionId,
              "node_prefix_color",
              preset.color,
            );
          },
        },
        preset.label,
      );
      wrap.appendChild(btn);
    });
    return wrap;
  };

  // ── 2. Proxy Share Links ──────────────────────────────────────────────────
  o = section.taboption(
    "general",
    form.DynamicList,
    "proxy_links",
    _("Proxy Share Links"),
    _(
      "vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, anytls://, naive+https://, mieru://, snell://, trusttunnel://, etc.",
    ),
  );
  o.modalonly = true;
  o.depends("source_type", "proxy_links");

  o = section.taboption(
    "general",
    form.TextValue,
    "_proxy_links_bulk",
    _("Bulk Paste Share Links (Multiline)"),
    _(
      "Optionally paste multiple share links (one per line); they will be merged into Proxy Share Links on save.",
    ),
  );
  o.modalonly = true;
  o.rows = 5;
  o.depends("source_type", "proxy_links");
  o.cfgvalue = function (sectionId) {
    return asArray(uci.get(UCI_PACKAGE, sectionId, "proxy_links")).join("\n");
  };
  o.write = function (sectionId, value) {
    const lines = String(value || "")
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (lines.length) {
      const existing = asArray(uci.get(UCI_PACKAGE, sectionId, "proxy_links"));
      const merged = Array.from(new Set([...existing, ...lines]));
      uci.set(UCI_PACKAGE, sectionId, "proxy_links", merged);
    }
  };

  // ── 3. Amnezia / AmneziaWG Multi-Config (vpn:// or .conf files) ───────────
  o = section.taboption(
    "general",
    form.Button,
    "_load_amnezia_confs",
    _("Upload WireGuard / AmneziaWG .conf Files"),
    _("Load one or multiple .conf files from your computer into this source."),
  );
  o.modalonly = true;
  o.inputtitle = _("Load .conf File(s)");
  o.inputstyle = "action";
  o.depends("source_type", "amnezia_config");
  o.onclick = function (ev, sectionId) {
    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.accept = ".conf,.wg,.txt";
    fileInput.multiple = true;
    fileInput.style.display = "none";
    document.body.appendChild(fileInput);
    fileInput.addEventListener("change", () => {
      const files = Array.from(fileInput.files || []);
      if (!files.length) {
        document.body.removeChild(fileInput);
        return;
      }
      Promise.all(
        files.map(
          (file) =>
            new Promise((resolve) => {
              const reader = new FileReader();
              reader.onload = (e) =>
                resolve({
                  name: file.name.replace(/\.(conf|wg|txt)$/i, ""),
                  config: String((e.target && e.target.result) || "").trim(),
                });
              reader.onerror = () => resolve(null);
              reader.readAsText(file);
            }),
        ),
      ).then((loaded) => {
        const valid = loaded.filter((item) => item && item.config);
        if (valid.length) {
          const cur = asArray(
            uci.get(UCI_PACKAGE, sectionId, "amnezia_configs"),
          );
          const next = [
            ...cur,
            ...valid.map((item) =>
              JSON.stringify({ name: item.name, config: item.config }),
            ),
          ];
          setModalFieldValue(section, sectionId, "amnezia_configs", next);
          if (valid.length === 1) {
            setModalFieldValue(
              section,
              sectionId,
              "amnezia_conf_text",
              valid[0].config,
            );
          }
          ui.addNotification(
            null,
            E("p", _("Loaded %d configuration file(s).").format(valid.length)),
            "info",
          );
        }
        document.body.removeChild(fileInput);
      });
    });
    fileInput.click();
  };

  o = section.taboption(
    "general",
    form.DynamicList,
    "amnezia_configs",
    _("Amnezia / AmneziaWG Configurations"),
    _("Paste vpn:// share links or upload .conf files using the button above."),
  );
  o.modalonly = true;
  o.depends("source_type", "amnezia_config");

  o = section.taboption(
    "general",
    form.TextValue,
    "amnezia_conf_text",
    _("AmneziaWG / WireGuard .conf Content"),
    _(
      "Optional raw WireGuard / AmneziaWG [Interface] + [Peer] configuration text.",
    ),
  );
  o.modalonly = true;
  o.rows = 6;
  o.depends("source_type", "amnezia_config");
  o.write = function (sectionId, value) {
    const trimmed = String(value || "").trim();
    if (!trimmed) return;
    uci.set(UCI_PACKAGE, sectionId, "amnezia_conf_text", trimmed);
    const cur = asArray(uci.get(UCI_PACKAGE, sectionId, "amnezia_configs"));
    const name = uci.get(UCI_PACKAGE, sectionId, "name") || sectionId;
    const serialized = JSON.stringify({ name, config: trimmed });
    if (!cur.includes(serialized) && !cur.includes(trimmed)) {
      uci.set(UCI_PACKAGE, sectionId, "amnezia_configs", [...cur, serialized]);
    }
  };

  // ── 4. AmneziaWG / WireGuard (Tunnel Parameters) ──────────────────────────
  o = section.taboption(
    "general",
    form.Button,
    "_generate_warp",
    _("Cloudflare WARP Generator"),
    _(
      "Automatically register a free Cloudflare WARP account and fill AmneziaWG parameters.",
    ),
  );
  o.modalonly = true;
  o.inputtitle = _("Generate WARP Config");
  o.inputstyle = "action";
  o.depends("source_type", "awg");
  o.onclick = function (ev, sectionId) {
    const btn = ev && ev.target ? ev.target : null;
    if (btn) btn.disabled = true;
    return fs
      .exec("/usr/bin/tachyon", ["generate_warp"])
      .then((res) => {
        const data = JSON.parse((res && res.stdout) || "{}");
        if (!data || data.error || !data.private_key) {
          throw new Error(
            (data && data.error) || _("Failed to generate WARP configuration"),
          );
        }
        setModalFieldValue(
          section,
          sectionId,
          "awg_private_key",
          data.private_key,
        );
        setModalFieldValue(
          section,
          sectionId,
          "awg_peer_public_key",
          data.peer_public_key || data.public_key || "",
        );
        setModalFieldValue(
          section,
          sectionId,
          "awg_server_address",
          data.server || "engage.cloudflareclient.com",
        );
        setModalFieldValue(
          section,
          sectionId,
          "awg_server_port",
          String(data.server_port || 2408),
        );
        const addrs = [];
        if (data.local_address) addrs.push(data.local_address);
        if (data.ipv6_address) addrs.push(data.ipv6_address);
        if (addrs.length) {
          setModalFieldValue(section, sectionId, "awg_local_address", addrs);
        }
        if (data.mtu) {
          setModalFieldValue(section, sectionId, "awg_mtu", String(data.mtu));
        }
        if (data.jc)
          setModalFieldValue(section, sectionId, "awg_jc", String(data.jc));
        if (data.jmin)
          setModalFieldValue(section, sectionId, "awg_jmin", String(data.jmin));
        if (data.jmax)
          setModalFieldValue(section, sectionId, "awg_jmax", String(data.jmax));
        if (data.s1)
          setModalFieldValue(section, sectionId, "awg_s1", String(data.s1));
        if (data.s2)
          setModalFieldValue(section, sectionId, "awg_s2", String(data.s2));
        if (data.h1)
          setModalFieldValue(section, sectionId, "awg_h1", String(data.h1));
        if (data.h2)
          setModalFieldValue(section, sectionId, "awg_h2", String(data.h2));
        if (data.h3)
          setModalFieldValue(section, sectionId, "awg_h3", String(data.h3));
        if (data.h4)
          setModalFieldValue(section, sectionId, "awg_h4", String(data.h4));
        ui.addNotification(
          null,
          E("p", _("WARP configuration generated and filled.")),
          "info",
        );
      })
      .catch((err) => {
        ui.addNotification(
          null,
          E("p", _("WARP generation failed: %s").format(err.message || err)),
          "error",
        );
      })
      .finally(() => {
        if (btn) btn.disabled = false;
      });
  };

  o = section.taboption(
    "general",
    form.Button,
    "_load_awg_conf",
    _("Import .conf File"),
    _(
      "Load an AmneziaWG or WireGuard .conf file to auto-fill all tunnel and obfuscation parameters.",
    ),
  );
  o.modalonly = true;
  o.inputtitle = _("Load .conf");
  o.inputstyle = "action";
  o.depends("source_type", "awg");
  o.onclick = function (ev, sectionId) {
    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.accept = ".conf,.wg,.txt";
    fileInput.style.display = "none";
    document.body.appendChild(fileInput);
    fileInput.addEventListener("change", () => {
      const file = fileInput.files && fileInput.files[0];
      if (!file) {
        document.body.removeChild(fileInput);
        return;
      }
      const reader = new FileReader();
      reader.onload = (e) => {
        const content = String((e.target && e.target.result) || "");
        const kv = parseAwgConfigText(content);
        if (kv.address) {
          const addrs = kv.address
            .split(",")
            .map((s) => s.trim())
            .filter(Boolean);
          setModalFieldValue(section, sectionId, "awg_local_address", addrs);
        }
        if (kv.privatekey)
          setModalFieldValue(
            section,
            sectionId,
            "awg_private_key",
            kv.privatekey,
          );
        if (kv.publickey)
          setModalFieldValue(
            section,
            sectionId,
            "awg_peer_public_key",
            kv.publickey,
          );
        if (kv.presharedkey)
          setModalFieldValue(
            section,
            sectionId,
            "awg_preshared_key",
            kv.presharedkey,
          );
        if (kv.mtu) setModalFieldValue(section, sectionId, "awg_mtu", kv.mtu);
        if (kv.persistentkeepalive)
          setModalFieldValue(
            section,
            sectionId,
            "awg_keepalive",
            kv.persistentkeepalive,
          );
        if (kv.endpoint) {
          const lastColon = kv.endpoint.lastIndexOf(":");
          if (lastColon > 0) {
            const host = kv.endpoint
              .slice(0, lastColon)
              .replace(/^\[|\]$/g, "");
            const port = kv.endpoint.slice(lastColon + 1);
            setModalFieldValue(section, sectionId, "awg_server_address", host);
            setModalFieldValue(section, sectionId, "awg_server_port", port);
          } else {
            setModalFieldValue(
              section,
              sectionId,
              "awg_server_address",
              kv.endpoint,
            );
          }
        }
        [
          "jc",
          "jmin",
          "jmax",
          "s1",
          "s2",
          "s3",
          "s4",
          "h1",
          "h2",
          "h3",
          "h4",
          "i1",
          "i2",
          "i3",
          "i4",
          "i5",
          "j1",
          "j2",
          "j3",
          "itime",
        ].forEach((k) => {
          if (kv[k] !== undefined)
            setModalFieldValue(section, sectionId, `awg_${k}`, kv[k]);
        });
        if (kv.headerprotectionkey) {
          setModalFieldValue(section, sectionId, "awg_version", "3.0");
          setModalFieldValue(
            section,
            sectionId,
            "awg_header_protection_key",
            kv.headerprotectionkey,
          );
        }
        if (kv.contentpaddingaddition)
          setModalFieldValue(
            section,
            sectionId,
            "awg_content_padding_addition",
            kv.contentpaddingaddition,
          );
        if (kv.rekeyaftertime)
          setModalFieldValue(
            section,
            sectionId,
            "awg_rekey_after_time",
            kv.rekeyaftertime,
          );
        if (kv.rekeytimeout)
          setModalFieldValue(
            section,
            sectionId,
            "awg_rekey_timeout",
            kv.rekeytimeout,
          );
        if (kv.rejectaftertime)
          setModalFieldValue(
            section,
            sectionId,
            "awg_reject_after_time",
            kv.rejectaftertime,
          );
        if (kv.keepalivetimeout)
          setModalFieldValue(
            section,
            sectionId,
            "awg_keepalive_timeout",
            kv.keepalivetimeout,
          );
        if (kv.maxhandshakeattempts)
          setModalFieldValue(
            section,
            sectionId,
            "awg_max_handshake_attempts",
            kv.maxhandshakeattempts,
          );
        if (kv.randomtrailers !== undefined) {
          setModalFieldValue(section, sectionId, "awg_version", "3.1");
          setModalFieldValue(
            section,
            sectionId,
            "awg_random_trailers",
            /^(1|true|yes|on)$/i.test(kv.randomtrailers) ? "1" : "0",
          );
        }
        if (kv.disablecookies !== undefined) {
          setModalFieldValue(section, sectionId, "awg_version", "3.1");
          setModalFieldValue(
            section,
            sectionId,
            "awg_disable_cookies",
            /^(1|true|yes|on)$/i.test(kv.disablecookies) ? "1" : "0",
          );
        }
        ui.addNotification(
          null,
          E(
            "p",
            _("AmneziaWG configuration loaded from %s.").format(file.name),
          ),
          "info",
        );
        document.body.removeChild(fileInput);
      };
      reader.readAsText(file);
    });
    fileInput.click();
  };

  o = section.taboption(
    "general",
    form.DynamicList,
    "awg_local_address",
    _("Client Tunnel IP / CIDR"),
    _("Interface IPv4/IPv6 addresses (e.g. 10.8.1.2/32)."),
  );
  o.modalonly = true;
  o.placeholder = "10.8.1.2/32";
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.Value,
    "awg_private_key",
    _("Client Private Key"),
  );
  o.modalonly = true;
  o.password = true;
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.Value,
    "awg_peer_public_key",
    _("Server Public Key"),
  );
  o.modalonly = true;
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.Value,
    "awg_preshared_key",
    _("Preshared Key (Optional)"),
  );
  o.modalonly = true;
  o.password = true;
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.Value,
    "awg_server_address",
    _("Server Endpoint Host / IP"),
  );
  o.modalonly = true;
  o.placeholder = "198.51.100.10";
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.Value,
    "awg_server_port",
    _("Server Endpoint Port"),
  );
  o.modalonly = true;
  o.default = "51820";
  o.placeholder = "51820";
  o.depends("source_type", "awg");

  o = section.taboption("general", form.Value, "awg_mtu", _("Tunnel MTU"));
  o.modalonly = true;
  o.placeholder = "1408";
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.Value,
    "awg_keepalive",
    _("Persistent Keepalive (s)"),
  );
  o.modalonly = true;
  o.placeholder = "25";
  o.depends("source_type", "awg");

  o = section.taboption(
    "general",
    form.ListValue,
    "awg_version",
    _("AmneziaWG Protocol Version"),
  );
  o.modalonly = true;
  o.default = "2.0";
  o.value("2.0", _("AWG 1.0 / 1.5 / 2.0 (Standard)"));
  o.value("3.0", _("AWG 3.0 (Header Protection & Timers)"));
  o.value("3.1", _("AWG 3.1 (Random Trailers & Cookie Control)"));
  o.depends("source_type", "awg");

  [
    ["awg_jc", "Jc (Junk Packet Count)", "4"],
    ["awg_jmin", "Jmin (Junk Min Size)", "40"],
    ["awg_jmax", "Jmax (Junk Max Size)", "70"],
    ["awg_s1", "S1 (Init Padding)", "0"],
    ["awg_s2", "S2 (Response Padding)", "0"],
    ["awg_s3", "S3 (Cookie Padding)", "0"],
    ["awg_s4", "S4 (Transport Padding)", "0"],
    ["awg_h1", "H1 (Init Header)", "1"],
    ["awg_h2", "H2 (Response Header)", "2"],
    ["awg_h3", "H3 (Cookie Header)", "3"],
    ["awg_h4", "H4 (Transport Header)", "4"],
    ["awg_i1", "I1 (Signature Packet 1)", ""],
    ["awg_i2", "I2 (Signature Packet 2)", ""],
    ["awg_i3", "I3 (Signature Packet 3)", ""],
    ["awg_i4", "I4 (Signature Packet 4)", ""],
    ["awg_i5", "I5 (Signature Packet 5)", ""],
    ["awg_j1", "J1 (Custom Junk 1)", ""],
    ["awg_j2", "J2 (Custom Junk 2)", ""],
    ["awg_j3", "J3 (Custom Junk 3)", ""],
    ["awg_itime", "Itime (Signature Timeout)", ""],
  ].forEach(([key, title, ph]) => {
    o = section.taboption("general", form.Value, key, _(title));
    o.modalonly = true;
    if (ph) o.placeholder = ph;
    o.depends("source_type", "awg");
  });

  [
    ["awg_header_protection_key", "HeaderProtectionKey (Base64)", ""],
    ["awg_content_padding_addition", "ContentPaddingAddition", "0"],
    ["awg_rekey_after_time", "RekeyAfterTime (s)", "120"],
    ["awg_rekey_timeout", "RekeyTimeout (s)", "5"],
    ["awg_reject_after_time", "RejectAfterTime (s)", "180"],
    ["awg_keepalive_timeout", "KeepaliveTimeout (s)", "10"],
    ["awg_max_handshake_attempts", "MaxHandshakeAttempts", "10"],
  ].forEach(([key, title, ph]) => {
    o = section.taboption("general", form.Value, key, _(title));
    o.modalonly = true;
    if (ph) o.placeholder = ph;
    o.depends({ source_type: "awg", awg_version: "3.0" });
    o.depends({ source_type: "awg", awg_version: "3.1" });
  });

  o = section.taboption(
    "general",
    form.Flag,
    "awg_random_trailers",
    _("RandomTrailers (AWG 3.1)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends({ source_type: "awg", awg_version: "3.1" });

  o = section.taboption(
    "general",
    form.Flag,
    "awg_disable_cookies",
    _("DisableCookies (AWG 3.1)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends({ source_type: "awg", awg_version: "3.1" });

  // ── 5. Cloudflare WARP ────────────────────────────────────────────────────
  o = section.taboption(
    "general",
    form.Button,
    "_generate_warp_proto",
    _("Cloudflare WARP Generator"),
    _(
      "Automatically register a free Cloudflare WARP account and fill all fields below.",
    ),
  );
  o.modalonly = true;
  o.inputtitle = _("Generate WARP Config");
  o.inputstyle = "action";
  o.depends("source_type", "warp");
  o.onclick = function (ev, sectionId) {
    const btn = ev && ev.target ? ev.target : null;
    if (btn) btn.disabled = true;
    return fs
      .exec("/usr/bin/tachyon", ["generate_warp"])
      .then((res) => {
        const data = JSON.parse((res && res.stdout) || "{}");
        if (!data || data.error || !data.private_key) {
          throw new Error(
            (data && data.error) || _("Failed to generate WARP configuration"),
          );
        }
        setModalFieldValue(
          section,
          sectionId,
          "warp_private_key",
          data.private_key,
        );
        setModalFieldValue(
          section,
          sectionId,
          "warp_peer_public_key",
          data.peer_public_key || data.public_key || "",
        );
        setModalFieldValue(
          section,
          sectionId,
          "warp_server",
          data.server || "engage.cloudflareclient.com",
        );
        setModalFieldValue(
          section,
          sectionId,
          "warp_server_port",
          String(data.server_port || 2408),
        );
        const addrs = [];
        if (data.local_address) addrs.push(data.local_address);
        if (data.ipv6_address) addrs.push(data.ipv6_address);
        if (addrs.length) {
          setModalFieldValue(section, sectionId, "warp_local_address", addrs);
        }
        if (Array.isArray(data.reserved)) {
          setModalFieldValue(
            section,
            sectionId,
            "warp_reserved",
            data.reserved.join(","),
          );
        }
        if (data.mtu) {
          setModalFieldValue(section, sectionId, "warp_mtu", String(data.mtu));
        }
        ui.addNotification(
          null,
          E("p", _("WARP configuration generated and filled.")),
          "info",
        );
      })
      .catch((err) => {
        ui.addNotification(
          null,
          E("p", _("WARP generation failed: %s").format(err.message || err)),
          "error",
        );
      })
      .finally(() => {
        if (btn) btn.disabled = false;
      });
  };

  o = section.taboption(
    "general",
    form.DynamicList,
    "warp_local_address",
    _("Client Tunnel IP / CIDR"),
  );
  o.modalonly = true;
  o.placeholder = "172.16.0.2/32";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_private_key",
    _("WARP Private Key"),
  );
  o.modalonly = true;
  o.password = true;
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_peer_public_key",
    _("WARP Peer Public Key"),
  );
  o.modalonly = true;
  o.placeholder = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_server",
    _("WARP Endpoint Server"),
  );
  o.modalonly = true;
  o.placeholder = "engage.cloudflareclient.com";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_server_port",
    _("WARP Endpoint Port"),
  );
  o.modalonly = true;
  o.placeholder = "2408";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_reserved",
    _("WARP Reserved Bytes"),
    _("3 comma-separated integers or Base64 client_id."),
  );
  o.modalonly = true;
  o.placeholder = "0,0,0";
  o.depends("source_type", "warp");

  o = section.taboption("general", form.Value, "warp_mtu", _("MTU"));
  o.modalonly = true;
  o.placeholder = "1280";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_fake_packets",
    _("Fake Packets Count Range"),
  );
  o.modalonly = true;
  o.placeholder = "5-10";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_fake_packets_size",
    _("Fake Packets Size Range"),
  );
  o.modalonly = true;
  o.placeholder = "40-100";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_fake_packets_delay",
    _("Fake Packets Delay Range (ms)"),
  );
  o.modalonly = true;
  o.placeholder = "20-250";
  o.depends("source_type", "warp");

  o = section.taboption(
    "general",
    form.Value,
    "warp_fake_packets_mode",
    _("Fake Packets Mode"),
  );
  o.modalonly = true;
  o.placeholder = "m4";
  o.depends("source_type", "warp");

  // ── 6. FPTN VPN ───────────────────────────────────────────────────────────
  o = section.taboption(
    "general",
    form.TextValue,
    "access_token",
    _("FPTN Access Token"),
    _("Paste fptn://, fptn:..., or fptnb:... access token."),
  );
  o.modalonly = true;
  o.rows = 3;
  o.placeholder = "fptn://...";
  o.depends("source_type", "fptn");

  o = section.taboption(
    "general",
    form.ListValue,
    "bypass_method",
    _("FPTN DPI Bypass Method"),
  );
  o.modalonly = true;
  o.default = "obfuscation";
  o.value("obfuscation", _("TLS Obfuscation (Default)"));
  o.value("split", _("TCP Fragmentation (Split)"));
  o.value("plain", _("Plain TLS"));
  o.value("auto-sni", _("Auto-SNI"));
  o.value("reality", _("REALITY Handshake"));
  o.depends("source_type", "fptn");

  o = section.taboption(
    "general",
    form.Value,
    "preferred_server",
    _("Preferred FPTN Server (Optional)"),
    _("Optional server name or IP from the token to prefer."),
  );
  o.modalonly = true;
  o.depends("source_type", "fptn");

  // ── 7. OpenVPN (.ovpn) ────────────────────────────────────────────────────
  o = section.taboption(
    "general",
    form.Button,
    "_load_openvpn_conf",
    _("Import .ovpn File"),
    _(
      "Upload an OpenVPN .ovpn file from your computer to populate all settings and certificates.",
    ),
  );
  o.modalonly = true;
  o.inputtitle = _("Load .ovpn");
  o.inputstyle = "action";
  o.depends("source_type", "openvpn");
  o.onclick = function (ev, sectionId) {
    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.accept = ".ovpn,.conf,.txt";
    fileInput.style.display = "none";
    document.body.appendChild(fileInput);
    fileInput.addEventListener("change", () => {
      const file = fileInput.files && fileInput.files[0];
      if (!file) {
        document.body.removeChild(fileInput);
        return;
      }
      const reader = new FileReader();
      reader.onload = (e) => {
        const content = String((e.target && e.target.result) || "");
        setModalFieldValue(section, sectionId, "openvpn_config", content);
        const parsed = parseOpenvpnConfig(content);
        if (parsed.server)
          setModalFieldValue(
            section,
            sectionId,
            "openvpn_server",
            parsed.server,
          );
        if (parsed.port)
          setModalFieldValue(
            section,
            sectionId,
            "openvpn_server_port",
            parsed.port,
          );
        if (parsed.proto)
          setModalFieldValue(section, sectionId, "openvpn_proto", parsed.proto);
        if (parsed.cipher)
          setModalFieldValue(
            section,
            sectionId,
            "openvpn_cipher",
            parsed.cipher,
          );
        if (parsed.auth)
          setModalFieldValue(section, sectionId, "openvpn_auth", parsed.auth);
        if (parsed.mtu)
          setModalFieldValue(section, sectionId, "openvpn_mtu", parsed.mtu);
        if (parsed.ca)
          setModalFieldValue(section, sectionId, "openvpn_ca", parsed.ca);
        if (parsed.cert)
          setModalFieldValue(section, sectionId, "openvpn_cert", parsed.cert);
        if (parsed.key)
          setModalFieldValue(section, sectionId, "openvpn_key", parsed.key);
        if (parsed.tls_auth)
          setModalFieldValue(
            section,
            sectionId,
            "openvpn_tls_auth",
            parsed.tls_auth,
          );
        if (parsed.tls_crypt)
          setModalFieldValue(
            section,
            sectionId,
            "openvpn_tls_crypt",
            parsed.tls_crypt,
          );
        if (parsed.key_direction !== undefined)
          setModalFieldValue(
            section,
            sectionId,
            "openvpn_key_direction",
            parsed.key_direction,
          );
        ui.addNotification(
          null,
          E("p", _("OpenVPN configuration loaded from %s.").format(file.name)),
          "info",
        );
        document.body.removeChild(fileInput);
      };
      reader.readAsText(file);
    });
    fileInput.click();
  };

  o = section.taboption(
    "general",
    form.Value,
    "openvpn_server",
    _("OpenVPN Server Host / IP"),
  );
  o.modalonly = true;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.Value,
    "openvpn_server_port",
    _("OpenVPN Server Port"),
  );
  o.modalonly = true;
  o.default = "1194";
  o.placeholder = "1194";
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.ListValue,
    "openvpn_proto",
    _("OpenVPN Protocol"),
  );
  o.modalonly = true;
  o.default = "udp";
  o.value("udp", "UDP");
  o.value("tcp", "TCP");
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.Value,
    "openvpn_username",
    _("Username (Optional)"),
  );
  o.modalonly = true;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.Value,
    "openvpn_password",
    _("Password (Optional)"),
  );
  o.modalonly = true;
  o.password = true;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.Value,
    "openvpn_cipher",
    _("Data Cipher"),
  );
  o.modalonly = true;
  o.placeholder = "AES-256-GCM";
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.Value,
    "openvpn_auth",
    _("Auth Digest"),
  );
  o.modalonly = true;
  o.placeholder = "SHA256";
  o.depends("source_type", "openvpn");

  o = section.taboption("general", form.Value, "openvpn_mtu", _("Tunnel MTU"));
  o.modalonly = true;
  o.placeholder = "1500";
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.TextValue,
    "openvpn_ca",
    _("CA Certificate (<ca>)"),
  );
  o.modalonly = true;
  o.rows = 4;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.TextValue,
    "openvpn_cert",
    _("Client Certificate (<cert>)"),
  );
  o.modalonly = true;
  o.rows = 4;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.TextValue,
    "openvpn_key",
    _("Client Private Key (<key>)"),
  );
  o.modalonly = true;
  o.rows = 4;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.TextValue,
    "openvpn_tls_auth",
    _("TLS-Auth Key (<tls-auth>)"),
  );
  o.modalonly = true;
  o.rows = 3;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.TextValue,
    "openvpn_tls_crypt",
    _("TLS-Crypt Key (<tls-crypt>)"),
  );
  o.modalonly = true;
  o.rows = 3;
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.ListValue,
    "openvpn_key_direction",
    _("Key Direction"),
  );
  o.modalonly = true;
  o.value("", _("Default / Bi-directional"));
  o.value("0", "0");
  o.value("1", "1");
  o.depends("source_type", "openvpn");

  o = section.taboption(
    "general",
    form.TextValue,
    "openvpn_config",
    _("Raw OpenVPN Configuration (.ovpn)"),
  );
  o.modalonly = true;
  o.rows = 6;
  o.depends("source_type", "openvpn");

  // ── 8. Direct Protocol Outbounds (AnyTLS, Naive, Mieru, Snell, Sudoku, MASQUE, OpenConnect, ShadowTLS, TrustTunnel, TewFai)
  const directProtoTypes = [
    "anytls",
    "naive",
    "mieru",
    "trusttunnel",
    "tewfai",
    "masque",
    "openconnect",
    "shadowtls",
    "snell",
    "sudoku",
  ];
  o = section.taboption("general", form.Value, "server", _("Server Host / IP"));
  o.modalonly = true;
  o.placeholder = "example.com";
  directProtoTypes.forEach((t) => o.depends("source_type", t));

  o = section.taboption("general", form.Value, "server_port", _("Server Port"));
  o.modalonly = true;
  o.default = "443";
  o.placeholder = "443";
  directProtoTypes.forEach((t) => o.depends("source_type", t));

  o = section.taboption(
    "general",
    form.Value,
    "username",
    _("Username / UUID"),
  );
  o.modalonly = true;
  ["naive", "mieru", "trusttunnel", "tewfai", "openconnect"].forEach((t) =>
    o.depends("source_type", t),
  );

  o = section.taboption(
    "general",
    form.Value,
    "password",
    _("Password / Key / PSK"),
  );
  o.modalonly = true;
  o.password = true;
  directProtoTypes.forEach((t) => o.depends("source_type", t));

  o = section.taboption(
    "general",
    form.Value,
    "sni",
    _("TLS SNI (Server Name)"),
  );
  o.modalonly = true;
  [
    "fptn",
    "anytls",
    "naive",
    "trusttunnel",
    "tewfai",
    "shadowtls",
    "masque",
  ].forEach((t) => o.depends("source_type", t));

  o = section.taboption(
    "general",
    form.Flag,
    "insecure",
    _("Skip TLS Certificate Verification (Insecure)"),
  );
  o.modalonly = true;
  o.default = "0";
  ["anytls", "naive", "trusttunnel", "tewfai", "masque", "openconnect"].forEach(
    (t) => o.depends("source_type", t),
  );

  // AnyTLS extras
  o = section.taboption(
    "general",
    form.DynamicList,
    "anytls_alpn",
    _("TLS ALPN"),
  );
  o.modalonly = true;
  o.placeholder = "h2";
  o.depends("source_type", "anytls");

  o = section.taboption(
    "general",
    form.Value,
    "anytls_idle_session_check_interval",
    _("Idle Session Check Interval"),
  );
  o.modalonly = true;
  o.placeholder = "30s";
  o.depends("source_type", "anytls");

  o = section.taboption(
    "general",
    form.Value,
    "anytls_idle_session_timeout",
    _("Idle Session Timeout"),
  );
  o.modalonly = true;
  o.placeholder = "30s";
  o.depends("source_type", "anytls");

  o = section.taboption(
    "general",
    form.Value,
    "anytls_min_idle_session",
    _("Minimum Idle Sessions"),
  );
  o.modalonly = true;
  o.placeholder = "5";
  o.depends("source_type", "anytls");

  // Snell extras
  o = section.taboption(
    "general",
    form.ListValue,
    "snell_version",
    _("Snell Protocol Version"),
  );
  o.modalonly = true;
  o.default = "4";
  o.value("4", "v4");
  o.value("3", "v3");
  o.value("2", "v2");
  o.value("1", "v1");
  o.depends("source_type", "snell");

  o = section.taboption(
    "general",
    form.ListValue,
    "snell_obfs",
    _("Obfuscation Mode"),
  );
  o.modalonly = true;
  o.value("", _("None"));
  o.value("http", "HTTP");
  o.value("tls", "TLS");
  o.depends("source_type", "snell");

  o = section.taboption(
    "general",
    form.Value,
    "snell_obfs_host",
    _("Obfuscation Host"),
  );
  o.modalonly = true;
  o.depends("source_type", "snell");

  o = section.taboption(
    "general",
    form.Flag,
    "snell_uot",
    _("UDP over TCP (UoT)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "snell");

  // Mieru extras
  o = section.taboption(
    "general",
    form.ListValue,
    "mieru_transport",
    _("Mieru Transport"),
  );
  o.modalonly = true;
  o.default = "TCP";
  o.value("TCP", "TCP");
  o.value("UDP", "UDP");
  o.depends("source_type", "mieru");

  o = section.taboption(
    "general",
    form.ListValue,
    "mieru_multiplexing",
    _("Multiplexing Level"),
  );
  o.modalonly = true;
  o.value("", _("Default"));
  o.value("MULTIPLEXING_OFF", "Off");
  o.value("MULTIPLEXING_LOW", "Low");
  o.value("MULTIPLEXING_MIDDLE", "Middle");
  o.value("MULTIPLEXING_HIGH", "High");
  o.depends("source_type", "mieru");

  o = section.taboption(
    "general",
    form.ListValue,
    "mieru_handshake_mode",
    _("Handshake Mode"),
  );
  o.modalonly = true;
  o.value("", _("Default"));
  o.value("HANDSHAKE_STANDARD", "Standard");
  o.value("HANDSHAKE_NO_WAIT", "No Wait (0-RTT)");
  o.depends("source_type", "mieru");

  // NaiveProxy extras
  o = section.taboption(
    "general",
    form.Flag,
    "naive_quic",
    _("Use QUIC (HTTP/3)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "naive");

  o = section.taboption(
    "general",
    form.ListValue,
    "naive_quic_congestion_control",
    _("QUIC Congestion Control"),
  );
  o.modalonly = true;
  o.value("", _("Default (BBR)"));
  o.value("bbr", "BBR");
  o.value("bbr2", "BBRv2");
  o.value("cubic", "CUBIC");
  o.value("reno", "Reno");
  o.depends({ source_type: "naive", naive_quic: "1" });

  o = section.taboption(
    "general",
    form.Value,
    "naive_insecure_concurrency",
    _("Insecure Concurrency"),
  );
  o.modalonly = true;
  o.placeholder = "1";
  o.depends("source_type", "naive");

  o = section.taboption(
    "general",
    form.Flag,
    "naive_udp_over_tcp",
    _("UDP over TCP"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "naive");

  o = section.taboption(
    "general",
    form.TextValue,
    "naive_extra_headers",
    _("Extra HTTP Headers"),
    _("One header per line (Header: Value)."),
  );
  o.modalonly = true;
  o.rows = 3;
  o.depends("source_type", "naive");

  // Sudoku extras
  o = section.taboption(
    "general",
    form.ListValue,
    "sudoku_aead",
    _("AEAD Cipher"),
  );
  o.modalonly = true;
  o.default = "chacha20-poly1305";
  o.value("chacha20-poly1305", "ChaCha20-Poly1305");
  o.value("aes-128-gcm", "AES-128-GCM");
  o.value("none", _("None"));
  o.depends("source_type", "sudoku");

  o = section.taboption("general", form.Value, "sudoku_ascii", _("ASCII Mode"));
  o.modalonly = true;
  o.placeholder = "prefer_entropy";
  o.depends("source_type", "sudoku");

  o = section.taboption(
    "general",
    form.Flag,
    "sudoku_http_mask",
    _("Enable HTTP Mask"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "sudoku");

  o = section.taboption(
    "general",
    form.Value,
    "sudoku_http_mask_host",
    _("HTTP Mask Host"),
  );
  o.modalonly = true;
  o.depends({ source_type: "sudoku", sudoku_http_mask: "1" });

  // MASQUE extras
  o = section.taboption("general", form.Flag, "masque_vhttp", _("vHTTP Mode"));
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "masque");

  o = section.taboption(
    "general",
    form.Value,
    "masque_public_key",
    _("Server Public Key (Base64 / PEM)"),
  );
  o.modalonly = true;
  o.depends("source_type", "masque");

  o = section.taboption(
    "general",
    form.Value,
    "masque_local_address",
    _("Client Tunnel IPv4 / CIDR"),
  );
  o.modalonly = true;
  o.placeholder = "172.16.0.2/32";
  o.depends("source_type", "masque");

  o = section.taboption(
    "general",
    form.Value,
    "masque_ipv6",
    _("Client Tunnel IPv6 / CIDR"),
  );
  o.modalonly = true;
  o.depends("source_type", "masque");

  o = section.taboption("general", form.Value, "masque_uri", _("MASQUE URI"));
  o.modalonly = true;
  o.placeholder =
    "https://example.com/.well-known/masque/udp/{target_host}/{target_port}/";
  o.depends("source_type", "masque");

  o = section.taboption("general", form.Value, "masque_mtu", _("MASQUE MTU"));
  o.modalonly = true;
  o.placeholder = "1280";
  o.depends("source_type", "masque");

  // OpenConnect extras
  o = section.taboption(
    "general",
    form.ListValue,
    "openconnect_protocol",
    _("VPN Protocol"),
  );
  o.modalonly = true;
  o.default = "anyconnect";
  o.value("anyconnect", "Cisco AnyConnect / ocserv");
  o.value("gp", "Palo Alto GlobalProtect");
  o.value("nc", "Juniper Network Connect");
  o.value("pulse", "Pulse Connect Secure");
  o.value("f5", "F5 Big-IP");
  o.value("fortinet", "Fortinet FortiGate");
  o.value("array", "Array Networks");
  o.depends("source_type", "openconnect");

  o = section.taboption(
    "general",
    form.Value,
    "openconnect_authgroup",
    _("Auth Group"),
  );
  o.modalonly = true;
  o.depends("source_type", "openconnect");

  o = section.taboption(
    "general",
    form.Value,
    "openconnect_servercert",
    _("Server Certificate PIN (pin-sha256:...)"),
  );
  o.modalonly = true;
  o.depends("source_type", "openconnect");

  o = section.taboption(
    "general",
    form.Flag,
    "openconnect_no_dtls",
    _("Disable DTLS (TCP/TLS Only)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "openconnect");

  // ShadowTLS extras
  o = section.taboption(
    "general",
    form.ListValue,
    "shadowtls_version",
    _("ShadowTLS Version"),
  );
  o.modalonly = true;
  o.default = "3";
  o.value("3", "v3");
  o.value("2", "v2");
  o.value("1", "v1");
  o.depends("source_type", "shadowtls");

  // TrustTunnel extras
  o = section.taboption(
    "general",
    form.Flag,
    "trusttunnel_quic",
    _("Use QUIC (HTTP/3)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "trusttunnel");

  o = section.taboption(
    "general",
    form.Flag,
    "trusttunnel_health_check",
    _("Enable Health Check"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "trusttunnel");

  // TewFai extras
  o = section.taboption(
    "general",
    form.DynamicList,
    "tewfai_transport",
    _("Transport Race List"),
    _("Transports to race (e.g. tcp, quic, h3_datagram, h2, ws)"),
  );
  o.modalonly = true;
  o.value("tcp", "TCP");
  o.value("quic", "QUIC");
  o.value("h3_datagram", "H3 Datagram");
  o.value("h3_stream", "H3 Stream");
  o.value("h2", "HTTP/2");
  o.value("ws", "WebSocket");
  o.value("raw_tls", "Raw TLS");
  o.depends("source_type", "tewfai");

  o = section.taboption(
    "general",
    form.ListValue,
    "tewfai_inner_cipher",
    _("Inner Cipher"),
  );
  o.modalonly = true;
  o.value("", _("Auto (Default)"));
  o.value("aes-256-gcm", "AES-256-GCM");
  o.value("none", _("None"));
  o.depends("source_type", "tewfai");

  o = section.taboption(
    "general",
    form.ListValue,
    "tewfai_morph_profile",
    _("Morph Profile"),
  );
  o.modalonly = true;
  o.value("", _("None (Default)"));
  o.value("browsing", "Browsing");
  o.value("video", "Video");
  o.value("webrtc", "WebRTC");
  o.value("bulk", "Bulk");
  o.depends("source_type", "tewfai");

  // ── 9. Network Interface / Tailscale / Tor / JSON ─────────────────────────
  o = section.taboption(
    "general",
    form.Value,
    "tor_socks_port",
    _("Tor SOCKS5 Port"),
    _("Local Tor SOCKS5 port on router (default: 9050)."),
  );
  o.modalonly = true;
  o.default = "9050";
  o.placeholder = "9050";
  o.depends("source_type", "tor");

  o = section.taboption(
    "general",
    form.Value,
    "interface_name",
    _("Network Interface Name"),
    _("e.g. wg0, awg0, tun0, tailscale0"),
  );
  o.modalonly = true;
  o.placeholder = "wg0";
  o.depends("source_type", "interface");
  o.depends("source_type", "tailscale");

  o = section.taboption(
    "general",
    form.Flag,
    "domain_resolver_enabled",
    _("Custom Domain Resolver for Interface"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "interface");

  o = section.taboption(
    "general",
    form.ListValue,
    "domain_resolver_dns_type",
    _("Resolver Protocol"),
  );
  o.modalonly = true;
  o.default = "udp";
  o.value("udp", "UDP");
  o.value("tcp", "TCP");
  o.value("tls", "DoT (TLS)");
  o.value("https", "DoH (HTTPS)");
  o.depends({ source_type: "interface", domain_resolver_enabled: "1" });

  o = section.taboption(
    "general",
    form.Value,
    "domain_resolver_dns_server",
    _("Resolver DNS Server"),
  );
  o.modalonly = true;
  o.placeholder = "1.1.1.1";
  o.depends({ source_type: "interface", domain_resolver_enabled: "1" });

  o = section.taboption(
    "general",
    form.DynamicList,
    "outbound_jsons",
    _("Outbound JSON Objects"),
    _("Raw sing-box outbound JSON objects."),
  );
  o.modalonly = true;
  o.depends("source_type", "outbound_json");

  // ── 10. DPI Desync Sources (Zapret2, Zapret, ByeDPI, Native Desync, WDTT, OlcRTC)
  o = section.taboption(
    "general",
    form.TextValue,
    "nfqws2_opt",
    _("NFQWS2 Strategy"),
    _("Command-line strategy arguments for nfqws2 (zapret2 / wdtt / olcrtc)."),
  );
  o.modalonly = true;
  o.rows = 6;
  o.wrap = "soft";
  o.default = ZAPRET2_DEFAULT_NFQWS2_OPT;
  o.depends("source_type", "zapret2");
  o.depends("source_type", "wdtt");
  o.depends("source_type", "olcrtc");
  o.load = function (sectionId) {
    const existing = uci.get(UCI_PACKAGE, sectionId, "nfqws2_opt");
    if (existing) return existing;
    const stype = uci.get(UCI_PACKAGE, sectionId, "source_type");
    if (stype === "wdtt") return WDTT_DEFAULT_NFQWS2_OPT;
    if (stype === "olcrtc") return OLCRTC_DEFAULT_NFQWS2_OPT;
    return ZAPRET2_DEFAULT_NFQWS2_OPT;
  };

  o = section.taboption(
    "general",
    form.TextValue,
    "nfqws_opt",
    _("NFQWS Strategy"),
    _("Command-line strategy arguments for nfqws (zapret)."),
  );
  o.modalonly = true;
  o.rows = 6;
  o.wrap = "soft";
  o.default = ZAPRET_DEFAULT_NFQWS_OPT;
  o.depends("source_type", "zapret");
  o.load = function (sectionId) {
    return (
      uci.get(UCI_PACKAGE, sectionId, "nfqws_opt") || ZAPRET_DEFAULT_NFQWS_OPT
    );
  };

  o = section.taboption(
    "general",
    form.Flag,
    "direct_nfqws",
    _("Direct NFQUEUE Mode (Bypass Proxy Core)"),
    _(
      "Route matched traffic directly into kernel NFQUEUE via nftables without passing through sing-box/tachyon-core.",
    ),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "zapret2");
  o.depends("source_type", "zapret");
  o.depends("source_type", "wdtt");
  o.depends("source_type", "olcrtc");

  o = section.taboption(
    "general",
    form.TextValue,
    "byedpi_cmd_opts",
    _("ByeDPI Strategy"),
    _("Command-line strategy arguments for ciadpi (ByeDPI)."),
  );
  o.modalonly = true;
  o.rows = 5;
  o.wrap = "soft";
  o.default = BYEDPI_DEFAULT_CMD_OPTS;
  o.depends("source_type", "byedpi");
  o.load = function (sectionId) {
    return (
      uci.get(UCI_PACKAGE, sectionId, "byedpi_cmd_opts") ||
      BYEDPI_DEFAULT_CMD_OPTS
    );
  };

  o = section.taboption(
    "general",
    form.ListValue,
    "desync_preset",
    _("Desync Preset"),
    _("Pre-configured DPI bypass profile for tachyon-core native desync."),
  );
  o.modalonly = true;
  o.default = "fake_split";
  o.value("fake_split", _("Fake + Split (midsld, TTL=5) — Recommended"));
  o.value("tlsrec", _("TLS Record Fragmentation (tlsrec, midsld)"));
  o.value("disorder", _("Fake + Disorder (Out-of-order, TTL=5)"));
  o.value("split", _("TCP Split Only (midsld)"));
  o.value("fake", _("Fake Packet Injection Only (TTL=5)"));
  o.value("oob", _("TCP Urgent OOB Desync (midsld)"));
  o.value("auto", _("Auto (Fake + Split)"));
  o.value("custom", _("Custom Parameters"));
  o.depends("source_type", "desync");

  o = section.taboption(
    "general",
    form.ListValue,
    "desync_mode",
    _("Desync Mode"),
  );
  o.modalonly = true;
  o.default = "fake_split";
  o.value("fake_split", "fake_split (Fake + Split)");
  o.value("tlsrec", "tlsrec (TLS Record Fragmentation)");
  o.value("disorder", "disorder (Fake + Out-of-order Split)");
  o.value("split", "split (TCP Segment Split)");
  o.value("fake", "fake (Fake Packet Only)");
  o.value("oob", "oob (TCP Urgent OOB)");
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Value,
    "desync_split_pos",
    _("Split Position"),
    _("midsld, sni, or byte offset (1..1400)"),
  );
  o.modalonly = true;
  o.placeholder = "midsld";
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Value,
    "desync_fake_ttl",
    _("Fake Packet TTL"),
  );
  o.modalonly = true;
  o.placeholder = "4";
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Value,
    "desync_fake_sni",
    _("Fake SNI"),
  );
  o.modalonly = true;
  o.placeholder = "www.google.com";
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Value,
    "desync_repeats",
    _("Fake Repeats"),
  );
  o.modalonly = true;
  o.placeholder = "2";
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Value,
    "desync_split_delay_ms",
    _("Split Delay (ms)"),
  );
  o.modalonly = true;
  o.placeholder = "2";
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Flag,
    "desync_udp_fake",
    _("UDP Fake (QUIC / Voice)"),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends({ source_type: "desync", desync_preset: "custom" });

  o = section.taboption(
    "general",
    form.Value,
    "desync_udp_repeats",
    _("UDP Fake Repeats"),
  );
  o.modalonly = true;
  o.placeholder = "4";
  o.depends({
    source_type: "desync",
    desync_preset: "custom",
    desync_udp_fake: "1",
  });

  o = section.taboption(
    "general",
    form.Value,
    "desync_udp_fake_ttl",
    _("UDP Fake TTL"),
  );
  o.modalonly = true;
  o.placeholder = "3";
  o.depends({
    source_type: "desync",
    desync_preset: "custom",
    desync_udp_fake: "1",
  });

  o = section.taboption(
    "general",
    form.Value,
    "desync_opts",
    _("Desync Strategy String (Fuzzer / CLI)"),
  );
  o.modalonly = true;
  o.depends("source_type", "desync");

  // ── 11. Advanced & Subscription Options Tab ───────────────────────────────
  o = section.taboption(
    "advanced",
    form.Flag,
    "subscription_update_enabled",
    _("Auto-update Subscription"),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.Value,
    "subscription_update_interval",
    _("Update Interval"),
  );
  o.modalonly = true;
  o.default = "1h";
  o.placeholder = "1h";
  o.depends({
    source_type: "subscription",
    subscription_update_enabled: "1",
  });

  o = section.taboption(
    "advanced",
    form.Flag,
    "download_via_proxy_enabled",
    _("Download Subscription via Proxy Section"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.ListValue,
    "download_via_proxy_section",
    _("Proxy Section for Download"),
  );
  o.modalonly = true;
  o.depends({
    source_type: "subscription",
    download_via_proxy_enabled: "1",
  });
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (sid) this.value(sid, `${s.name || sid} (${sid})`);
    });
    return uci.get(UCI_PACKAGE, sectionId, "download_via_proxy_section");
  };

  o = section.taboption(
    "advanced",
    form.Flag,
    "auto_user_agent",
    _("Automatic User-Agent"),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.Value,
    "user_agent",
    _("Custom User-Agent / Client Profile"),
  );
  o.modalonly = true;
  o.value("sing-box", "sing-box (Default)");
  o.value("Happ/3.7.1", "Happ (Happ/3.7.1)");
  o.value("v2rayN/7.12", "v2rayN (v2rayN/7.12)");
  o.value(
    "ClashMetaForAndroid/2.11.5.Meta",
    "Clash Meta for Android (2.11.5.Meta)",
  );
  o.value("FlClash/v0.8.72", "FlClash (v0.8.72)");
  o.value("HiddifyNext/2.5.7", "HiddifyNext (2.5.7)");
  o.value("Koala Clash/v0.2.8", "Koala Clash (v0.2.8)");
  o.value("Mihomo/1.19.0", "Mihomo (1.19.0)");
  o.value("Shadowrocket/2075", "Shadowrocket (2075)");
  o.depends({ source_type: "subscription", auto_user_agent: "0" });

  o = section.taboption(
    "advanced",
    form.Flag,
    "auto_hwid",
    _("Automatic HWID Header (x-hwid)"),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.Value,
    "hwid",
    _("Custom HWID (x-hwid)"),
  );
  o.modalonly = true;
  o.placeholder = "16-64 hex characters";
  o.depends({ source_type: "subscription", auto_hwid: "0" });

  o = section.taboption(
    "advanced",
    form.Button,
    "_generate_hwid",
    _("Generate Random HWID"),
  );
  o.modalonly = true;
  o.inputtitle = _("Generate HWID");
  o.inputstyle = "action";
  o.depends({ source_type: "subscription", auto_hwid: "0" });
  o.onclick = function (_ev, sectionId) {
    const bytes = new Uint8Array(8);
    if (typeof crypto !== "undefined" && crypto.getRandomValues) {
      crypto.getRandomValues(bytes);
    } else {
      for (let i = 0; i < 8; i++) bytes[i] = Math.floor(Math.random() * 256);
    }
    const hex = Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    setModalFieldValue(section, sectionId, "hwid", hex);
  };

  o = section.taboption(
    "advanced",
    form.Flag,
    "custom_device_headers",
    _("Custom Device Metadata Headers"),
    _(
      "Send custom x-device-os, x-ver-os, x-device-model, and x-device-locale headers.",
    ),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "subscription");

  [
    ["device_os", "Device OS (x-device-os)", "Android"],
    ["ver_os", "OS Version (x-ver-os)", "14"],
    ["device_model", "Device Model (x-device-model)", "Pixel 8"],
    ["device_locale", "Device Locale (x-device-locale)", "en-US"],
    ["app_version", "App Version", "3.7.1"],
    ["accept_language", "Accept-Language Header", "en-US,en;q=0.9"],
  ].forEach(([key, title, ph]) => {
    o = section.taboption("advanced", form.Value, key, _(title));
    o.modalonly = true;
    o.placeholder = ph;
    o.depends({ source_type: "subscription", custom_device_headers: "1" });
  });

  o = section.taboption(
    "advanced",
    form.Flag,
    "show_dashboard_metadata",
    _("Show Subscription Quota on Dashboard"),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.Flag,
    "include_urltest_groups",
    _("Import URLTest / Selector Groups from Subscription"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.Flag,
    "hide_urltest_group_outbounds",
    _("Hide Individual Servers Inside Imported Groups"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends({
    source_type: "subscription",
    include_urltest_groups: "1",
  });

  o = section.taboption(
    "advanced",
    form.Value,
    "urltest_idle_timeout",
    _("Imported URLTest Idle Timeout"),
  );
  o.modalonly = true;
  o.placeholder = "30m";
  o.depends({
    source_type: "subscription",
    include_urltest_groups: "1",
  });

  o = section.taboption(
    "advanced",
    form.Flag,
    "hide_detour_outbounds",
    _("Hide Intermediate Detour Outbounds"),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.Flag,
    "subscription_insecure",
    _("Skip TLS Verification for Imported Nodes (insecure)"),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.DynamicList,
    "subscription_filter_include_keywords",
    _("Include Server Keywords"),
    _(
      "Only import subscription servers whose name matches at least one keyword.",
    ),
  );
  o.modalonly = true;
  o.depends("source_type", "subscription");

  o = section.taboption(
    "advanced",
    form.DynamicList,
    "subscription_filter_exclude_keywords",
    _("Exclude Server Keywords"),
    _("Skip subscription servers whose name matches any of these keywords."),
  );
  o.modalonly = true;
  o.depends("source_type", "subscription");

  // Outbound Detour (Chain via another section)
  o = section.taboption(
    "advanced",
    form.Flag,
    "outbound_detour_enabled",
    _("Chain via Another Section (Detour)"),
    _(
      "Route this connection's upstream traffic through another routing Section.",
    ),
  );
  o.modalonly = true;
  o.default = "0";

  o = section.taboption(
    "advanced",
    form.ListValue,
    "outbound_detour_section",
    _("Detour Target Section"),
  );
  o.modalonly = true;
  o.depends("outbound_detour_enabled", "1");
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (sid) this.value(sid, `${s.name || sid} (${sid})`);
    });
    return uci.get(UCI_PACKAGE, sectionId, "outbound_detour_section");
  };
}

return baseclass.extend({
  configureOutboundsSection,
  createOutboundsContent,
});
