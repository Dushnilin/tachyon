"use strict";
"require baseclass";
"require form";
"require fs";
"require uci";
"require ui";
"require view.tachyon.main as main";
"require view.tachyon.local_devices as localDevices";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE || "tachyon";

function asArray(val) {
  if (!val) return [];
  const lines = Array.isArray(val) ? val : String(val).split(/[\r\n]+/);
  const out = [];
  lines.forEach((line) => {
    const cleaned = String(line)
      .replace(/(^|\s+)\/\/.*$/, "")
      .replace(/(^|\s+)#.*$/, "")
      .trim();
    if (!cleaned) return;
    cleaned.split(/[\s,]+/).forEach((tok) => {
      const t = tok.trim();
      if (t) out.push(t);
    });
  });
  return out;
}

function loadCombinedDomainText(sectionId) {
  const parts = [];
  const rawDom = uci.get(UCI_PACKAGE, sectionId, "domain");
  if (Array.isArray(rawDom)) {
    if (rawDom.length) parts.push(rawDom.join("\n"));
  } else if (rawDom && String(rawDom).trim()) {
    parts.push(String(rawDom).trim());
  }
  const rawSuf = uci.get(UCI_PACKAGE, sectionId, "domain_suffix");
  if (Array.isArray(rawSuf)) {
    if (rawSuf.length) parts.push(rawSuf.join("\n"));
  } else if (rawSuf && String(rawSuf).trim()) {
    parts.push(String(rawSuf).trim());
  }
  const rawSufText = uci.get(UCI_PACKAGE, sectionId, "domain_suffix_text");
  if (rawSufText && String(rawSufText).trim()) {
    parts.push(String(rawSufText).trim());
  }
  const rawDomText = uci.get(UCI_PACKAGE, sectionId, "domain_text");
  if (rawDomText && String(rawDomText).trim()) {
    parts.push(String(rawDomText).trim());
  }
  const rawKw = asArray(uci.get(UCI_PACKAGE, sectionId, "domain_keyword"));
  rawKw.forEach((k) => {
    parts.push(k.startsWith("keyword:") ? k : `keyword:${k}`);
  });
  const rawRx = asArray(uci.get(UCI_PACKAGE, sectionId, "domain_regex"));
  rawRx.forEach((r) => {
    parts.push(r.startsWith("regex:") ? r : `regex:${r}`);
  });
  return parts.join("\n");
}

function loadMultilineText(sectionId, key, altKey) {
  const raw = uci.get(UCI_PACKAGE, sectionId, key);
  if (Array.isArray(raw)) {
    return raw.join("\n");
  }
  if (raw && String(raw).trim()) {
    return String(raw);
  }
  if (altKey) {
    const alt = uci.get(UCI_PACKAGE, sectionId, altKey);
    if (alt && String(alt).trim()) return String(alt);
  }
  return "";
}

function summarizeCondition(sectionId) {
  const ctype = (
    uci.get(UCI_PACKAGE, sectionId, "condition_type") || "atomic"
  ).toLowerCase();
  const expr = (uci.get(UCI_PACKAGE, sectionId, "expression") || "").trim();
  const members = asArray(uci.get(UCI_PACKAGE, sectionId, "members"));
  const op = (
    uci.get(UCI_PACKAGE, sectionId, "operator") || "and"
  ).toUpperCase();
  const invert = uci.get(UCI_PACKAGE, sectionId, "invert") === "1";

  if (expr) {
    return (invert ? "NOT (" + expr + ")" : expr).slice(0, 120);
  }
  if (ctype === "composite" || members.length > 0) {
    const memberNames = members.map(
      (id) =>
        uci.get(UCI_PACKAGE, id, "name") ||
        uci.get(UCI_PACKAGE, id, "label") ||
        id,
    );
    if (op === "NOT") {
      return `NOT (${memberNames.join(" AND ")})`;
    }
    const joined = memberNames.join(` ${op} `);
    return invert ? `NOT (${joined})` : joined || _("Empty composite rule");
  }

  const parts = [];
  const comm = asArray(uci.get(UCI_PACKAGE, sectionId, "community_lists"));
  if (comm.length) parts.push(`${_("Services")}: ${comm.join(", ")}`);
  const rsets = [
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "rule_set")),
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "rule_set_with_subnets")),
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "domain_ip_lists")),
  ];
  if (rsets.length) parts.push(`${_("Lists")}: ${rsets.length}`);
  const doms = [
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "domain")),
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "domain_suffix")),
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "domain_keyword")),
    ...asArray(uci.get(UCI_PACKAGE, sectionId, "domain_regex")),
  ];
  if (doms.length)
    parts.push(
      `${_("Domains")}: ${doms.slice(0, 3).join(", ")}${doms.length > 3 ? "…" : ""}`,
    );
  const ips = asArray(uci.get(UCI_PACKAGE, sectionId, "ip_cidr"));
  if (ips.length)
    parts.push(
      `${_("Dest IP")}: ${ips.slice(0, 2).join(", ")}${ips.length > 2 ? "…" : ""}`,
    );
  const sips = asArray(uci.get(UCI_PACKAGE, sectionId, "source_ip_cidr"));
  const smacs = asArray(uci.get(UCI_PACKAGE, sectionId, "source_macs"));
  if (sips.length || smacs.length) {
    parts.push(`${_("Source")}: ${[...sips, ...smacs].slice(0, 2).join(", ")}`);
  }
  const ports = asArray(uci.get(UCI_PACKAGE, sectionId, "ports"));
  if (ports.length) parts.push(`${_("Ports")}: ${ports.join(", ")}`);
  const proto = asArray(uci.get(UCI_PACKAGE, sectionId, "protocol"));
  if (proto.length) parts.push(`${_("Proto")}: ${proto.join("/")}`);
  const geo = asArray(uci.get(UCI_PACKAGE, sectionId, "geoip_country"));
  if (geo.length) parts.push(`${_("GeoIP")}: ${geo.join(", ").toUpperCase()}`);

  const summary = parts.length ? parts.join(" | ") : _("No matchers set");
  return invert ? `NOT (${summary})` : summary;
}

