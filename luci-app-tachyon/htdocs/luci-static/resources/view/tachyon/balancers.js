"use strict";
"require baseclass";
"require form";
"require fs";
"require uci";
"require view.tachyon.main as main";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE || "tachyon";
const SECTION_CACHE_DIR = "/var/run/tachyon/section-cache";

const COMMON_COUNTRIES = [
  ["NL", "🇳🇱 Netherlands (NL)"],
  ["DE", "🇩🇪 Germany (DE)"],
  ["FI", "🇫🇮 Finland (FI)"],
  ["FR", "🇫🇷 France (FR)"],
  ["GB", "🇬🇧 United Kingdom (GB)"],
  ["US", "🇺🇸 United States (US)"],
  ["SE", "🇸🇪 Sweden (SE)"],
  ["PL", "🇵🇱 Poland (PL)"],
  ["EE", "🇪🇪 Estonia (EE)"],
  ["LV", "🇱🇻 Latvia (LV)"],
  ["LT", "🇱🇹 Lithuania (LT)"],
  ["CH", "🇨🇭 Switzerland (CH)"],
  ["AT", "🇦🇹 Austria (AT)"],
  ["CZ", "🇨🇿 Czechia (CZ)"],
  ["TR", "🇹🇷 Turkey (TR)"],
  ["KZ", "🇰🇿 Kazakhstan (KZ)"],
  ["SG", "🇸🇬 Singapore (SG)"],
  ["JP", "🇯🇵 Japan (JP)"],
  ["HK", "🇭🇰 Hong Kong (HK)"],
  ["RU", "🇷🇺 Russia (RU)"],
  ["UA", "🇺🇦 Ukraine (UA)"],
  ["BY", "🇧🇾 Belarus (BY)"],
];

const PROTOCOL_CHOICES = [
  ["vless", "VLESS"],
  ["hysteria2", "Hysteria2"],
  ["tuic", "TUIC"],
  ["trojan", "Trojan"],
  ["vmess", "VMess"],
  ["shadowsocks", "Shadowsocks"],
  ["anytls", "AnyTLS"],
  ["naive", "NaiveProxy"],
  ["amneziawg", "AmneziaWG / WireGuard"],
  ["wireguard", "WireGuard"],
  ["openvpn", "OpenVPN"],
  ["fptn", "FPTN"],
  ["mieru", "Mieru"],
  ["trusttunnel", "TrustTunnel"],
  ["masque", "MASQUE"],
  ["openconnect", "OpenConnect"],
  ["shadowtls", "ShadowTLS"],
  ["snell", "Snell"],
  ["sudoku", "Sudoku"],
  ["socks", "SOCKS5 / Tor"],
  ["http", "HTTP"],
  ["direct", "Direct"],
];

const TRANSPORT_CHOICES = [
  ["tcp", "TCP"],
  ["ws", "WebSocket"],
  ["grpc", "gRPC"],
  ["http", "HTTP"],
  ["httpupgrade", "HTTPUpgrade"],
  ["quic", "QUIC"],
  ["xhttp", "XHTTP"],
];

const SECURITY_CHOICES = [
  ["none", _("None")],
  ["tls", "TLS"],
  ["reality", "Reality"],
];

const PORT_CHOICES = [
  ["443", "443 (HTTPS)"],
  ["80", "80 (HTTP)"],
  ["8443", "8443"],
  ["2053", "2053 (Cloudflare)"],
  ["2083", "2083 (Cloudflare)"],
  ["2087", "2087 (Cloudflare)"],
  ["2096", "2096 (Cloudflare)"],
  ["8080", "8080"],
];

const URLTEST_URL_CHOICES = [
  "https://www.gstatic.com/generate_204",
  "https://cp.cloudflare.com/generate_204",
  "http://www.msftconnecttest.com/connecttest.txt",
  "https://captive.apple.com/hotspot-detect.html",
];

