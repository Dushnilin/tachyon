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
      .replace(/^(full|keyword|regex):[ \t]*(\/\/|#).*$/, "")
      .split("//")[0]
      .split("#")[0]
      .trim();
    if (!cleaned) return;
    cleaned.split(/[\s,]+/).forEach((tok) => {
      const t = tok.trim();
      if (
        t &&
        !t.startsWith("//") &&
        !t.startsWith("#") &&
        !/^[-=_*~]{2,}$/.test(t)
      ) {
        out.push(t);
      }
    });
  });
  return out;
}

function asReferenceArray(val) {
  if (!val) return [];
  // References are opaque values: //, # and commas can all be part of a URL.
  const values = Array.isArray(val) ? val : String(val).split(/\s+/);
  return values.map((value) => String(value).trim()).filter(Boolean);
}

function unsetIfPresent(sectionId, key) {
  const cur = uci.get(UCI_PACKAGE, sectionId, key);
  if (cur !== undefined && cur !== null) {
    uci.unset(UCI_PACKAGE, sectionId, key);
    return;
  }
  const hasCommittedValue =
    uci.state?.values?.[UCI_PACKAGE]?.[sectionId] &&
    Object.prototype.hasOwnProperty.call(
      uci.state.values[UCI_PACKAGE][sectionId],
      key,
    );
  if (
    !hasCommittedValue &&
    uci.state?.deletes?.[UCI_PACKAGE]?.[sectionId]?.[key]
  ) {
    delete uci.state.deletes[UCI_PACKAGE][sectionId][key];
  }
}