function detectConditionCycle(startId, candidateMembers, candidateExpr) {
  const allConds = uci.sections(UCI_PACKAGE, "condition") || [];
  const byId = {};
  allConds.forEach((c) => {
    if (c[".name"]) byId[c[".name"]] = c;
  });

  function getDeps(id) {
    if (id === startId) {
      const tokens = String(candidateExpr || "")
        .split(/[^A-Za-z0-9_.-]+/)
        .filter((t) => t && !["AND", "OR", "NOT"].includes(t.toUpperCase()));
      return Array.from(new Set([...candidateMembers, ...tokens]));
    }
    const sec = byId[id];
    if (!sec) return [];
    const m = asArray(sec.members);
    const tokens = String(sec.expression || "")
      .split(/[^A-Za-z0-9_.-]+/)
      .filter((t) => t && !["AND", "OR", "NOT"].includes(t.toUpperCase()));
    return Array.from(new Set([...m, ...tokens]));
  }

  const state = {};
  const path = [];
  function visit(curr) {
    state[curr] = 1;
    path.push(curr);
    for (const dep of getDeps(curr)) {
      if (dep === curr) {
        return _("Condition '%s' cannot reference itself").format(curr);
      }
      if (state[dep] === 1) {
        return _("Circular condition reference detected: %s").format(
          [...path, dep].join(" -> "),
        );
      }
      if (!state[dep]) {
        const subErr = visit(dep);
        if (subErr) return subErr;
      }
    }
    path.pop();
    state[curr] = 2;
    return null;
  }

  return visit(startId);
}