const DPI_SOURCE_TYPES = new Set(["zapret", "zapret2", "byedpi", "desync"]);

let cachedPoolChoices = null;
let cachedPoolFetchedAt = 0;

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
  if (cachedPoolChoices && Date.now() - cachedPoolFetchedAt < 10000) {
    return Promise.resolve(cachedPoolChoices);
  }
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

    const prefixes = Array.from(prefixSet)
      .filter(Boolean)
      .map((p) => ({ value: p, label: p }));

    cachedPoolChoices = { servers, countries, prefixes };
    cachedPoolFetchedAt = Date.now();
    return cachedPoolChoices;
  });
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

function sectionsUsingRef(refKey, targetId) {
  const result = [];
  (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
    const sid = s[".name"];
    if (!sid) return;
    if (asArray(s[refKey]).includes(targetId)) {
      result.push(sid);
    }
  });
  return result;
}

function updateSectionsRef(refKey, targetId, selectedSectionIds) {
  const want = new Set(asArray(selectedSectionIds));
  (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
    const sid = s[".name"];
    if (!sid) return;
    const current = asArray(s[refKey]);
    const has = current.includes(targetId);
    if (want.has(sid) && !has) {
      uci.set(UCI_PACKAGE, sid, refKey, [...current, targetId]);
    } else if (!want.has(sid) && has) {
      const next = current.filter((id) => id !== targetId);
      if (next.length) uci.set(UCI_PACKAGE, sid, refKey, next);
      else uci.unset(UCI_PACKAGE, sid, refKey);
    }
  });
}

function summarizeBalancer(sectionId) {
  const btype = (
    uci.get(UCI_PACKAGE, sectionId, "balancer_type") || "urltest"
  ).toLowerCase();
  if (btype === "priority") {
    const levels = asArray(
      uci.get(UCI_PACKAGE, sectionId, "outbound_group_levels"),
    );
    const interval =
      uci.get(UCI_PACKAGE, sectionId, "active_check_interval") || "5s";
    return `${_("Priority Failover")} (${_("Tiers")}: ${levels.length ? levels.join(" → ") : _("Section Pool")}, ${_("Check")}: ${interval})`;
  }
  const url =
    uci.get(UCI_PACKAGE, sectionId, "testing_url") ||
    "https://www.gstatic.com/generate_204";
  const interval = uci.get(UCI_PACKAGE, sectionId, "check_interval") || "3m";
  const tol = uci.get(UCI_PACKAGE, sectionId, "tolerance") || "50";
  const parts = [
    `URLTest (${_("Interval")}: ${interval}, ${_("Tolerance")}: ${tol} ms)`,
  ];
  const srcRefs = asArray(uci.get(UCI_PACKAGE, sectionId, "source_refs"));
  const grpRefs = asArray(uci.get(UCI_PACKAGE, sectionId, "group_refs"));
  const fmode = uci.get(UCI_PACKAGE, sectionId, "filter_mode") || "disabled";
  if (srcRefs.length) parts.push(`${_("Sources")}: ${srcRefs.join(", ")}`);
  if (grpRefs.length) parts.push(`${_("Groups")}: ${grpRefs.join(", ")}`);
  if (fmode !== "disabled") {
    const incC = asArray(uci.get(UCI_PACKAGE, sectionId, "include_countries"));
    const excC = asArray(uci.get(UCI_PACKAGE, sectionId, "exclude_countries"));
    const incO = asArray(uci.get(UCI_PACKAGE, sectionId, "include_outbounds"));
    const excO = asArray(uci.get(UCI_PACKAGE, sectionId, "exclude_outbounds"));
    const incR = asArray(uci.get(UCI_PACKAGE, sectionId, "include_regex"));
    const excR = asArray(uci.get(UCI_PACKAGE, sectionId, "exclude_regex"));
    if (incC.length) parts.push(`+${incC.join(",")}`);
    if (excC.length) parts.push(`-${excC.join(",")}`);
    if (incO.length) parts.push(`+${incO.length} ${_("srv")}`);
    if (excO.length) parts.push(`-${excO.length} ${_("srv")}`);
    if (incR.length) parts.push(`~/${incR.join("|")}/`);
    if (excR.length) parts.push(`!/${excR.join("|")}/`);
  }
  parts.push(url);
  return parts.join(" • ");
}