function setArrayIfChanged(sectionId, key, arr) {
  const parse = [
    "rule_set",
    "rule_set_with_subnets",
    "domain_ip_lists",
  ].includes(key)
    ? asReferenceArray
    : asArray;
  const cur = parse(uci.get(UCI_PACKAGE, sectionId, key));
  const same = cur.length === arr.length && cur.every((v, i) => v === arr[i]);
  if (same) return;
  if (arr.length) {
    uci.set(UCI_PACKAGE, sectionId, key, arr);
  } else {
    unsetIfPresent(sectionId, key);
  }
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
    ...asReferenceArray(uci.get(UCI_PACKAGE, sectionId, "rule_set")),
    ...asReferenceArray(
      uci.get(UCI_PACKAGE, sectionId, "rule_set_with_subnets"),
    ),
    ...asReferenceArray(uci.get(UCI_PACKAGE, sectionId, "domain_ip_lists")),
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
  const inbounds = asArray(uci.get(UCI_PACKAGE, sectionId, "source_inbounds"));
  if (inbounds.length) {
    parts.push(`${_("Inbound")}: ${inbounds.join(", ")}`);
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

  return E(
    "div",
    { class: "tachyon-studio-panel", style: "margin-bottom: 12px;" },
    [
      E("div", { class: "tachyon-studio-panel__header" }, [
        E("div", { class: "tachyon-studio-panel__titles" }, [
          E(
            "span",
            { class: "tachyon-studio-toolbar__kicker" },
            _("RULE SIMULATION & SEARCH"),
          ),
          E(
            "h3",
            { class: "tachyon-studio-panel__title" },
            _("2-Mode Rule & Condition Tracer"),
          ),
        ]),
      ]),
      E(
        "div",
        {
          class: "tachyon-studio-panel__controls",
          style: "margin-bottom: 8px;",
        },
        [modeSelect, searchInput],
      ),
      E("div", { class: "tachyon-studio-panel__controls" }, [
        srcIpInput,
        srcMacInput,
        portInput,
        runBtn,
      ]),
      resultsBox,
    ],
  );
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
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const ANNOTATED_TEXTAREA_STYLE_ID = "fkp-annotated-textarea-styles";

function ensureAnnotatedTextareaStyles() {
  if (
    typeof document === "undefined" ||
    !document.head ||
    document.getElementById(ANNOTATED_TEXTAREA_STYLE_ID)
  ) {
    return;
  }

  document.head.insertAdjacentHTML(
    "beforeend",
    `<style id="${ANNOTATED_TEXTAREA_STYLE_ID}">
      .fkp-annotated-textarea {
        position: relative;
        background-color: var(--tachyon-bg-card-elevated, #f5f7fa) !important;
        border-radius: 9px !important;
      }

      .fkp-annotated-textarea > textarea,
      #modal_overlay .fkp-annotated-textarea > textarea,
      #modal_overlay .fkp-annotated-textarea > .cbi-input-textarea,
      .cbi-modal .fkp-annotated-textarea > textarea,
      .cbi-modal .fkp-annotated-textarea > .cbi-input-textarea {
        position: relative !important;
        z-index: 1 !important;
        background: transparent !important;
        background-color: transparent !important;
      }

      .fkp-annotated-textarea__overlay {
        position: absolute;
        inset: 0;
        z-index: 0;
        pointer-events: none;
        overflow: hidden;
        box-sizing: border-box;
        color: transparent;
        white-space: pre-wrap;
        word-break: break-word;
        overflow-wrap: break-word;
      }

      .fkp-annotated-textarea__invalid {
        background-color: rgba(239, 68, 68, 0.25);
        border-radius: 3px;
        box-shadow: 0 0 0 1px rgba(239, 68, 68, 0.42);
        color: transparent;
        text-decoration-line: underline;
        text-decoration-style: wavy;
        text-decoration-color: var(--error-color-medium, #ef4444);
        text-decoration-thickness: 1.5px;
        text-underline-offset: 2px;
        text-decoration-skip-ink: none;
      }

      .fkp-annotated-textarea__duplicate {
        background-color: rgba(245, 158, 11, 0.28);
        border-radius: 3px;
        box-shadow: 0 0 0 1px rgba(245, 158, 11, 0.48);
        color: transparent;
        text-decoration-line: underline;
        text-decoration-style: wavy;
        text-decoration-color: #f59e0b;
        text-decoration-thickness: 1.5px;
        text-underline-offset: 2px;
        text-decoration-skip-ink: none;
      }
    </style>`,
  );
}

function applyTextareaInputAttributes(textarea) {
  textarea.setAttribute("spellcheck", "false");
  textarea.setAttribute("autocomplete", "off");
  textarea.setAttribute("autocorrect", "off");
  textarea.setAttribute("autocapitalize", "off");
  textarea.setAttribute("data-gramm", "false");
  textarea.setAttribute("data-gramm_editor", "false");
  textarea.setAttribute("data-enable-grammarly", "false");
  textarea.style.resize = "vertical";
  textarea.style.maxWidth = "100%";
}

function syncAnnotatedTextareaOverlay(textarea, wrapper, overlay) {
  if (
    typeof window === "undefined" ||
    !textarea ||
    !wrapper ||
    !overlay ||
    typeof window.getComputedStyle !== "function"
  ) {
    return;
  }

  const style = window.getComputedStyle(textarea);

  wrapper.style.borderRadius = style.borderRadius;

  overlay.style.font = style.font;
  overlay.style.fontFamily = style.fontFamily;
  overlay.style.fontSize = style.fontSize;
  overlay.style.fontWeight = style.fontWeight;
  overlay.style.lineHeight = style.lineHeight;
  overlay.style.letterSpacing = style.letterSpacing;
  overlay.style.paddingTop = style.paddingTop;
  overlay.style.paddingRight = style.paddingRight;
  overlay.style.paddingBottom = style.paddingBottom;
  overlay.style.paddingLeft = style.paddingLeft;
  overlay.style.borderTopWidth = style.borderTopWidth;
  overlay.style.borderRightWidth = style.borderRightWidth;
  overlay.style.borderBottomWidth = style.borderBottomWidth;
  overlay.style.borderLeftWidth = style.borderLeftWidth;
  overlay.style.borderStyle = "solid";
  overlay.style.borderColor = "transparent";
  overlay.style.textAlign = style.textAlign;
  overlay.style.direction = style.direction;
  overlay.style.tabSize = style.tabSize;
  overlay.style.textIndent = style.textIndent;
  overlay.style.textTransform = style.textTransform;
  overlay.style.boxSizing = style.boxSizing;
  overlay.style.scrollPaddingTop = style.scrollPaddingTop;

  overlay.scrollTop = textarea.scrollTop;
  overlay.scrollLeft = textarea.scrollLeft;
}

function addAnnotationIssue(
  annotationMap,
  annotation,
  message,
  kind = "invalid",
) {
  const key = `${annotation.start}:${annotation.end}`;
  const existing = annotationMap.get(key);
  if (existing) {
    if (!existing.messages.includes(message)) {
      existing.messages.push(message);
    }
    if (kind === "invalid") {
      existing.kind = "invalid";
    }
    return;
  }

  annotationMap.set(key, {
    start: annotation.start,
    end: annotation.end,
    messages: [message],
    kind,
  });
}

function finalizeAnnotations(annotationMap) {
  return Array.from(annotationMap.values())
    .map((annotation) => ({
      start: annotation.start,
      end: annotation.end,
      message: annotation.messages.join("; "),
      kind: annotation.kind || "invalid",
    }))
    .sort((left, right) => left.start - right.start || left.end - right.end);
}

function renderAnnotatedTextareaOverlay(value, annotations) {
  const text = value ? `${value}` : "";
  const normalizedAnnotations = Array.isArray(annotations) ? annotations : [];

  if (!text.length) {
    return "&#8203;";
  }

  if (!normalizedAnnotations.length) {
    return `${escapeHtml(text)}${text.endsWith("\n") ? "\n " : ""}`;
  }

  let cursor = 0;
  let html = "";

  normalizedAnnotations.forEach((annotation) => {
    if (
      annotation.start < cursor ||
      annotation.start >= annotation.end ||
      annotation.start < 0
    ) {
      return;
    }

    const cls =
      annotation.kind === "duplicate"
        ? "fkp-annotated-textarea__duplicate"
        : "fkp-annotated-textarea__invalid";
    html += escapeHtml(text.slice(cursor, annotation.start));
    html += `<span class="${cls}">${escapeHtml(
      text.slice(annotation.start, annotation.end),
    )}</span>`;
    cursor = annotation.end;
  });

  html += escapeHtml(text.slice(cursor));

  if (text.endsWith("\n")) {
    html += "\n ";
  }

  return html;
}

function parseCommentAwareListTokens(value) {
  const text = value ? `${value}` : "";
  const tokens = [];
  const lines = text.split(/\r\n|\r|\n/);
  const newlines = text.match(/\r\n|\r|\n/g) || [];
  let offset = 0;

  lines.forEach((line, index) => {
    const cleanLine = line.replace(
      /^(full|keyword|regex):[ \t]*(\/\/|#).*$/,
      "",
    );
    const hashIndex = cleanLine.indexOf("#");
    const slashIndex = cleanLine.indexOf("//");
    let commentIndex = -1;

    if (hashIndex >= 0 && slashIndex >= 0) {
      commentIndex = Math.min(hashIndex, slashIndex);
    } else if (hashIndex >= 0) {
      commentIndex = hashIndex;
    } else if (slashIndex >= 0) {
      commentIndex = slashIndex;
    }

    const source =
      commentIndex >= 0 ? cleanLine.slice(0, commentIndex) : cleanLine;
    const matcher = /[^,\s]+/g;
    let match;

    while ((match = matcher.exec(source)) !== null) {
      tokens.push({
        value: match[0],
        start: offset + match.index,
        end: offset + match.index + match[0].length,
      });
    }

    offset += line.length + (newlines[index] ? newlines[index].length : 0);
  });

  return tokens;
}

function analyzeTextListValue(value, validateItem, emptyMessage, options = {}) {
  const text = value ? `${value}` : "";
  if (!text.length) {
    return {
      valid: true,
      message: "",
      annotations: [],
      duplicateCount: 0,
      duplicateItems: [],
      syntaxErrorCount: 0,
      validCount: 0,
    };
  }

  const tokens = parseCommentAwareListTokens(text);
  if (!tokens.length) {
    return {
      valid: false,
      message: emptyMessage,
      annotations: [],
      duplicateCount: 0,
      duplicateItems: [],
      syntaxErrorCount: 1,
      validCount: 0,
    };
  }

  const duplicateMessage = options.duplicateMessage || _("Duplicate value");
  const annotationMap = new Map();
  const errors = [];
  const seen = new Set();
  const firstTokenByNormalized = new Map();
  const duplicateItems = [];
  let duplicateCount = 0;
  let syntaxErrorCount = 0;
  let validCount = 0;

  tokens.forEach((token) => {
    let itemValid = true;
    if (typeof validateItem === "function") {
      const validation = validateItem(token.value);
      if (!validation || !validation.valid) {
        const msg = (validation && validation.message) || _("Invalid value");
        errors.push(`${token.value}: ${msg}`);
        addAnnotationIssue(annotationMap, token, msg, "invalid");
        syntaxErrorCount += 1;
        itemValid = false;
      }
    }

    const normalized = options.normalizeDuplicateValue
      ? options.normalizeDuplicateValue(token.value)
      : token.value;

    if (!normalized) {
      return;
    }

    if (seen.has(normalized)) {
      errors.push(`${token.value}: ${duplicateMessage}`);
      const firstToken = firstTokenByNormalized.get(normalized);
      if (firstToken) {
        addAnnotationIssue(
          annotationMap,
          firstToken,
          duplicateMessage,
          "duplicate",
        );
      }
      addAnnotationIssue(annotationMap, token, duplicateMessage, "duplicate");
      duplicateCount += 1;
      duplicateItems.push({
        value: token.value,
        normalized,
        start: token.start,
        end: token.end,
      });
      return;
    }

    seen.add(normalized);
    firstTokenByNormalized.set(normalized, token);
    if (itemValid) {
      validCount += 1;
    }
  });

  if (!errors.length) {
    return {
      valid: true,
      message: "",
      annotations: [],
      duplicateCount: 0,
      duplicateItems: [],
      syntaxErrorCount: 0,
      validCount,
    };
  }

  return {
    valid: false,
    message: [_("Validation errors:"), ...errors].join("\n"),
    annotations: finalizeAnnotations(annotationMap),
    duplicateCount,
    duplicateItems,
    syntaxErrorCount,
    validCount,
  };
}

function validateKeywordValue(value) {
  const normalized = value ? `${value}`.trim() : "";
  if (!normalized.length) {
    return _("Value cannot be empty");
  }
  if (/[,\s]/.test(normalized) || normalized.includes("/")) {
    return _("Keyword must not contain spaces, commas, or slashes");
  }
  return true;
}

function validateRegexValue(value) {
  const normalized = value ? `${value}`.trim() : "";
  if (!normalized.length) {
    return _("Value cannot be empty");
  }
  try {
    new RegExp(normalized);
    return true;
  } catch (err) {
    return _("Invalid regular expression: %s").format(
      err && err.message ? err.message : normalized,
    );
  }
}

function analyzeDomainSuffixText(value) {
  const validateDomainCondition = (domain) => {
    const normalized = `${domain || ""}`.trim();
    if (normalized.includes("/")) {
      return { valid: false, message: _("Invalid domain address") };
    }
    if (typeof main.validateDomain === "function") {
      return main.validateDomain(normalized, true);
    }
    return { valid: true, message: "" };
  };

  return analyzeTextListValue(
    value,
    (item) => {
      const colonIndex = item.indexOf(":");
      const prefix = colonIndex > 0 ? item.slice(0, colonIndex) : "";
      const body = colonIndex > 0 ? item.slice(colonIndex + 1) : item;

      if (!prefix) {
        return validateDomainCondition(body);
      }

      if (!["full", "domain", "keyword", "regex"].includes(prefix)) {
        return {
          valid: false,
          message: _("Allowed domain prefixes are full:, keyword:, and regex:"),
        };
      }

      if (!body.length) {
        return { valid: false, message: _("Value cannot be empty") };
      }

      if (prefix === "full" || prefix === "domain") {
        return validateDomainCondition(body);
      }

      if (prefix === "keyword") {
        const validation = validateKeywordValue(body);
        return validation === true
          ? { valid: true, message: _("Valid") }
          : { valid: false, message: validation };
      }

      if (/[,\s]/.test(body)) {
        return {
          valid: false,
          message: _("Regular expression must not contain spaces or commas"),
        };
      }

      const validation = validateRegexValue(body);
      return validation === true
        ? { valid: true, message: _("Valid") }
        : { valid: false, message: validation };
    },
    _("At least one valid domain must be specified."),
    {
      normalizeDuplicateValue: (item) => {
        const lower = `${item}`.trim().toLowerCase();
        return lower.startsWith("domain:") ? lower.slice(7) : lower;
      },
    },
  );
}

function analyzeIpCidrText(value) {
  return analyzeTextListValue(
    value,
    (item) =>
      typeof main.validateSubnet === "function"
        ? main.validateSubnet(item)
        : { valid: true, message: "" },
    _("At least one valid IP or subnet must be specified."),
    {
      normalizeDuplicateValue: (item) => `${item}`.trim().toLowerCase(),
    },
  );
}

function deduplicateTextListPreservingComments(value, normalizeFn) {
  const lines = String(value || "").split(/\r\n|\r|\n/);
  const seen = new Set();
  const outLines = [];

  lines.forEach((line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    if (trimmed.startsWith("//") || trimmed.startsWith("#")) {
      outLines.push(line);
      return;
    }

    const hashIdx = line.indexOf("#");
    const slashIdx = line.indexOf("//");
    let commentIdx = -1;
    if (hashIdx >= 0 && slashIdx >= 0) commentIdx = Math.min(hashIdx, slashIdx);
    else if (hashIdx >= 0) commentIdx = hashIdx;
    else if (slashIdx >= 0) commentIdx = slashIdx;

    const bodyPart = commentIdx >= 0 ? line.slice(0, commentIdx) : line;
    const commentPart = commentIdx >= 0 ? line.slice(commentIdx) : "";

    const tokens = bodyPart
      .split(/[\s,]+/)
      .map((t) => t.trim())
      .filter(Boolean);
    const uniqueTokens = [];
    tokens.forEach((tok) => {
      const key = normalizeFn ? normalizeFn(tok) : tok.toLowerCase();
      if (!seen.has(key)) {
        seen.add(key);
        uniqueTokens.push(tok);
      }
    });

    if (uniqueTokens.length > 0) {
      outLines.push(
        uniqueTokens.join(", ") + (commentPart ? " " + commentPart.trim() : ""),
      );
    }
  });

  return outLines.join("\n");
}

function attachAnnotatedTextarea(
  textarea,
  analyzer,
  option,
  sectionId,
  normalizeFn,
) {
  if (!textarea || typeof analyzer !== "function") {
    return;
  }

  ensureAnnotatedTextareaStyles();

  if (textarea.__tachyonAnnotatedTextareaController) {
    textarea.__tachyonAnnotatedTextareaController.analyzer = analyzer;
    textarea.__tachyonAnnotatedTextareaController.ensureMounted();
    textarea.__tachyonAnnotatedTextareaController.update();
    return;
  }

  const overlay = document.createElement("div");
  overlay.className = "fkp-annotated-textarea__overlay";
  overlay.setAttribute("aria-hidden", "true");

  const diagBar = E("div", {
    class: "tachyon-condition-textarea-diag",
    style:
      "display:none;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;margin-top:6px;padding:6px 10px;border-radius:6px;font-size:12px;",
  });

  const controller = {
    analyzer,
    textarea,
    wrapper: null,
    overlay,
    diagBar,
    ensureMounted() {
      const parent = this.textarea.parentNode;
      if (!parent) {
        return false;
      }
      if (
        !parent.classList ||
        !parent.classList.contains("fkp-annotated-textarea")
      ) {
        const innerWrap = document.createElement("div");
        innerWrap.className = "fkp-annotated-textarea";
        parent.insertBefore(innerWrap, this.textarea);
        innerWrap.appendChild(this.textarea);
        this.wrapper = innerWrap;
      } else {
        this.wrapper = parent;
      }
      if (this.wrapper) {
        Object.defineProperty(this.wrapper, "value", {
          get: () => this.textarea.value,
          set: (v) => {
            this.textarea.value = v != null ? String(v) : "";
          },
          configurable: true,
        });
      }

      if (this.overlay.parentNode !== this.wrapper) {
        this.wrapper.insertBefore(this.overlay, this.textarea.nextSibling);
      }

      const wrapperParent = this.wrapper.parentNode;
      if (wrapperParent && this.diagBar.parentNode !== wrapperParent) {
        wrapperParent.insertBefore(this.diagBar, this.wrapper.nextSibling);
      }
      return true;
    },
    update() {
      this.ensureMounted();
      const analysis = this.analyzer(this.textarea.value);
      this.overlay.innerHTML = renderAnnotatedTextareaOverlay(
        this.textarea.value,
        analysis.annotations,
      );
      if (this.wrapper) {
        syncAnnotatedTextareaOverlay(this.textarea, this.wrapper, this.overlay);
      }

      if (!this.textarea.value.trim()) {
        this.diagBar.style.display = "none";
        return;
      }

      this.diagBar.style.display = "flex";
      this.diagBar.innerHTML = "";

      if (analysis.valid) {
        this.diagBar.style.background = "rgba(39, 174, 96, 0.1)";
        this.diagBar.style.border = "1px solid rgba(39, 174, 96, 0.3)";
        this.diagBar.style.color = "var(--success-color-high, #27ae60)";
        this.diagBar.appendChild(
          E(
            "span",
            {},
            `✓ ${_("No errors or duplicates found")} (${analysis.validCount || 0})`,
          ),
        );
      } else {
        this.diagBar.style.background = "rgba(212, 68, 68, 0.1)";
        this.diagBar.style.border = "1px solid rgba(212, 68, 68, 0.35)";
        this.diagBar.style.color = "var(--error-color-medium, #d44)";
        const parts = [];
        if (analysis.duplicateCount > 0) {
          parts.push(`${_("Duplicates")}: ${analysis.duplicateCount}`);
        }
        if (analysis.syntaxErrorCount > 0) {
          parts.push(`${_("Syntax errors")}: ${analysis.syntaxErrorCount}`);
        }

        const leftGroup = E(
          "div",
          {
            style:
              "display:inline-flex;align-items:center;flex-wrap:wrap;gap:6px;",
          },
          [
            E(
              "span",
              {
                style:
                  "font-weight:600;display:inline-flex;align-items:center;gap:4px;",
              },
              [
                typeof main !== "undefined" &&
                typeof main.renderAlertTriangleIcon === "function"
                  ? main.renderAlertTriangleIcon(12)
                  : null,
                E(
                  "span",
                  {},
                  parts.join(" • ") || _("Validation errors detected"),
                ),
              ].filter(Boolean),
            ),
          ],
        );

        const dupItems = Array.isArray(analysis.duplicateItems)
          ? analysis.duplicateItems
          : [];
        if (dupItems.length > 0) {
          dupItems.slice(0, 5).forEach((dup) => {
            leftGroup.appendChild(
              E(
                "button",
                {
                  type: "button",
                  class: "tachyon-duplicate-chip",
                  title: _("Click to highlight in editor"),
                  style:
                    "padding:1px 6px;border-radius:4px;border:1px solid rgba(245, 158, 11, 0.55);background:rgba(245, 158, 11, 0.18);color:inherit;font-family:var(--tachyon-font-mono, monospace);font-size:11px;cursor:pointer;",
                  click: (ev) => {
                    ev.preventDefault();
                    this.textarea.focus();
                    if (typeof this.textarea.setSelectionRange === "function") {
                      this.textarea.setSelectionRange(dup.start, dup.end);
                    }
                  },
                },
                dup.value,
              ),
            );
          });
        }

        this.diagBar.appendChild(leftGroup);

        if (analysis.duplicateCount > 0) {
          const cleanBtn = E(
            "button",
            {
              type: "button",
              class: "btn cbi-button cbi-button-action",
              style:
                "padding:3px 10px;min-height:26px;font-size:11px;font-weight:600;cursor:pointer;",
              click: (ev) => {
                ev.preventDefault();
                this.textarea.value = deduplicateTextListPreservingComments(
                  this.textarea.value,
                  normalizeFn,
                );
                this.textarea.dispatchEvent(
                  new Event("input", { bubbles: true }),
                );
                this.textarea.dispatchEvent(
                  new Event("keyup", { bubbles: true }),
                );
                this.textarea.dispatchEvent(
                  new Event("change", { bubbles: true }),
                );
                if (option && typeof option.getUIElement === "function") {
                  const uiEl = option.getUIElement(sectionId);
                  if (uiEl && typeof uiEl.triggerValidation === "function") {
                    uiEl.triggerValidation();
                  }
                }
                if (option && typeof option.triggerValidation === "function") {
                  option.triggerValidation(sectionId);
                }
                this.update();
              },
            },
            `${_("Remove duplicates")} (${analysis.duplicateCount})`,
          );
          this.diagBar.appendChild(cleanBtn);
        }
      }
    },
  };

  textarea.__tachyonAnnotatedTextareaController = controller;

  const updateAnnotatedTextarea = () => {
    controller.update();
    if (option && typeof option.triggerValidation === "function") {
      option.triggerValidation(sectionId);
    }
  };
  const syncAnnotatedScroll = () => {
    overlay.scrollTop = textarea.scrollTop;
    overlay.scrollLeft = textarea.scrollLeft;
  };
  textarea.addEventListener("input", updateAnnotatedTextarea);
  textarea.addEventListener("change", updateAnnotatedTextarea);
  textarea.addEventListener("focus", () => controller.update());
  textarea.addEventListener("scroll", syncAnnotatedScroll, {
    passive: true,
  });
  textarea.addEventListener("keyup", updateAnnotatedTextarea);

  if (typeof ResizeObserver === "function") {
    const resizeObserver = new ResizeObserver(() => {
      if (!textarea.isConnected) {
        resizeObserver.disconnect();
        return;
      }
      controller.update();
    });
    resizeObserver.observe(textarea);
    controller.resizeObserver = resizeObserver;
  }

  controller.update();
  if (
    typeof window !== "undefined" &&
    typeof window.requestAnimationFrame === "function"
  ) {
    window.requestAnimationFrame(() => {
      controller.update();
      window.setTimeout(() => controller.update(), 30);
    });
  }
}

function getOptionTextarea(option, sectionId, rootNode = null) {
  if (rootNode) {
    if (rootNode.tagName === "TEXTAREA") {
      return rootNode;
    }
    if (typeof rootNode.querySelector === "function") {
      const nested = rootNode.querySelector("textarea");
      if (nested) {
        return nested;
      }
    }
  }

  if (typeof document === "undefined") {
    return null;
  }

  const cbid = option.cbid(sectionId);
  const direct = document.getElementById(`widget.${cbid}`);
  if (direct && direct.tagName === "TEXTAREA") {
    return direct;
  }

  const field = document.getElementById(cbid) || direct;
  if (field && typeof field.querySelector === "function") {
    return field.querySelector("textarea");
  }

  return null;
}

function configureTextareaOption(option, analyzer, normalizeFn) {
  const originalRenderWidget = option.renderWidget;
  const originalFormValue = option.formvalue;

  option.formvalue = function (section_id) {
    if (typeof this.isActive === "function" && !this.isActive(section_id)) {
      return null;
    }
    const ta = getOptionTextarea(this, section_id);
    if (ta && typeof ta.value === "string") {
      return ta.value;
    }
    return typeof originalFormValue === "function"
      ? originalFormValue.call(this, section_id)
      : null;
  };

  option.renderWidget = function (section_id, option_index, cfgvalue) {
    const node = originalRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    const textarea = getOptionTextarea(this, section_id, node);

    if (textarea) {
      applyTextareaInputAttributes(textarea);
      if (typeof analyzer === "function") {
        attachAnnotatedTextarea(
          textarea,
          analyzer,
          this,
          section_id,
          normalizeFn,
        );
      }
    }

    return node;
  };
}

function getConditionValidationIssues(sectionId) {
  const issues = [];
  const domText = loadCombinedDomainText(sectionId);
  if (domText) {
    const domAnalysis = analyzeDomainSuffixText(domText);
    if (!domAnalysis.valid) {
      if (domAnalysis.duplicateCount > 0) {
        issues.push(`${_("Duplicate domains")}: ${domAnalysis.duplicateCount}`);
      }
      if (domAnalysis.syntaxErrorCount > 0) {
        issues.push(`${_("Invalid domains")}: ${domAnalysis.syntaxErrorCount}`);
      }
    }
  }
  const userDomText = loadMultilineText(
    sectionId,
    "user_domains",
    "user_domains_text",
  );
  if (userDomText) {
    const uAnalysis = analyzeDomainSuffixText(userDomText);
    if (!uAnalysis.valid) {
      if (uAnalysis.duplicateCount > 0) {
        issues.push(
          `${_("Duplicate auto-domains")}: ${uAnalysis.duplicateCount}`,
        );
      }
      if (uAnalysis.syntaxErrorCount > 0) {
        issues.push(
          `${_("Invalid auto-domains")}: ${uAnalysis.syntaxErrorCount}`,
        );
      }
    }
  }
  const ipText = loadMultilineText(sectionId, "ip_cidr", "ip_cidr_text");
  if (ipText) {
    const ipAnalysis = analyzeIpCidrText(ipText);
    if (!ipAnalysis.valid) {
      if (ipAnalysis.duplicateCount > 0) {
        issues.push(`${_("Duplicate IPs")}: ${ipAnalysis.duplicateCount}`);
      }
      if (ipAnalysis.syntaxErrorCount > 0) {
        issues.push(`${_("Invalid IPs")}: ${ipAnalysis.syntaxErrorCount}`);
      }
    }
  }
  return issues;
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
    const issues = getConditionValidationIssues(sectionId);
    const issueBadge = issues.length
      ? `<span style="display:inline-flex;align-items:center;margin-left:6px;padding:1px 6px;border-radius:4px;font-size:11px;font-weight:600;background:rgba(212,68,68,0.15);color:var(--error-color-medium,#d44);border:1px solid rgba(212,68,68,0.4);" title="${escapeHtml(issues.join(" • "))}">${escapeHtml(issues.join(", "))}</span>`
      : "";
    return `<span style="display:inline-block;max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:bottom;" title="${escapeHtml(text)}">${escapeHtml(text)}</span>${issueBadge}`;
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
  if (typeof main.attachCommunityListPicker === "function") {
    main.attachCommunityListPicker(o);
  }
  const origCommWrite = o.write;
  o.write = function (sectionId, value) {
    const arr = asArray(value);
    if (typeof origCommWrite === "function") {
      origCommWrite.call(this, sectionId, value);
    } else {
      setArrayIfChanged(sectionId, "community_lists", arr);
    }
    const cid = String(sectionId || "");
    const syncParentSection = (secName) => {
      if (uci.get(UCI_PACKAGE, secName, ".type") === "section") {
        setArrayIfChanged(secName, "community_lists", arr);
      }
    };
    if (cid.startsWith("cond_")) {
      syncParentSection(cid.slice(5));
    }
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((sec) => {
      const sname = sec && sec[".name"];
      if (!sname) return;
      const refs = asArray(sec.condition_refs);
      if (refs.length === 1 && refs[0] === cid) {
        syncParentSection(sname);
      }
    });
  };
  const origCommRemove = o.remove;
  o.remove = function (sectionId) {
    if (typeof origCommRemove === "function") {
      origCommRemove.call(this, sectionId);
    } else {
      unsetIfPresent(sectionId, "community_lists");
    }
    const cid = String(sectionId || "");
    const unsetParentSection = (secName) => {
      if (uci.get(UCI_PACKAGE, secName, ".type") === "section") {
        unsetIfPresent(secName, "community_lists");
      }
    };
    if (cid.startsWith("cond_")) {
      unsetParentSection(cid.slice(5));
    }
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((sec) => {
      const sname = sec && sec[".name"];
      if (!sname) return;
      const refs = asArray(sec.condition_refs);
      if (refs.length === 1 && refs[0] === cid) {
        unsetParentSection(sname);
      }
    });
  };

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

  function syncConditionOptionToParentSection(condId, key, val) {
    const cid = String(condId || "");
    if (!cid) return;
    const targetSections = new Set();
    if (cid.startsWith("cond_")) {
      const parentSec = cid.slice(5);
      if (uci.get(UCI_PACKAGE, parentSec, ".type") === "section") {
        targetSections.add(parentSec);
      }
    }
    (uci.sections(UCI_PACKAGE, "section") || []).forEach((sec) => {
      const sname = sec && sec[".name"];
      if (!sname) return;
      const refs = asArray(sec.condition_refs);
      if (refs.length === 1 && refs[0] === cid) {
        targetSections.add(sname);
      }
    });
    targetSections.forEach((parentSec) => {
      if (
        val === null ||
        val === undefined ||
        val === "" ||
        (Array.isArray(val) && val.length === 0)
      ) {
        unsetIfPresent(parentSec, key);
      } else if (Array.isArray(val)) {
        setArrayIfChanged(parentSec, key, val);
      } else if (
        String(uci.get(UCI_PACKAGE, parentSec, key) ?? "") !== String(val)
      ) {
        uci.set(UCI_PACKAGE, parentSec, key, val);
      }
    });
  }

  function validateRuleSetOrUrlItem(_sectionId, value) {
    const normalized = String(value || "").trim();
    if (!normalized) return true;
    if (normalized.startsWith("/")) return true;
    if (/^[a-z0-9_:-]+$/i.test(normalized)) return true;
    if (typeof main.validateUrl === "function") {
      const res = main.validateUrl(normalized);
      return res.valid ? true : res.message;
    }
    return true;
  }

  function validatePortConditionItem(_sectionId, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (!normalized.length) return true;
    const match = normalized.match(/^(\d+)(?:-(\d+))?$/);
    if (!match) {
      return _("Invalid port or range. Use 80 or 1000-2000");
    }
    const start = Number.parseInt(match[1], 10);
    const end = match[2] ? Number.parseInt(match[2], 10) : start;
    if (start < 1 || start > 65535 || end < 1 || end > 65535) {
      return _("Port must be between 1 and 65535");
    }
    if (start > end) {
      return _("Port range start must be less than or equal to end");
    }
    return true;
  }

  function attachPendingConditionListInput(opt) {
    const baseFormValue = opt.formvalue || form.DynamicList.prototype.formvalue;
    opt.formvalue = function (sectionId) {
      if (typeof this.isActive === "function" && !this.isActive(sectionId)) {
        return null;
      }
      const raw = baseFormValue.call(this, sectionId);
      const list = Array.isArray(raw) ? raw.slice() : raw ? [raw] : [];
      if (typeof document === "undefined") return list;
      const widgetEl = document.getElementById(this.cbid(sectionId));
      if (!widgetEl) return list;
      const inputs = widgetEl.querySelectorAll(
        '.add-item input[type="text"], .cbi-dropdown input[type="text"]',
      );
      inputs.forEach((inp) => {
        const val = String((inp && inp.value) || "").trim();
        if (!val || list.includes(val)) return;
        if (validateRuleSetOrUrlItem(sectionId, val) !== true) return;
        list.push(val);
      });
      return list;
    };
  }

  o = section.taboption(
    "domains",
    form.DynamicList,
    "rule_set",
    _("Rule Sets (.srs / .json / URL)"),
    _("Remote or local sing-box rule-set URLs or paths (domains only)."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.validate = validateRuleSetOrUrlItem;
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asReferenceArray(value)));
    setArrayIfChanged(sectionId, "rule_set", arr);
    syncConditionOptionToParentSection(sectionId, "rule_set", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "rule_set");
    syncConditionOptionToParentSection(sectionId, "rule_set", null);
  };
  attachPendingConditionListInput(o);

  o = section.taboption(
    "domains",
    form.DynamicList,
    "rule_set_with_subnets",
    _("Rule Sets with Subnets"),
    _("Rule-sets that also extract IP/CIDR subnets into nftables."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.validate = validateRuleSetOrUrlItem;
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asReferenceArray(value)));
    setArrayIfChanged(sectionId, "rule_set_with_subnets", arr);
    syncConditionOptionToParentSection(sectionId, "rule_set_with_subnets", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "rule_set_with_subnets");
    syncConditionOptionToParentSection(
      sectionId,
      "rule_set_with_subnets",
      null,
    );
  };
  attachPendingConditionListInput(o);

  o = section.taboption(
    "domains",
    form.DynamicList,
    "domain_ip_lists",
    _("Plain Domain/IP Lists (.lst / .txt)"),
    _("URLs or local paths to plain-text domain/IP lists."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.validate = validateRuleSetOrUrlItem;
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asReferenceArray(value)));
    setArrayIfChanged(sectionId, "domain_ip_lists", arr);
    syncConditionOptionToParentSection(sectionId, "domain_ip_lists", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "domain_ip_lists");
    syncConditionOptionToParentSection(sectionId, "domain_ip_lists", null);
  };
  attachPendingConditionListInput(o);

  o = section.taboption(
    "domains",
    form.TextValue,
    "domain",
    _("Domains & Suffixes"),
    _(
      "One domain or rule per line (supports // comments, plain suffixes like youtube.com, or prefixes full:, domain:, keyword:, regex:). Checked for syntax errors and duplicates in real time.",
    ),
  );
  o.modalonly = true;
  o.rows = 8;
  o.wrap = "soft";
  o.textarea = true;
  o.depends("condition_type", "atomic");
  o.validate = function (_sectionId, value) {
    const analysis = analyzeDomainSuffixText(value);
    return analysis.valid ? true : analysis.message;
  };
  configureTextareaOption(o, analyzeDomainSuffixText, (tok) => {
    const lower = String(tok || "")
      .trim()
      .toLowerCase();
    return lower.startsWith("domain:") ? lower.slice(7) : lower;
  });
  o.load = function (sectionId) {
    return loadCombinedDomainText(sectionId);
  };
  o.cfgvalue = function (sectionId) {
    return loadCombinedDomainText(sectionId);
  };
  o.write = function (sectionId, value) {
    const text = String(value || "").trim();
    if (text) {
      if (
        loadCombinedDomainText(sectionId).trim() !== text ||
        String(uci.get(UCI_PACKAGE, sectionId, "domain") ?? "") !== text
      ) {
        uci.set(UCI_PACKAGE, sectionId, "domain", text);
      }
      syncConditionOptionToParentSection(sectionId, "domain", text);
    } else {
      unsetIfPresent(sectionId, "domain");
      syncConditionOptionToParentSection(sectionId, "domain", null);
    }
    [
      "domain_suffix",
      "domain_suffix_text",
      "domain_text",
      "domain_keyword",
      "domain_regex",
    ].forEach((k) => {
      unsetIfPresent(sectionId, k);
      syncConditionOptionToParentSection(sectionId, k, null);
    });
  };
  o.remove = function (sectionId) {
    [
      "domain",
      "domain_suffix",
      "domain_suffix_text",
      "domain_text",
      "domain_keyword",
      "domain_regex",
    ].forEach((k) => {
      unsetIfPresent(sectionId, k);
      syncConditionOptionToParentSection(sectionId, k, null);
    });
  };

  o = section.taboption(
    "domains",
    form.TextValue,
    "user_domains",
    _("Auto-detected Domains"),
    _(
      "Additional or auto-discovered domain suffixes (one per line). Checked for syntax errors and duplicates in real time.",
    ),
  );
  o.modalonly = true;
  o.rows = 5;
  o.wrap = "soft";
  o.textarea = true;
  o.depends("condition_type", "atomic");
  o.validate = function (_sectionId, value) {
    const analysis = analyzeDomainSuffixText(value);
    return analysis.valid ? true : analysis.message;
  };
  configureTextareaOption(o, analyzeDomainSuffixText, (tok) => {
    const lower = String(tok || "")
      .trim()
      .toLowerCase();
    return lower.startsWith("domain:") ? lower.slice(7) : lower;
  });
  o.load = function (sectionId) {
    return loadMultilineText(sectionId, "user_domains", "user_domains_text");
  };
  o.cfgvalue = function (sectionId) {
    return loadMultilineText(sectionId, "user_domains", "user_domains_text");
  };
  o.write = function (sectionId, value) {
    const lines = asArray(value);
    setArrayIfChanged(sectionId, "user_domains", lines);
    unsetIfPresent(sectionId, "user_domains_text");
    syncConditionOptionToParentSection(sectionId, "user_domains", lines);
    syncConditionOptionToParentSection(sectionId, "user_domains_text", null);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "user_domains");
    unsetIfPresent(sectionId, "user_domains_text");
    syncConditionOptionToParentSection(sectionId, "user_domains", null);
    syncConditionOptionToParentSection(sectionId, "user_domains_text", null);
  };

  // Network tab
  o = section.taboption(
    "network",
    form.TextValue,
    "ip_cidr",
    _("Destination IP / CIDR Subnets"),
    _(
      "Target IPv4/IPv6 addresses or CIDR blocks, one per line or comma-separated (supports // comments). Checked for syntax errors and duplicates in real time.",
    ),
  );
  o.modalonly = true;
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.depends("condition_type", "atomic");
  o.validate = function (_sectionId, value) {
    const analysis = analyzeIpCidrText(value);
    return analysis.valid ? true : analysis.message;
  };
  configureTextareaOption(o, analyzeIpCidrText, (tok) =>
    String(tok || "")
      .trim()
      .toLowerCase(),
  );
  o.load = function (sectionId) {
    return loadMultilineText(sectionId, "ip_cidr", "ip_cidr_text");
  };
  o.cfgvalue = function (sectionId) {
    return loadMultilineText(sectionId, "ip_cidr", "ip_cidr_text");
  };
  o.write = function (sectionId, value) {
    const text = String(value || "").trim();
    if (text) {
      if (
        loadMultilineText(sectionId, "ip_cidr", "ip_cidr_text").trim() !==
          text ||
        String(uci.get(UCI_PACKAGE, sectionId, "ip_cidr") ?? "") !== text
      ) {
        uci.set(UCI_PACKAGE, sectionId, "ip_cidr", text);
      }
      syncConditionOptionToParentSection(sectionId, "ip_cidr", text);
    } else {
      unsetIfPresent(sectionId, "ip_cidr");
      syncConditionOptionToParentSection(sectionId, "ip_cidr", null);
    }
    unsetIfPresent(sectionId, "ip_cidr_text");
    syncConditionOptionToParentSection(sectionId, "ip_cidr_text", null);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "ip_cidr");
    unsetIfPresent(sectionId, "ip_cidr_text");
    syncConditionOptionToParentSection(sectionId, "ip_cidr", null);
    syncConditionOptionToParentSection(sectionId, "ip_cidr_text", null);
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
  o.validate = function (_sectionId, value) {
    if (!value || !String(value).trim()) return true;
    const v = String(value).trim();
    if (
      typeof main.validateSubnet === "function" &&
      main.validateSubnet(v).valid
    ) {
      return true;
    }
    if (
      typeof main.validateDomain === "function" &&
      main.validateDomain(v, true).valid
    ) {
      return true;
    }
    return _("Enter a valid IP, CIDR subnet, or hostname");
  };
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asArray(value)));
    setArrayIfChanged(sectionId, "fully_routed_ips", arr);
    syncConditionOptionToParentSection(sectionId, "fully_routed_ips", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "fully_routed_ips");
    syncConditionOptionToParentSection(sectionId, "fully_routed_ips", null);
  };
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
  o.validate = function (_sectionId, value) {
    if (!value || !String(value).trim()) return true;
    if (typeof main.validateSubnet === "function") {
      const res = main.validateSubnet(String(value).trim());
      return res.valid ? true : res.message;
    }
    return true;
  };
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asArray(value)));
    setArrayIfChanged(sectionId, "excluded_ips", arr);
    syncConditionOptionToParentSection(sectionId, "excluded_ips", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "excluded_ips");
    syncConditionOptionToParentSection(sectionId, "excluded_ips", null);
  };
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
  o.validate = function (_sectionId, value) {
    if (!value || !String(value).trim()) return true;
    if (typeof main.validateSubnet === "function") {
      const res = main.validateSubnet(String(value).trim());
      return res.valid ? true : res.message;
    }
    return true;
  };
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asArray(value)));
    setArrayIfChanged(sectionId, "source_ip_cidr", arr);
    syncConditionOptionToParentSection(sectionId, "source_ip_cidr", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "source_ip_cidr");
    syncConditionOptionToParentSection(sectionId, "source_ip_cidr", null);
  };
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
  o.validate = function (_sectionId, value) {
    const v = String(value || "").trim();
    if (!v) return true;
    if (!/^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$/.test(v)) {
      return _("Invalid MAC address format (expected AA:BB:CC:DD:EE:FF)");
    }
    return true;
  };
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asArray(value)));
    setArrayIfChanged(sectionId, "source_macs", arr);
    syncConditionOptionToParentSection(sectionId, "source_macs", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "source_macs");
    syncConditionOptionToParentSection(sectionId, "source_macs", null);
  };

  o = section.taboption(
    "network",
    form.DynamicList,
    "source_inbounds",
    _("Inbound Servers (Capture Traffic)"),
    _(
      "Route traffic arriving from selected local Inbound servers (created in the Server tab) through this condition/section.",
    ),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.placeholder = _("-- Select Inbound Server --");
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    (uci.sections(UCI_PACKAGE, "server") || []).forEach((srv) => {
      const sid = srv && srv[".name"];
      if (!sid) return;
      const stype = String(srv.type || "vless").toUpperCase();
      const sport = srv.listen_port ? `:${srv.listen_port}` : "";
      const label = `${srv.label || sid} [${stype}${sport}]`;
      this.value(sid, label);
    });
    return asArray(uci.get(UCI_PACKAGE, sectionId, "source_inbounds"));
  };
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asArray(value)));
    setArrayIfChanged(sectionId, "source_inbounds", arr);
    syncConditionOptionToParentSection(sectionId, "source_inbounds", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "source_inbounds");
    syncConditionOptionToParentSection(sectionId, "source_inbounds", null);
  };

  o = section.taboption(
    "network",
    form.DynamicList,
    "ports",
    _("Destination Ports"),
    _("Single ports or ranges (e.g. 80, 443, 1000-2000)."),
  );
  o.modalonly = true;
  o.depends("condition_type", "atomic");
  o.validate = validatePortConditionItem;
  o.write = function (sectionId, value) {
    const arr = Array.from(new Set(asArray(value)));
    setArrayIfChanged(sectionId, "ports", arr);
    syncConditionOptionToParentSection(sectionId, "ports", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "ports");
    syncConditionOptionToParentSection(sectionId, "ports", null);
  };

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
  o.rmempty = true;
  o.depends("condition_type", "atomic");
  TRAFFIC_PROTOCOL_CHOICES.forEach(([val, label]) => o.value(val, label));
  o.load = function (sectionId) {
    return asArray(uci.get(UCI_PACKAGE, sectionId, "protocol"));
  };
  o.cfgvalue = function (sectionId) {
    return asArray(uci.get(UCI_PACKAGE, sectionId, "protocol"));
  };
  o.write = function (sectionId, value) {
    const arr = asArray(value);
    setArrayIfChanged(sectionId, "protocol", arr);
    syncConditionOptionToParentSection(sectionId, "protocol", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "protocol");
    syncConditionOptionToParentSection(sectionId, "protocol", null);
  };

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
  o.rmempty = true;
  o.depends("condition_type", "atomic");
  TRAFFIC_PROTOCOL_CHOICES.forEach(([val, label]) => o.value(val, label));
  o.load = function (sectionId) {
    return asArray(uci.get(UCI_PACKAGE, sectionId, "excluded_protocol"));
  };
  o.cfgvalue = function (sectionId) {
    return asArray(uci.get(UCI_PACKAGE, sectionId, "excluded_protocol"));
  };
  o.write = function (sectionId, value) {
    const arr = asArray(value);
    setArrayIfChanged(sectionId, "excluded_protocol", arr);
    syncConditionOptionToParentSection(sectionId, "excluded_protocol", arr);
  };
  o.remove = function (sectionId) {
    unsetIfPresent(sectionId, "excluded_protocol");
    syncConditionOptionToParentSection(sectionId, "excluded_protocol", null);
  };

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
  o.value("pl", _("🇵🇱 Poland (pl)"));
  o.value("ee", _("🇪🇪 Estonia (ee)"));
  o.value("lv", _("🇱🇻 Latvia (lv)"));
  o.value("lt", _("🇱🇹 Lithuania (lt)"));
  o.value("ch", _("🇨🇭 Switzerland (ch)"));
  o.value("at", _("🇦🇹 Austria (at)"));
  o.value("cz", _("🇨🇿 Czechia (cz)"));
  o.value("hk", _("🇭🇰 Hong Kong (hk)"));
}

return baseclass.extend({
  configureConditionsSection,
  createConditionsContent,
  analyzeDomainSuffixText,
  analyzeIpCidrText,
  getConditionValidationIssues,
});