function createTwoModeTracerWidget() {
  const modeSelect = E("select", { class: "cbi-input-select" }, [
    E(
      "option",
      { value: "presence" },
      _("1. Where is the argument present? (Presence Search)"),
    ),
    E(
      "option",
      { value: "exact" },
      _("2. Which rule is strictly satisfied? (Exact Boolean Match)"),
    ),
  ]);

  const searchInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: _(
      "Domain, IP/subnet, MAC, port, or service list (e.g. youtube.com, 1.1.1.1, discord)",
    ),
    style: "flex: 2; min-width: 220px;",
  });

  const srcIpInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: _("Source IP (e.g. 192.168.1.50)"),
    style: "flex: 1; min-width: 140px;",
  });

  const srcMacInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: _("Source MAC (e.g. AA:BB:CC:11:22:33)"),
    style: "flex: 1; min-width: 150px;",
  });

  const portInput = E("input", {
    type: "text",
    class: "cbi-input-text",
    placeholder: _("Port (e.g. 443)"),
    style: "width: 110px;",
  });

  const resultsBox = E("div", {
    style: "margin-top: 10px; display: none;",
  });

  const runBtn = E(
    "button",
    {
      type: "button",
      class: "btn cbi-button cbi-button-action",
      click: async () => {
        const payload = {
          mode: modeSelect.value,
          search: searchInput.value.trim(),
          source_ip: srcIpInput.value.trim(),
          source_mac: srcMacInput.value.trim(),
          port: portInput.value.trim(),
        };
        if (
          !payload.search &&
          !payload.source_ip &&
          !payload.source_mac &&
          !payload.port
        ) {
          resultsBox.style.display = "none";
          return;
        }
        runBtn.disabled = true;
        resultsBox.style.display = "block";
        resultsBox.innerHTML = "";
        resultsBox.appendChild(E("em", {}, _("Running 2-mode rule tracer...")));
        try {
          const res = await fs.exec("/usr/bin/tachyon", [
            "trace_rules",
            JSON.stringify(payload),
          ]);
          const data = res && res.stdout ? JSON.parse(res.stdout) : null;
          resultsBox.innerHTML = "";
          if (!data) {
            resultsBox.appendChild(
              E(
                "p",
                { class: "alert-message warning" },
                _("No response from rule tracer."),
              ),
            );
            return;
          }

          if (data.mode === "exact") {
            const win = data.winning_section;
            resultsBox.appendChild(
              E(
                "div",
                {
                  class: win ? "alert-message notice" : "alert-message warning",
                  style: "margin-bottom: 8px;",
                },
                win
                  ? [
                      E(
                        "strong",
                        {},
                        _("Winning Section (Exact Match)") + ": ",
                      ),
                      E("span", {}, `${win.name || win.id} [${win.action}]`),
                    ]
                  : _(
                      "No section is strictly satisfied by the supplied arguments.",
                    ),
              ),
            );
          }

          const condList =
            data.mode === "exact"
              ? data.exact_conditions || []
              : data.presence_conditions || [];
          const secList =
            data.mode === "exact"
              ? data.exact_sections || []
              : data.presence_sections || [];

          const condItems = condList.map((c) =>
            E("li", { style: "margin: 3px 0;" }, [
              E("strong", {}, `${c.name || c.id}`),
              c.hits && c.hits.length
                ? ` — ${_("Matched")}: ${c.hits.join(", ")}`
                : "",
              !c.exact_match && c.unmatched_leaves && c.unmatched_leaves.length
                ? ` (${_("Requires other AND operands")}: ${c.unmatched_leaves.join(", ")})`
                : "",
            ]),
          );

          const secItems = secList.map((s) =>
            E("li", { style: "margin: 3px 0;" }, [
              E("strong", {}, `${s.name || s.id} [${s.action}]`),
              s.hits && s.hits.length
                ? ` — ${_("Matched")}: ${s.hits.join(", ")}`
                : "",
              !s.exact_match
                ? ` (${_("Partial presence match — other AND conditions not supplied")})`
                : ` (${_("Exact match")})`,
            ]),
          );

          resultsBox.appendChild(
            E("div", { class: "cbi-section-node", style: "padding: 8px;" }, [
              E("div", { style: "margin-bottom: 6px;" }, [
                E(
                  "strong",
                  {},
                  _("Matched Conditions") + ` (${condItems.length}):`,
                ),
                condItems.length
                  ? E("ul", { style: "margin: 4px 0 8px 18px;" }, condItems)
                  : E("div", {}, E("em", {}, _("None"))),
              ]),
              E("div", {}, [
                E(
                  "strong",
                  {},
                  _("Matched Sections") + ` (${secItems.length}):`,
                ),
                secItems.length
                  ? E("ul", { style: "margin: 4px 0 0 18px;" }, secItems)
                  : E("div", {}, E("em", {}, _("None"))),
              ]),
            ]),
          );
        } catch (err) {
          resultsBox.innerHTML = "";
          resultsBox.appendChild(
            E(
              "p",
              { class: "alert-message danger" },
              _("Tracer error") + ": " + (err?.message || String(err)),
            ),
          );
        } finally {
          runBtn.disabled = false;
        }
      },
    },
    _("Trace"),
  );

  return E("div", { class: "cbi-section", style: "margin-bottom: 12px;" }, [
    E("h3", {}, _("2-Mode Rule & Condition Tracer")),
    E("div", { class: "cbi-section-node", style: "padding: 10px;" }, [
      E(
        "div",
        {
          style:
            "display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 8px;",
        },
        [modeSelect, searchInput],
      ),
      E(
        "div",
        {
          style:
            "display: flex; flex-wrap: wrap; gap: 8px; align-items: center;",
        },
        [srcIpInput, srcMacInput, portInput, runBtn],
      ),
      resultsBox,
    ]),
  ]);
}