function configureBalancersSection(sectionRef) {
  const origAdd = sectionRef.handleAdd;
  sectionRef.handleAdd = function (ev, name) {
    const res = origAdd.apply(this, arguments);
    const sections = uci.sections(UCI_PACKAGE, "balancer") || [];
    const last = sections[sections.length - 1];
    if (last && last[".name"]) {
      const bid = last[".name"];
      if (!last.name) {
        uci.set(UCI_PACKAGE, bid, "name", bid);
      }
    }
    return res;
  };

  const origRemove = sectionRef.handleRemove;
  if (typeof origRemove === "function") {
    sectionRef.handleRemove = function (section_id, ev) {
      const bname = uci.get(UCI_PACKAGE, section_id, "name") || section_id;
      updateSectionsRef("balancer_refs", section_id, []);
      for (const ut of uci.sections(UCI_PACKAGE, "urltest") || []) {
        if (ut[".name"] && (ut.name || ut[".name"]) === bname) {
          uci.remove(UCI_PACKAGE, ut[".name"]);
        }
      }
      for (const pg of uci.sections(UCI_PACKAGE, "priority_group") || []) {
        if (pg[".name"] && (pg.name || pg[".name"]) === bname) {
          uci.remove(UCI_PACKAGE, pg[".name"]);
        }
      }
      return origRemove.apply(this, arguments);
    };
  }
}