function configureConditionsSection(sectionRef) {
  const origRemove = sectionRef.remove;
  sectionRef.remove = function (sectionId) {
    const stripPrefix = (tok) => String(tok || "").replace(/^[+!-]/, "");
    const inlineConditionKeys = [
      "community_lists",
      "rule_set",
      "rule_set_with_subnets",
      "domain_ip_lists",
      "domain",
      "domain_suffix",
      "domain_keyword",
      "domain_regex",
      "ip_cidr",
      "source_ip_cidr",
      "source_macs",
      "ports",
      "protocol",
      "geoip_country",
      "domain_suffix_text",
      "domain_text",
      "ip_cidr_text",
      "source_ip_cidr_text",
      "source_macs_text",
      "ports_text",
    ];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (!sid) return;
      const cur = asArray(s.condition_refs);
      const hasRef = cur.some((tok) => stripPrefix(tok) === sectionId);
      if (hasRef) {
        const next = cur.filter((tok) => stripPrefix(tok) !== sectionId);
        if (next.length) uci.set(UCI_PACKAGE, sid, "condition_refs", next);
        else uci.unset(UCI_PACKAGE, sid, "condition_refs");
      }
      if (hasRef || sectionId === `cond_${sid}`) {
        inlineConditionKeys.forEach((k) => uci.unset(UCI_PACKAGE, sid, k));
      }
    });
    (uci.sections(UCI_PACKAGE, "condition") || []).forEach((c) => {
      const cid = c[".name"];
      if (!cid || cid === sectionId) return;
      const cur = asArray(c.members);
      if (cur.some((tok) => stripPrefix(tok) === sectionId)) {
        const next = cur.filter((tok) => stripPrefix(tok) !== sectionId);
        if (next.length) uci.set(UCI_PACKAGE, cid, "members", next);
        else uci.unset(UCI_PACKAGE, cid, "members");
      }
    });
    return origRemove
      ? origRemove.apply(this, arguments)
      : form.GridSection.prototype.remove.apply(this, arguments);
  };

  const origRender = sectionRef.render;
  sectionRef.render = function () {
    return origRender.apply(this, arguments).then((node) => {
      if (node) {
        node.insertBefore(createTwoModeTracerWidget(), node.firstChild);
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

function createConditionsContent(section) {
  section.tab("general", _("General & Logic"));
  section.tab("domains", _("Domains & Lists"));
  section.tab("network", _("Devices, IPs & Ports"));

  let o = section.taboption("general", form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "5rem";

  o = section.taboption(
    "general",
    form.Value,
    "name",
    _("Condition Name"),
    _("Human-readable name of this reusable condition."),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.placeholder = _("e.g. Banned Domains or My Devices");

  o = section.taboption(
    "general",
    form.ListValue,
    "condition_type",
    _("Condition Type"),
    _(
      "Atomic conditions match traffic properties directly. Composite conditions combine other conditions with AND, OR, and NOT.",
    ),
  );
  o.modalonly = true;
  o.default = "atomic";
  o.value("atomic", _("Atomic Matchers"));
  o.value("composite", _("Composite Boolean Rule (AND / OR / NOT)"));

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
      if (sid && asArray(s.condition_refs).includes(sectionId)) {
        used.push(s.label || s.name || sid);
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
      "Select which routing Sections use this Condition (automatically updates the section's Attached Conditions).",
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
      this.value(sid, s.label || s.name || sid);
      if (asArray(s.condition_refs).includes(sectionId)) {
        used.push(sid);
      }
    });
    return used;
  };
  o.cfgvalue = function (sectionId) {
    const used = [];
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((s) => {
      const sid = s[".name"];
      if (sid && asArray(s.condition_refs).includes(sectionId)) {
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
      const cur = asArray(s.condition_refs);
      const has = cur.includes(sectionId);
      if (want.has(sid) && !has) {
        uci.set(UCI_PACKAGE, sid, "condition_refs", [...cur, sectionId]);
      } else if (!want.has(sid) && has) {
        const next = cur.filter((id) => id !== sectionId);
        if (next.length) uci.set(UCI_PACKAGE, sid, "condition_refs", next);
        else uci.unset(UCI_PACKAGE, sid, "condition_refs");
      }
    });
  };
  o.remove = function (sectionId) {
    this.write(sectionId, []);
  };

  o = section.taboption(
    "general",
    form.DummyValue,
    "_summary",
    _("Rule Summary"),
  );
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const text = summarizeCondition(sectionId);
    return `<span style="display:inline-block;max-width:360px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom;" title="${escapeHtml(text)}">${escapeHtml(text)}</span>`;
  };
  o.textvalue = function (sectionId) {
    return this.cfgvalue(sectionId);
  };

  o = section.taboption(
    "general",
    form.ListValue,
    "operator",
    _("Boolean Operator"),
    _("How member conditions are combined."),
  );
  o.modalonly = true;
  o.default = "and";
  o.value("and", _("AND (all selected conditions must match)"));
  o.value("or", _("OR (any selected condition matches)"));
  o.value("not", _("NOT (none of the selected conditions match)"));
  o.depends("condition_type", "composite");

  o = section.taboption(
    "general",
    form.DynamicList,
    "members",
    _("Member Conditions"),
    _(
      "Select existing conditions to combine. Self-references and circular chains (A -> B -> A) are automatically blocked.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "composite");
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "condition") || []).forEach((c) => {
      const cid = c[".name"];
      if (cid && cid !== sectionId) {
        this.value(cid, c.name || c.label || cid);
      }
    });
    return form.DynamicList.prototype.load.apply(this, arguments);
  };
  o.validate = function (sectionId, value) {
    const members = asArray(value);
    const expr = uci.get(UCI_PACKAGE, sectionId, "expression") || "";
    const cycleErr = detectConditionCycle(sectionId, members, expr);
    if (cycleErr) return cycleErr;
    return true;
  };

  o = section.taboption(
    "general",
    form.Value,
    "expression",
    _("Advanced Boolean Expression"),
    _(
      "Optional expression using condition IDs and AND / OR / NOT / parentheses, e.g. (baned_domains AND my_devices) AND NOT whitelist.",
    ),
  );
  o.modalonly = true;
  o.placeholder = "baned_domains AND my_devices";
  o.depends("condition_type", "composite");
  o.validate = function (sectionId, value) {
    const members = asArray(uci.get(UCI_PACKAGE, sectionId, "members"));
    const cycleErr = detectConditionCycle(sectionId, members, value);
    if (cycleErr) return cycleErr;
    return true;
  };

  o = section.taboption(
    "general",
    form.Flag,
    "invert",
    _("Invert Condition (NOT)"),
    _("Negate the result of this condition."),
  );
  o.modalonly = true;
  o.default = "0";

  // Domains & Lists tab
  o = section.taboption(
    "domains",
    form.DynamicList,
    "community_lists",
    _("Community Service Lists"),
    _("Predefined service domain/subnet lists."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  if (main.DOMAIN_LIST_OPTIONS) {
    Object.entries(main.DOMAIN_LIST_OPTIONS).forEach(([key, label]) => {
      o.value(key, label);
    });
  }

  o = section.taboption(
    "domains",
    form.Flag,
    "community_subnets",
    _("Route Subnets from Community Lists"),
    _(
      "Also route IP/CIDR subnets included in the selected community lists (in addition to domains).",
    ),
  );
  o.modalonly = true;
  o.default = "0";
  o.depends("condition_type", "atomic");

  o = section.taboption(
    "domains",
    form.DynamicList,
    "rule_set",
    _("Rule Sets (.srs / .json / URL)"),
    _("Remote or local sing-box rule-set URLs or paths (domains only)."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");

  o = section.taboption(
    "domains",
    form.DynamicList,
    "rule_set_with_subnets",
    _("Rule Sets with Subnets"),
    _("Rule-sets that also extract IP/CIDR subnets into nftables."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");

  o = section.taboption(
    "domains",
    form.DynamicList,
    "domain_ip_lists",
    _("Plain Domain/IP Lists (.lst / .txt)"),
    _("URLs or local paths to plain-text domain/IP lists."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");

  o = section.taboption(
    "domains",
    form.TextValue,
    "domain",
    _("Domains & Suffixes"),
    _(
      "One domain or rule per line (supports // comments, plain suffixes like youtube.com, or prefixes full:, domain:, keyword:, regex:).",
    ),
  );
  o.modalonly = true;
  o.rows = 8;
  o.textarea = true;
  o.depends("condition_type", "atomic");
  o.cfgvalue = function (sectionId) {
    return loadCombinedDomainText(sectionId);
  };
  o.write = function (sectionId, value) {
    const text = String(value || "").trim();
    if (text) {
      uci.set(UCI_PACKAGE, sectionId, "domain", text);
    } else {
      uci.unset(UCI_PACKAGE, sectionId, "domain");
    }
    uci.unset(UCI_PACKAGE, sectionId, "domain_suffix");
    uci.unset(UCI_PACKAGE, sectionId, "domain_suffix_text");
    uci.unset(UCI_PACKAGE, sectionId, "domain_text");
    uci.unset(UCI_PACKAGE, sectionId, "domain_keyword");
    uci.unset(UCI_PACKAGE, sectionId, "domain_regex");
  };
  o.remove = function (sectionId) {
    uci.unset(UCI_PACKAGE, sectionId, "domain");
    uci.unset(UCI_PACKAGE, sectionId, "domain_suffix");
    uci.unset(UCI_PACKAGE, sectionId, "domain_suffix_text");
    uci.unset(UCI_PACKAGE, sectionId, "domain_text");
    uci.unset(UCI_PACKAGE, sectionId, "domain_keyword");
    uci.unset(UCI_PACKAGE, sectionId, "domain_regex");
  };

  o = section.taboption(
    "domains",
    form.TextValue,
    "user_domains",
    _("Auto-detected Domains"),
    _("Additional or auto-discovered domain suffixes (one per line)."),
  );
  o.modalonly = true;
  o.rows = 5;
  o.textarea = true;
  o.depends("condition_type", "atomic");
  o.cfgvalue = function (sectionId) {
    return loadMultilineText(sectionId, "user_domains", "user_domains_text");
  };
  o.write = function (sectionId, value) {
    const lines = asArray(value);
    if (lines.length) {
      uci.set(UCI_PACKAGE, sectionId, "user_domains", lines);
    } else {
      uci.unset(UCI_PACKAGE, sectionId, "user_domains");
    }
    uci.unset(UCI_PACKAGE, sectionId, "user_domains_text");
  };
  o.remove = function (sectionId) {
    uci.unset(UCI_PACKAGE, sectionId, "user_domains");
    uci.unset(UCI_PACKAGE, sectionId, "user_domains_text");
  };

  // Network tab
  o = section.taboption(
    "network",
    form.TextValue,
    "ip_cidr",
    _("Destination IP / CIDR Subnets"),
    _(
      "Target IPv4/IPv6 addresses or CIDR blocks, one per line or comma-separated (supports // comments).",
    ),
  );
  o.modalonly = true;
  o.rows = 6;
  o.textarea = true;
  o.depends("condition_type", "atomic");
  o.cfgvalue = function (sectionId) {
    return loadMultilineText(sectionId, "ip_cidr", "ip_cidr_text");
  };
  o.write = function (sectionId, value) {
    const text = String(value || "").trim();
    if (text) {
      uci.set(UCI_PACKAGE, sectionId, "ip_cidr", text);
    } else {
      uci.unset(UCI_PACKAGE, sectionId, "ip_cidr");
    }
    uci.unset(UCI_PACKAGE, sectionId, "ip_cidr_text");
  };
  o.remove = function (sectionId) {
    uci.unset(UCI_PACKAGE, sectionId, "ip_cidr");
    uci.unset(UCI_PACKAGE, sectionId, "ip_cidr_text");
  };

  o = section.taboption(
    "network",
    form.DynamicList,
    "fully_routed_ips",
    _("Fully Routed IPs / Hostnames (Direct NFT)"),
    _(
      "IPs, CIDR blocks, or hostnames pre-resolved and added directly into the nftables routing set.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  if (
    localDevices &&
    typeof localDevices.createLocalDeviceDynamicListWidget === "function"
  ) {
    o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
      return localDevices.createLocalDeviceDynamicListWidget(
        this,
        sectionId,
        cfgvalue,
      );
    };
  }

  o = section.taboption(
    "network",
    form.DynamicList,
    "excluded_ips",
    _("Excluded Destination IPs / Subnets"),
    _("Destination IPs or CIDR blocks to exclude from this condition."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  if (
    localDevices &&
    typeof localDevices.createLocalDeviceDynamicListWidget === "function"
  ) {
    o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
      return localDevices.createLocalDeviceDynamicListWidget(
        this,
        sectionId,
        cfgvalue,
      );
    };
  }

  o = section.taboption(
    "network",
    form.DynamicList,
    "source_ip_cidr",
    _("Source Device IPs / Subnets"),
    _("LAN client IP addresses or subnets (e.g. 192.168.1.50/32)."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  if (
    localDevices &&
    typeof localDevices.createLocalDeviceDynamicListWidget === "function"
  ) {
    o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
      return localDevices.createLocalDeviceDynamicListWidget(
        this,
        sectionId,
        cfgvalue,
      );
    };
  }

  o = section.taboption(
    "network",
    form.DynamicList,
    "source_macs",
    _("Source Device MAC Addresses"),
    _(
      "LAN client MAC addresses (e.g. AA:BB:CC:DD:EE:FF). Resolved automatically via DHCP leases and ARP.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");

  o = section.taboption(
    "network",
    form.DynamicList,
    "ports",
    _("Destination Ports"),
    _("Single ports or ranges (e.g. 80, 443, 1000-2000)."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");

  const TRAFFIC_PROTOCOL_CHOICES = [
    ["bittorrent", _("BitTorrent / P2P")],
    ["quic", _("QUIC (HTTP/3)")],
    ["stun", _("STUN (P2P Calls)")],
    ["dns", _("DNS")],
    ["http", _("HTTP")],
    ["tls", _("TLS / HTTPS")],
    ["ssh", _("SSH")],
    ["rdp", _("RDP")],
    ["tcp", "TCP"],
    ["udp", "UDP"],
    ["icmp", "ICMP"],
  ];

  o = section.taboption(
    "network",
    form.MultiValue,
    "protocol",
    _("Traffic type filter"),
    _("Apply rules of this section only to selected protocols."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  TRAFFIC_PROTOCOL_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "network",
    form.MultiValue,
    "excluded_protocol",
    _("Exclude traffic types"),
    _(
      "Traffic of specified protocols (e.g. BitTorrent, QUIC, STUN) will bypass this section.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  TRAFFIC_PROTOCOL_CHOICES.forEach(([val, label]) => o.value(val, label));

  o = section.taboption(
    "network",
    form.DynamicList,
    "dscp",
    _("DSCP Marks (QoS)"),
    _("Numeric (0-63), hex (0x2e), or class name (ef, cs5, af41)."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");

  o = section.taboption(
    "network",
    form.ListValue,
    "geoip_mode",
    _("GeoIP routing mode"),
    _(
      "Include selected countries: route selected GeoIP countries via this section. Exclude selected countries: route all GeoIP traffic except selected countries via this section. Exclude selected countries (route direct): selected GeoIP countries go direct while all other traffic routes via this section. Include selected countries and all other traffic: route both selected countries and any non-excluded traffic via this section.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.default = "include";
  o.value("include", _("Include selected countries"));
  o.value("exclude", _("Exclude selected countries"));
  o.value("exclude_direct", _("Exclude selected countries (route direct)"));
  o.value("include_all", _("Include selected countries and all other traffic"));

  o = section.taboption(
    "network",
    form.DynamicList,
    "geoip_country",
    _("GeoIP Countries (2-letter ISO)"),
    _(
      "2-letter ISO country codes (e.g. ru, us, de, nl). Automatically downloads and caches the corresponding GeoIP rule-sets.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.placeholder = _("e.g. ru, nl, de");
  o.value("ru", _("Russia (ru)"));
  o.value("us", _("United States (us)"));
  o.value("de", _("Germany (de)"));
  o.value("nl", _("Netherlands (nl)"));
  o.value("gb", _("United Kingdom (gb)"));
  o.value("fr", _("France (fr)"));
  o.value("fi", _("Finland (fi)"));
  o.value("se", _("Sweden (se)"));
  o.value("tr", _("Turkey (tr)"));
  o.value("cn", _("China (cn)"));
  o.value("jp", _("Japan (jp)"));
  o.value("sg", _("Singapore (sg)"));
  o.value("by", _("Belarus (by)"));
  o.value("kz", _("Kazakhstan (kz)"));
  o.value("ua", _("Ukraine (ua)"));
  o.value("pl", "🇵🇱 Poland (pl)");
  o.value("ee", "🇪🇪 Estonia (ee)");
  o.value("lv", "🇱🇻 Latvia (lv)");
  o.value("lt", "🇱🇹 Lithuania (lt)");
  o.value("ch", "🇨🇭 Switzerland (ch)");
  o.value("at", "🇦🇹 Austria (at)");
  o.value("cz", "🇨🇿 Czechia (cz)");
  o.value("hk", "🇭🇰 Hong Kong (hk)");
}

return baseclass.extend({
  configureConditionsSection,
  createConditionsContent,
});