function escapeHtml(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function createBalancersContent(section) {
  section.tab("general", _("Policy Settings"));
  section.tab("pool", _("Server Pool & Filters"));

  let o = section.taboption("general", form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "5rem";

  o = section.taboption(
    "general",
    form.Value,
    "name",
    _("Balancer Name"),
    _(
      "Display name of this reusable selection policy (e.g. Fastest or Priority Failover).",
    ),
  );
  o.rmempty = false;
  o.placeholder = _("e.g. Fastest");
  o.cfgvalue = function (sectionId) {
    return uci.get(UCI_PACKAGE, sectionId, "name") || sectionId;
  };

  o = section.taboption(
    "general",
    form.ListValue,
    "balancer_type",
    _("Balancer Type"),
    _(
      "URLTest picks the lowest-latency server from the pool. Priority switches across ordered Outbound Group tiers.",
    ),
  );
  o.modalonly = true;
  o.default = "urltest";
  o.value("urltest", _("URLTest (Lowest Latency)"));
  o.value("priority", _("Priority (Ordered Failover Tiers)"));

  o = section.taboption(
    "general",
    form.DummyValue,
    "_used_in",
    _("Used in Sections"),
  );
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const used = sectionsUsingRef("balancer_refs", sectionId);
    return used.length ? used.join(", ") : "—";
  };

  o = section.taboption(
    "general",
    form.DynamicList,
    "_target_sections",
    _("Used in Sections"),
    _(
      "Select which routing Sections use this Balancer (automatically updates the section's Attached Balancers).",
    ),
  );
  o.modalonly = true;
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (!sid) return;
      this.value(sid, `${s.name || sid} (${sid})`);
    });
    return sectionsUsingRef("balancer_refs", sectionId);
  };
  o.cfgvalue = function (sectionId) {
    return sectionsUsingRef("balancer_refs", sectionId);
  };
  o.write = function (sectionId, value) {
    updateSectionsRef("balancer_refs", sectionId, value);
  };
  o.remove = function (sectionId) {
    updateSectionsRef("balancer_refs", sectionId, []);
  };

  o = section.taboption(
    "general",
    form.DummyValue,
    "_summary",
    _("Policy Summary"),
  );
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const text = summarizeBalancer(sectionId);
    return `<span style="display:inline-block;max-width:360px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom;" title="${escapeHtml(text)}">${escapeHtml(text)}</span>`;
  };
  o.textvalue = function (sectionId) {
    return this.cfgvalue(sectionId);
  };

  // URLTest fields
  o = section.taboption("general", form.Value, "testing_url", _("Testing URL"));
  o.modalonly = true;
  o.default = "https://www.gstatic.com/generate_204";
  o.placeholder = "https://www.gstatic.com/generate_204";
  o.depends("balancer_type", "urltest");
  URLTEST_URL_CHOICES.forEach((u) => o.value(u));

  o = section.taboption(
    "general",
    form.Value,
    "check_interval",
    _("Check Interval"),
    _("Duration format like 1m, 3m, 30s."),
  );
  o.modalonly = true;
  o.default = "3m";
  o.placeholder = "3m";
  o.depends("balancer_type", "urltest");

  o = section.taboption(
    "general",
    form.Value,
    "tolerance",
    _("Latency Tolerance (ms)"),
    _("Minimum latency difference in ms required to switch servers."),
  );
  o.modalonly = true;
  o.default = "50";
  o.placeholder = "50";
  o.depends("balancer_type", "urltest");

  o = section.taboption(
    "general",
    form.Value,
    "idle_timeout",
    _("Idle Timeout"),
  );
  o.modalonly = true;
  o.default = "30m";
  o.placeholder = "30m";
  o.depends("balancer_type", "urltest");

  // Priority fields
  o = section.taboption(
    "general",
    form.DynamicList,
    "outbound_group_levels",
    _("Priority Tiers (Outbound Groups)"),
    _(
      "Ordered list of Outbound Group IDs (or 'direct' for direct fallback). Tier 1 is tried first, then Tier 2, etc.",
    ),
  );
  o.modalonly = true;
  o.depends("balancer_type", "priority");
  o.load = function () {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "outbound_group") || []).forEach((g) => {
      const gid = g[".name"];
      if (gid) this.value(gid, `${g.name || gid} (${gid})`);
    });
    this.value("direct", _("Direct Connection (Fallback)"));
    return form.DynamicList.prototype.load.apply(this, arguments);
  };

  o = section.taboption(
    "general",
    form.Value,
    "health_url",
    _("Health Check URL"),
  );
  o.modalonly = true;
  o.default = "https://www.gstatic.com/generate_204";
  o.placeholder = "https://www.gstatic.com/generate_204";
  o.depends("balancer_type", "priority");
  URLTEST_URL_CHOICES.forEach((u) => o.value(u));

  o = section.taboption(
    "general",
    form.Value,
    "active_check_interval",
    _("Active Check Interval"),
  );
  o.modalonly = true;
  o.default = "5s";
  o.placeholder = "5s";
  o.depends("balancer_type", "priority");

  o = section.taboption(
    "general",
    form.Value,
    "check_timeout",
    _("Check Timeout"),
  );
  o.modalonly = true;
  o.default = "3s";
  o.placeholder = "3s";
  o.depends("balancer_type", "priority");

  o = section.taboption(
    "general",
    form.Value,
    "recovery_check_interval",
    _("Recovery Check Interval"),
  );
  o.modalonly = true;
  o.default = "30s";
  o.placeholder = "30s";
  o.depends("balancer_type", "priority");

  o = section.taboption(
    "general",
    form.Flag,
    "pick_fastest",
    _("Select the fastest node"),
    _(
      "Pick the fastest server of the tier instead of the first working one. On by default - the first node in the filter order is not necessarily the quickest.",
    ),
  );
  o.modalonly = true;
  o.default = "1";
  o.depends("balancer_type", "priority");

  o = section.taboption(
    "general",
    form.Flag,
    "switch_to_faster_same_priority",
    _("Pick Fastest Server Within Active Tier"),
    _(
      "Periodically check the current level and switch to a faster server even when the current one works.",
    ),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("balancer_type", "priority");

  o = section.taboption(
    "general",
    form.Value,
    "fastest_check_interval",
    _("Faster server search interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.modalonly = true;
  o.default = "3m";
  o.placeholder = "3m";
  o.depends({ balancer_type: "priority", switch_to_faster_same_priority: "1" });

  o = section.taboption(
    "general",
    form.Flag,
    "interrupt_exist_connections",
    _("Interrupt Existing Connections on Switch"),
  );
  o.modalonly = true;
  o.default = "1";

  o = section.taboption(
    "general",
    form.Flag,
    "pin_dashboard",
    _("Pin to Dashboard"),
  );
  o.modalonly = true;
  o.default = "1";

  // Tab 2: Server Pool & Filters (subscriptions, groups, countries, regex)
  o = section.taboption(
    "pool",
    form.DynamicList,
    "source_refs",
    _("Subscriptions / Outbound Sources"),
    _(
      "Select subscriptions or sources from the Outbounds tab. Leave empty to use all servers available in the attached Section.",
    ),
  );
  o.modalonly = true;
  o.load = function () {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "outbound_source") || []).forEach((src) => {
      const sid = src[".name"];
      if (!sid) return;
      const stypeLower = String(
        src.source_type || "subscription",
      ).toLowerCase();
      if (DPI_SOURCE_TYPES.has(stypeLower)) return;
      const stype = stypeLower.toUpperCase();
      const pfx = src.node_prefix ? ` [${src.node_prefix}]` : ` [${stype}]`;
      this.value(sid, `${src.name || sid}${pfx} (${sid})`);
    });
    return form.DynamicList.prototype.load.apply(this, arguments);
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "group_refs",
    _("Reusable Outbound Server Groups"),
    _(
      "Optionally select pre-filtered Outbound Server Groups from the Outbounds tab.",
    ),
  );
  o.modalonly = true;
  o.depends("balancer_type", "urltest");
  o.load = function () {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "outbound_group") || []).forEach((grp) => {
      const gid = grp[".name"];
      if (!gid) return;
      this.value(gid, `${grp.name || gid} (${gid})`);
    });
    return form.DynamicList.prototype.load.apply(this, arguments);
  };

  o = section.taboption(
    "pool",
    form.ListValue,
    "filter_mode",
    _("Filter Mode"),
    _(
      "Filter which servers from the pool participate in this URLTest balancer.",
    ),
  );
  o.modalonly = true;
  o.default = "disabled";
  o.value("disabled", _("Disabled (Use all servers in pool)"));
  o.value("include", _("Include Only Matching"));
  o.value("exclude", _("Exclude Matching"));
  o.value("mixed", _("Mixed (Include AND Exclude)"));
  o.depends("balancer_type", "urltest");

  o = section.taboption(
    "pool",
    form.ListValue,
    "detect_server_country",
    _("Detect server country"),
  );
  o.modalonly = true;
  o.default = "flag_emoji";
  o.value("flag_emoji", _("By flag emoji from name"));
  o.value("country_is", _("Via country.is"));
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_prefixes",
    _("Include Subscription Prefixes"),
  );
  o.modalonly = true;
  o.placeholder = _("e.g. Unlim");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  o.load = function (sectionId) {
    return loadGlobalPoolChoices().then((pool) => {
      this.keylist = [];
      this.vallist = [];
      pool.prefixes.forEach((c) => this.value(c.value, c.label));
      return form.DynamicList.prototype.load.call(this, sectionId);
    });
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_prefixes",
    _("Exclude Subscription Prefixes"),
  );
  o.modalonly = true;
  o.placeholder = _("e.g. Backup");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  o.load = function (sectionId) {
    return loadGlobalPoolChoices().then((pool) => {
      this.keylist = [];
      this.vallist = [];
      pool.prefixes.forEach((c) => this.value(c.value, c.label));
      return form.DynamicList.prototype.load.call(this, sectionId);
    });
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_countries",
    _("Include Country Flags (ISO)"),
    _(
      "Select countries from the dropdown or enter 2-letter ISO codes (NL, DE, FI, RU).",
    ),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select country --");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  o.load = function (sectionId) {
    return loadGlobalPoolChoices().then((pool) => {
      this.keylist = [];
      this.vallist = [];
      pool.countries.forEach((c) => this.value(c.value, c.label));
      return form.DynamicList.prototype.load.call(this, sectionId);
    });
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_countries",
    _("Exclude Country Flags (ISO)"),
    _("Select countries to exclude from auto-selection."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select country --");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  o.load = function (sectionId) {
    return loadGlobalPoolChoices().then((pool) => {
      this.keylist = [];
      this.vallist = [];
      pool.countries.forEach((c) => this.value(c.value, c.label));
      return form.DynamicList.prototype.load.call(this, sectionId);
    });
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_outbounds",
    _("Include Servers"),
    _(
      "Select specific servers from the pool to include in this auto-selection.",
    ),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select server --");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  o.load = function (sectionId) {
    return loadGlobalPoolChoices().then((pool) => {
      this.keylist = [];
      this.vallist = [];
      pool.servers.forEach((s) => this.value(s.value, s.label));
      return form.DynamicList.prototype.load.call(this, sectionId);
    });
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_outbounds",
    _("Exclude Servers"),
    _(
      "Select specific servers from the pool to exclude from this auto-selection.",
    ),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select server --");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  o.load = function (sectionId) {
    return loadGlobalPoolChoices().then((pool) => {
      this.keylist = [];
      this.vallist = [];
      pool.servers.forEach((s) => this.value(s.value, s.label));
      return form.DynamicList.prototype.load.call(this, sectionId);
    });
  };

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_protocols",
    _("Include Protocols"),
    _("Filter servers by protocol (e.g. VLESS, Hysteria2, AmneziaWG)."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select protocol --");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  PROTOCOL_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_protocols",
    _("Exclude Protocols"),
    _("Exclude servers with specified protocols."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select protocol --");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  PROTOCOL_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_transports",
    _("Include Transports"),
    _("Only servers with one of the selected transports."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select transport --");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  TRANSPORT_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_transports",
    _("Exclude Transports"),
    _("Do not test servers with one of the selected transports."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select transport --");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  TRANSPORT_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_securities",
    _("Include Security Types"),
    _("Only servers with one of the selected security types."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select security --");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  SECURITY_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_securities",
    _("Exclude Security Types"),
    _("Do not test servers with one of the selected security types."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select security --");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  SECURITY_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_ports",
    _("Include Ports"),
    _(
      "Test only servers with one of the selected ports or port ranges (e.g. 443, 8443, 2000-3000).",
    ),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select or type port/range --");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  PORT_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_ports",
    _("Exclude Ports"),
    _("Do not test servers with one of the selected ports or port ranges."),
  );
  o.modalonly = true;
  o.placeholder = _("-- Select or type port/range --");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
  PORT_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "pool",
    form.DynamicList,
    "include_regex",
    _("Include Name Regex"),
  );
  o.modalonly = true;
  o.placeholder = _("e.g. Amsterdam|Frankfurt");
  o.depends({ balancer_type: "urltest", filter_mode: "include" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });

  o = section.taboption(
    "pool",
    form.DynamicList,
    "exclude_regex",
    _("Exclude Name Regex"),
  );
  o.modalonly = true;
  o.placeholder = _("e.g. \\|WL\\| or Bypass");
  o.depends({ balancer_type: "urltest", filter_mode: "exclude" });
  o.depends({ balancer_type: "urltest", filter_mode: "mixed" });
}

return baseclass.extend({
  configureBalancersSection,
  createBalancersContent,
});
