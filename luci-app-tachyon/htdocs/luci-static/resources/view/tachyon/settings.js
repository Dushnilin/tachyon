"use strict";
"require form";
"require uci";
"require baseclass";
"require fs";
"require ui";
"require tools.widgets as widgets";
"require view.tachyon.main as main";
"require view.tachyon.local_devices as local_devices";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE;

function isSingBoxDuration(value) {
  return /^(?=.*[1-9])([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

function latencyTestUrlChoices() {
  return Array.isArray(main.LATENCY_TEST_URL_OPTIONS)
    ? main.LATENCY_TEST_URL_OPTIONS
    : [main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204"];
}

function validateLatencyTestUrl(value) {
  const validation = main.validateUrl(`${value || ""}`.trim());
  return validation.valid ? true : validation.message;
}

function isDownloadSectionAction(action, capabilities) {
  switch (action) {
    case "connection":
    case "proxy":
    case "outbound":
    case "vpn":
      return true;
    case "zapret":
      return !capabilities?.loaded || Boolean(capabilities.zapretInstalled);
    case "zapret2":
      return !capabilities?.loaded || Boolean(capabilities.zapret2Installed);
    case "byedpi":
      return !capabilities?.loaded || Boolean(capabilities.byedpiInstalled);
    default:
      return false;
  }
}

function refreshDownloadSectionChoices(option, capabilities) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const secName in sections) {
    const sec = sections[secName];
    if (
      sec[".type"] === "section" &&
      sec.enabled !== "0" &&
      isDownloadSectionAction(sec.action, capabilities)
    ) {
      option.value(secName, sec.label || secName);
    }
  }
}

function configureDownloadSectionOption(option, sectionOption, capabilities) {
  option.default = "";
  option.rmempty = false;
  option.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, sectionOption) || "";
  };
  option.load = function (section_id) {
    refreshDownloadSectionChoices(this, capabilities);
    return this.cfgvalue(section_id);
  };
  option.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized) {
      uci.set(UCI_PACKAGE, section_id, sectionOption, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
  option.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, sectionOption);
  };
  option.validate = function (_section_id, value) {
    return value ? true : _("Select a section");
  };
}

function configureDownloadViaProxyFlag(option, sectionOption) {
  option.default = "0";
  option.rmempty = false;
  option.write = function (section_id, value) {
    const enabled = value === "1" || value === true;
    uci.set(UCI_PACKAGE, section_id, this.option, enabled ? "1" : "0");
    if (!enabled) {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
}

function optionListValues(option, section_id) {
  const formValue = option.formvalue(section_id);
  const value = formValue != null ? formValue : option.cfgvalue(section_id);
  return L.toArray(value)
    .map((item) => `${item || ""}`.trim())
    .filter(Boolean);
}

function configureDnsList(option, choices, defaultValue) {
  Object.entries(choices).forEach(([key, label]) => {
    option.value(key, _(label));
  });
  option.default = [defaultValue];
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return optionListValues(option, _section_id).length > 0
        ? true
        : _("Add at least one DNS server");
    }
    const validation = main.validateDNS(normalized);
    return validation.valid ? true : validation.message;
  };
}

function configureDnsFailoverVisibility(option, dnsOption, bootstrapOption) {
  option.depends("dns_server", "__tachyon_multiple_dns__");
  option.depends("bootstrap_dns_server", "__tachyon_multiple_dns__");
  option.retain = true;
  option.checkDepends = function (section_id) {
    return (
      optionListValues(dnsOption, section_id).length > 1 ||
      optionListValues(bootstrapOption, section_id).length > 1
    );
  };
}

function refreshOptionChoices(option, choices) {
  delete option.keylist;
  delete option.vallist;
  (choices || []).forEach((choice) => {
    if (typeof choice === "object") {
      option.value(choice.value, choice.label);
    } else {
      option.value(choice);
    }
  });
}

function getDnsServerChoices(dnsType) {
  const servers = main.DNS_SERVERS_BY_PROTOCOL[dnsType] || main.DNS_SERVERS_BY_PROTOCOL.udp;
  return Object.entries(servers).map(([value, label]) => ({ value, label: _(label) }));
}

function configureDnsDynamicList(option, getChoices, defaultValue) {
  option.default = [defaultValue];
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return optionListValues(option, _section_id).length > 0
        ? true
        : _("Add at least one DNS server");
    }
    const validation = main.validateDNS(normalized);
    return validation.valid ? true : validation.message;
  };
  option.renderWidget = function (section_id, _option_index, cfgvalue) {
    const values = L.toArray(cfgvalue != null ? cfgvalue : this.default);
    const choices = getChoices(section_id, values);
    const labels = {};
    choices.forEach((choice) => {
      labels[choice.value] = choice.label;
    });
    refreshOptionChoices(this, choices);
    let choiceSignature = JSON.stringify(
      choices.map((choice) => [choice.value, choice.label]),
    );
    const widget = new ui.DynamicList(values, labels, {
      id: this.cbid(section_id),
      sort: this.keylist,
      optional: this.optional || this.rmempty,
      datatype: this.datatype,
      placeholder: this.placeholder,
      validate: L.bind(this.validate, this, section_id),
      disabled: this.readonly != null ? this.readonly : this.map.readonly,
    });
    const node = widget.render();
    const refreshChoices = () => {
      if (!node.isConnected) return false;
      const currentValues = widget.getValue();
      const currentChoices = getChoices(section_id, currentValues);
      const currentLabels = {};
      currentChoices.forEach((choice) => {
        currentLabels[choice.value] = choice.label;
      });
      const currentSignature = JSON.stringify(
        currentChoices.map((choice) => [choice.value, choice.label]),
      );
      if (currentSignature === choiceSignature) return;
      choiceSignature = currentSignature;
      refreshOptionChoices(this, currentChoices);
      widget.choices = currentLabels;
      widget.clearChoices();
      widget.addChoices(
        currentChoices.map((choice) => choice.value),
        currentLabels,
      );
    };
    const refreshBeforeOpening = (event) => {
      if (event.target && event.target.closest(".add-item")) refreshChoices();
    };
    node.addEventListener("mousedown", refreshBeforeOpening, true);
    node.addEventListener("focusin", refreshBeforeOpening, true);
    if (!settingsDnsDynamicState.refreshers.has(section_id)) {
      settingsDnsDynamicState.refreshers.set(section_id, new Set());
    }
    settingsDnsDynamicState.refreshers.get(section_id).add(refreshChoices);
    settingsDnsDynamicState.widget = widget;
    settingsDnsDynamicState.option = this;
    return node;
  };
}

const settingsDnsDynamicState = {
  dnsType: null,
  widget: null,
  option: null,
  refreshers: new Map(),
};

function getDefaultDnsServers(dnsType) {
  const servers = main.DNS_SERVERS_BY_PROTOCOL[dnsType] || main.DNS_SERVERS_BY_PROTOCOL.udp;
  const keys = Object.keys(servers);
  return keys.length > 0 ? [keys[0]] : ["77.88.8.8"];
}

function configureDnsDuration(
  option,
  defaultValue,
  dnsOption,
  bootstrapOption,
) {
  option.default = defaultValue;
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized || !isSingBoxDuration(normalized)) {
      return _("Use sing-box duration format like 10s, 1m or 2m30s");
    }
    return true;
  };
  configureDnsFailoverVisibility(option, dnsOption, bootstrapOption);
}

function createWatchdogStatusWidget() {
  const wrapper = E("div", {
    id: "tachyon-watchdog-status-widget",
    style: "display:flex;align-items:center;gap:12px;padding:4px 0;flex-wrap:wrap;",
  });

  const indicator = E("span", {
    style: "display:inline-flex;align-items:center;gap:6px;",
  });

  const dot = E("span", {
    id: "tachyon-watchdog-status-dot",
    style: "display:inline-block;width:10px;height:10px;border-radius:50%;background:#aaa;flex-shrink:0;",
  });

  const statusText = E("span", { id: "tachyon-watchdog-status-text" });
  statusText.textContent = _("Checking\u2026");

  indicator.appendChild(dot);
  indicator.appendChild(statusText);

  const btnStart = E("button", {
    class: "btn cbi-button cbi-button-action",
    type: "button",
    style: "display:none;",
  });
  btnStart.textContent = _("Start");

  const btnStop = E("button", {
    class: "btn cbi-button cbi-button-negative",
    type: "button",
    style: "display:none;",
  });
  btnStop.textContent = _("Stop");

  const msgEl = E("span", {
    style: "font-size:12px;color:var(--text-color-medium,#888);",
  });

  function applyWdStatus(running) {
    if (running) {
      dot.style.background = "#4caf50";
      statusText.textContent = _("Running");
      btnStart.style.display = "none";
      btnStop.style.display = "";
      btnStop.disabled = false;
    } else {
      dot.style.background = "#f44336";
      statusText.textContent = _("Stopped");
      btnStart.style.display = "";
      btnStart.disabled = false;
      btnStop.style.display = "none";
    }
  }

  function refreshWdStatus() {
    return fs
      .exec("/usr/bin/tachyon", ["watchdog", "status"])
      .then(function (res) {
        const out = ((res && res.stdout) || "").trim();
        try {
          const data = JSON.parse(out);
          applyWdStatus(Boolean(data.running));
        } catch (e) {
          applyWdStatus(out.indexOf("running") === 0);
        }
      })
      .catch(function () {
        dot.style.background = "#aaa";
        statusText.textContent = _("Unknown");
      });
  }

  btnStart.addEventListener("click", function () {
    btnStart.disabled = true;
    msgEl.textContent = _("Starting\u2026");
    fs.exec("/usr/bin/tachyon", ["watchdog_start"])
      .then(function () {
        msgEl.textContent = "";
        return refreshWdStatus();
      })
      .catch(function () {
        msgEl.textContent = _("Failed to start watchdog");
        btnStart.disabled = false;
      });
  });

  btnStop.addEventListener("click", function () {
    btnStop.disabled = true;
    msgEl.textContent = _("Stopping\u2026");
    fs.exec("/usr/bin/tachyon", ["watchdog_stop"])
      .then(function () {
        msgEl.textContent = "";
        return refreshWdStatus();
      })
      .catch(function () {
        msgEl.textContent = _("Failed to stop watchdog");
        btnStop.disabled = false;
      });
  });

  wrapper.appendChild(indicator);
  wrapper.appendChild(btnStart);
  wrapper.appendChild(btnStop);
  wrapper.appendChild(msgEl);

  refreshWdStatus();

  const wdTimer = setInterval(refreshWdStatus, 10000);
  const wdObserver = new MutationObserver(function () {
    if (!document.body.contains(wrapper)) {
      clearInterval(wdTimer);
      wdObserver.disconnect();
    }
  });
  wdObserver.observe(document.body, { childList: true, subtree: true });

  return wrapper;
}

function createSmartDetectSectionsWidget(section_id) {
  const TESTABLE_ACTIONS = ["connection", "proxy", "outbound", "vpn", "zapret", "zapret2", "byedpi"];
  const allSections = (uci.sections(UCI_PACKAGE, "section") || [])
    .filter(function (s) {
      return s.enabled !== "0" && TESTABLE_ACTIONS.indexOf(s.action) >= 0;
    })
    .map(function (s) { return s[".name"]; });

  if (allSections.length === 0) {
    const empty = E("em", { style: "color:var(--text-color-medium,#888);font-size:0.9rem;" });
    empty.textContent = _("No active routing sections found.");
    return empty;
  }

  const rawVal = uci.get(UCI_PACKAGE, section_id, "smart_detect_sections");
  const savedSections = L.toArray(rawVal || []);

  // Build ordered list: saved sections first (preserving order), then any not yet included
  const ordered = [];
  savedSections.forEach(function (name) {
    if (allSections.indexOf(name) >= 0 && ordered.indexOf(name) < 0) {
      ordered.push(name);
    }
  });
  allSections.forEach(function (name) {
    if (ordered.indexOf(name) < 0) ordered.push(name);
  });

  // enabledSet: which sections are checked
  const enabledSet = {};
  if (savedSections.length > 0) {
    savedSections.forEach(function (name) { enabledSet[name] = true; });
  } else if (ordered.length > 0) {
    enabledSet[ordered[0]] = true;
  }

  const wrapper = E("div", { id: "smart-detect-sections-widget-" + section_id });
  const listEl = E("div", {
    style: "border:1px solid var(--border-color,#dee2e6);border-radius:4px;overflow:hidden;margin-bottom:8px;max-width:480px;",
  });

  function updateValue() {
    wrapper.value = ordered.filter(function (name) {
      return Boolean(enabledSet[name]);
    });
  }

  function renderSdRow(name, idx, totalLen) {
    const isEnabled = Boolean(enabledSet[name]);
    const row = E("div", {
      style: [
        "display:flex;align-items:center;gap:10px;padding:7px 10px;",
        idx < totalLen - 1 ? "border-bottom:1px solid var(--border-color,#dee2e6);" : "",
        isEnabled ? "" : "opacity:0.5;",
      ].join(""),
    });

    const cb = E("input", { type: "checkbox" });
    cb.checked = isEnabled;
    cb.addEventListener("change", function (ev) {
      enabledSet[name] = ev.target.checked;
      updateValue();
      renderSdList();
    });

    const label = E("span", { style: "flex:1;font-family:monospace;font-size:0.9rem;user-select:none;" });
    label.textContent = name;

    const upBtn = E("button", {
      class: "btn",
      type: "button",
      style: "padding:1px 8px;font-size:0.75rem;line-height:1.4;border:1px solid var(--border-color,#ccc);border-radius:3px;background:transparent;cursor:pointer;",
    });
    upBtn.disabled = (idx === 0);
    upBtn.textContent = "\u25b3";
    upBtn.addEventListener("click", function () {
      if (idx > 0) {
        const tmp = ordered[idx - 1];
        ordered[idx - 1] = ordered[idx];
        ordered[idx] = tmp;
        updateValue();
        renderSdList();
      }
    });

    const downBtn = E("button", {
      class: "btn",
      type: "button",
      style: "padding:1px 8px;font-size:0.75rem;line-height:1.4;border:1px solid var(--border-color,#ccc);border-radius:3px;background:transparent;cursor:pointer;",
    });
    downBtn.disabled = (idx === totalLen - 1);
    downBtn.textContent = "\u25bd";
    downBtn.addEventListener("click", function () {
      if (idx < ordered.length - 1) {
        const tmp = ordered[idx + 1];
        ordered[idx + 1] = ordered[idx];
        ordered[idx] = tmp;
        updateValue();
        renderSdList();
      }
    });

    row.appendChild(cb);
    row.appendChild(label);
    row.appendChild(upBtn);
    row.appendChild(downBtn);
    return row;
  }

  function renderSdList() {
    while (listEl.firstChild) listEl.removeChild(listEl.firstChild);
    ordered.forEach(function (name, idx) {
      listEl.appendChild(renderSdRow(name, idx, ordered.length));
    });
  }

  renderSdList();
  updateValue();

  wrapper.appendChild(listEl);
  return wrapper;
}

function createSettingsContent(section, capabilities) {
  section.tab("dns", _("DNS Settings"));
  section.tab("network", _("Network & Interfaces"));
  section.tab("services", _("Services & Access"));
  section.tab("updates", _("Updates & Downloads"));
  section.tab("ai", _("AI & Watchdog"));
  section.tab("advanced", _("Advanced System"));

  settingsDnsDynamicState.dnsType = uci.get(UCI_PACKAGE, "settings", "dns_type") || "udp";

  let o = section.taboption(
    "dns",
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("doq", _("DNS over QUIC (DoQ)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;

  const dnsTypeOption = o;

  const dnsOption = section.taboption(
    "dns",
    form.DynamicList,
    "dns_server",
    _("DNS Servers"),
    _(
      "Main DNS server. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsDynamicList(dnsOption, (_section_id) => {
    const dnsType = settingsDnsDynamicState.dnsType || "udp";
    return getDnsServerChoices(dnsType);
  }, "77.88.8.8");

  const bootstrapOption = section.taboption(
    "dns",
    form.DynamicList,
    "bootstrap_dns_server",
    _("Bootstrap DNS Servers"),
    _(
      "DNS server used to obtain IP addresses for upstream DNS and proxies. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsList(
    bootstrapOption,
    main.BOOTSTRAP_DNS_SERVER_OPTIONS,
    "77.88.8.8",
  );

  dnsTypeOption.onchange = function (_ev, section_id, value) {
    const newType = value || "udp";
    if (newType === settingsDnsDynamicState.dnsType) return;
    settingsDnsDynamicState.dnsType = newType;

    const widget = settingsDnsDynamicState.widget;
    if (widget) {
      const servers = main.DNS_SERVERS_BY_PROTOCOL[newType] || main.DNS_SERVERS_BY_PROTOCOL.udp;
      const defaultLabels = {};
      Object.entries(servers).forEach(([v, l]) => { defaultLabels[v] = _(l); });
      const defaultServers = getDefaultDnsServers(newType);
      widget.choices = defaultLabels;
      widget.setValue(defaultServers);
    }

    const refreshers = settingsDnsDynamicState.refreshers.get(section_id);
    if (refreshers) {
      refreshers.forEach((fn) => fn());
    }
  };

  o = section.taboption(
    "dns",
    form.Flag,
    "fallback_wan_main",
    _("Enable WAN DNS Fallback for Main DNS"),
    _("⚠️ If all Main DNS fail 3 times, queries will be sent to your ISP's DNS in plaintext. Only use as a last resort to prevent complete internet loss."),
  );
  o.default = o.disabled;

  o = section.taboption(
    "dns",
    form.Flag,
    "fallback_wan_bootstrap",
    _("Enable WAN DNS Fallback for Bootstrap DNS"),
    _("⚠️ If all Bootstrap DNS fail 3 times, queries will be sent to your ISP's DNS in plaintext. Only use as a last resort to prevent complete internet loss."),
  );
  o.default = o.disabled;


  o = section.taboption(
    "dns",
    form.Value,
    "dns_check_interval",
    _("DNS Check Interval"),
    _("How often to check the active DNS servers."),
  );
  configureDnsDuration(o, "10s", dnsOption, bootstrapOption);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_recovery_check_interval",
    _("Higher-priority DNS Check"),
    _("How often to check whether a higher-priority DNS server has recovered."),
  );
  configureDnsDuration(o, "60s", dnsOption, bootstrapOption);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_check_timeout",
    _("DNS Unavailability Timeout"),
    _(
      "Maximum time to wait for example.com to resolve during a DNS health check.",
    ),
  );
  configureDnsDuration(o, "2s", dnsOption, bootstrapOption);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_failure_threshold",
    _("DNS Failures Before Switching"),
    _(
      "Number of consecutive failed checks required before switching DNS servers.",
    ),
  );
  o.default = "3";
  o.rmempty = false;
  o.datatype = "range(1, 10)";
  configureDnsFailoverVisibility(o, dnsOption, bootstrapOption);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_recovery_threshold",
    _("DNS Successful Checks Before Recovery"),
    _(
      "Number of consecutive successful checks required before returning to a higher-priority DNS server.",
    ),
  );
  o.default = "3";
  o.rmempty = false;
  o.datatype = "range(1, 10)";
  configureDnsFailoverVisibility(o, dnsOption, bootstrapOption);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _("Time in seconds for DNS record caching (default: 60)"),
  );
  o.default = "60";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("TTL value cannot be empty");
    }

    const ttl = parseInt(value);
    if (isNaN(ttl) || ttl < 0) {
      return _("TTL must be a positive number");
    }

    return true;
  };

  o = section.taboption(
    "dns",
    form.Flag,
    "dns_turbo_cache",
    _("DNS Turbo Cache"),
    _(
      "Keeps FakeIP cache persistent across reboots and pre-resolves popular blocked domains on startup so first-visit latency is 0\u00a0ms.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  // ─── DNS Strategy ────────────────────────────────────────────────────────

  o = section.taboption("dns", form.ListValue, "dns_strategy", _("DNS Strategy"));
  o.value("prefer_ipv4", _("Prefer IPv4"));
  o.value("ipv4_only", _("IPv4 only"));
  o.value("prefer_ipv6", _("Prefer IPv6"));
  o.value("ipv6_only", _("IPv6 only"));
  o.default = "prefer_ipv4";
  o.rmempty = false;

  o = section.taboption(
    "dns",
    form.Flag,
    "dns_detour_enabled",
    _("DNS through proxy"),
    _("Route main DNS requests through the selected section."),
  );
  configureDownloadViaProxyFlag(o, "dns_detour_section");

  o = section.taboption(
    "dns",
    form.ListValue,
    "dns_detour_section",
    _("DNS requests through section"),
  );
  o.depends("dns_detour_enabled", "1");
  configureDownloadSectionOption(o, "dns_detour_section", capabilities);

  o = section.taboption(
    "network",
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Block specific interface names from being selectable
    const blocked = ["wan", "phy0-ap0", "phy1-ap0", "pppoe-wan"];
    if (blocked.includes(value)) {
      return false;
    }

    // Try to find the device object by its name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Check the type of the device
    const type = device.getType();

    // Consider any Wi-Fi / wireless / wlan device as invalid
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    // Allow only non-wireless devices
    return !isWireless;
  };

  o = section.taboption(
    "network",
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    widgets.DeviceSelect,
    "output_network_interface",
    _("Output Network Interface"),
    _("Select the network interface to which the traffic will originate"),
  );
  o.noaliases = true;
  o.multiple = false;
  o.depends("enable_output_network_interface", "1");
  o.filter = function (section_id, value) {
    // Blocked interface names that should never be selectable
    const blockedInterfaces = ["br-lan"];

    // Reject immediately if the value matches any blocked interface
    if (blockedInterfaces.includes(value)) {
      return false;
    }

    // Reject lan*
    if (value.startsWith("lan")) {
      return false;
    }

    // Reject tun*, wg*, vpn*, awg*, oc*
    if (
      value.startsWith("tun") ||
      value.startsWith("wg") ||
      value.startsWith("vpn") ||
      value.startsWith("awg") ||
      value.startsWith("oc")
    ) {
      return false;
    }

    // Try to find the device object with the given name
    const device = this.devices.find((dev) => dev.getName() === value);

    // If no device is found, allow the value
    if (!device) {
      return true;
    }

    // Get the device type (e.g., "wifi", "ethernet", etc.)
    const type = device.getType();

    // Reject wireless-related devices
    const isWireless =
      type === "wifi" || type === "wireless" || type.includes("wlan");

    return !isWireless;
  };

  o = section.taboption(
    "network",
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    widgets.NetworkSelect,
    "badwan_monitored_interfaces",
    _("Monitored Interfaces"),
    _("Select the WAN interfaces to be monitored"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (["lan", "loopback"].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith("@")) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = section.taboption(
    "network",
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading Tachyon after interface UP"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.default = "2000";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Delay value cannot be empty");
    }
    return true;
  };

  o = section.taboption(
    "services",
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _(
      "Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall.",
    ),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret key for authenticating remote access to YACD when WAN access is enabled.",
    ),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.Flag,
    "isolate_p2p",
    _("P2P Leak Protection"),
    _(
      "Isolate BitTorrent traffic and force it direct to prevent VPN bans",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.Flag,
    "game_console_optimizer",
    _("Game Console Optimizer (NAT Type 1)"),
    _("Bypasses UDP traffic for selected game consoles (PS5/Xbox) to achieve NAT Type 1 / 2 (Full Cone NAT) for P2P matchmaking, while keeping TCP (PSN/Auth) routed through the proxy."),
  );
  o.default = "0";
  o.rmempty = false;

  const gameConsoleIpsOpt = section.taboption(
    "services",
    form.DynamicList,
    "game_console_ips",
    _("Game Console IPs"),
    _("Select or enter the IP addresses of your game consoles."),
  );
  gameConsoleIpsOpt.depends("game_console_optimizer", "1");
  gameConsoleIpsOpt.datatype = "ipaddr";
  gameConsoleIpsOpt.renderWidget = function (section_id, option_index, cfgvalue) {
    return local_devices.createLocalDeviceDynamicListWidget(
      this,
      section_id,
      cfgvalue,
    );
  };

  o = section.taboption(
    "updates",
    form.Flag,
    "list_update_enabled",
    _("Enable list updates"),
    _("Enable automatic updates for remote lists and rule sets"),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.taboption(
    "updates",
    form.Value,
    "update_interval",
    _("List Update Frequency"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("list_update_enabled", "1");
  o.placeholder = "1d";
  o.default = "1d";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "update_interval") || "1d";
  };
  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length) {
      uci.set(UCI_PACKAGE, section_id, "update_interval", normalized);
    } else {
      uci.set(UCI_PACKAGE, section_id, "update_interval", "1d");
    }
  };
  o.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (!normalized.length) {
      return _("Use sing-box duration format like 1d, 12h or 30m");
    }

    if (isSingBoxDuration(normalized)) {
      return true;
    }

    return _("Use sing-box duration format like 1d, 12h or 30m");
  };

  o = section.taboption(
    "updates",
    form.Flag,
    "download_all_presets",
    _("Pre-download all preset lists"),
    _(
      "Cache all built-in lists and databases even if they are not currently selected in any section. Recommended if you have plenty of storage space or USB drive.",
    ),
  );
  o.depends("list_update_enabled", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "updates",
    form.Flag,
    "component_update_check_enabled",
    _("Automatic component update checks"),
    _("Automatically check installed components for new versions"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "updates",
    form.Value,
    "component_update_check_interval",
    _("Component update check interval"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("component_update_check_enabled", "1");
  o.placeholder = "1d";
  o.default = "1d";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "component_update_check_interval") ||
      "1d"
    );
  };
  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    uci.set(
      UCI_PACKAGE,
      section_id,
      "component_update_check_interval",
      normalized.length ? normalized : "1d",
    );
  };
  o.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length && isSingBoxDuration(normalized)) {
      return true;
    }

    return _("Use sing-box duration format like 1d, 12h or 30m");
  };

  o = section.taboption(
    "updates",
    form.Value,
    "latency_test_url",
    _("Latency test URL"),
    _(
      "Default address for checking server availability and latency. URLTest uses its own address.",
    ),
  );
  latencyTestUrlChoices().forEach((value) => o.value(value));
  o.default =
    main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204";
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    return validateLatencyTestUrl(value);
  };

  o = section.taboption(
    "updates",
    form.Flag,
    "download_lists_via_proxy",
    _("Download lists through a section"),
    _("Download remote lists and rule sets via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_lists_via_proxy_section");

  o = section.taboption(
    "updates",
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download lists through"),
  );
  o.depends("download_lists_via_proxy", "1");
  configureDownloadSectionOption(
    o,
    "download_lists_via_proxy_section",
    capabilities,
  );

  o = section.taboption(
    "updates",
    form.Flag,
    "download_components_via_proxy",
    _("Download components through a section"),
    _("Download component packages via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_components_via_proxy_section");

  o = section.taboption(
    "updates",
    form.ListValue,
    "download_components_via_proxy_section",
    _("Download components through"),
  );
  o.depends("download_components_via_proxy", "1");
  configureDownloadSectionOption(
    o,
    "download_components_via_proxy_section",
    capabilities,
  );

  o = section.taboption(
    "advanced",
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Tachyon will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/etc/sing-box/config.json", "Flash (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "RAM (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "RAM (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    "Flash (/usr/share/sing-box/cache.db)",
  );
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("Cache file path cannot be empty");
    }

    if (!value.startsWith("/")) {
      return _("Path must be absolute (start with /)");
    }

    if (!value.endsWith("cache.db")) {
      return _("Path must end with cache.db");
    }

    const parts = value.split("/").filter(Boolean);
    if (parts.length < 2) {
      return _("Path must contain at least one directory (like /tmp/cache.db)");
    }

    return true;
  };

  o = section.taboption(
    "advanced",
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Select the log level for sing-box"),
  );
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warn");
  o.value("error", "Error");
  o.value("fatal", "Fatal");
  o.value("panic", "Panic");
  o.default = "warn";
  o.rmempty = false;

  // Anonymization and Security
  o = section.taboption(
    "advanced",
    form.Flag,
    "webrtc_leak_protect",
    _("WebRTC Leak Protection"),
    _("Detects and drops STUN/TURN packets in nftables to prevent real IP leaks via WebRTC.")
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "dns_doq_ech",
    _("Strict ECH + DoQ DNS Enforcer"),
    _("Forces sing-box to tunnel DNS requests via DoQ with Encrypted Client Hello (ECH) for SNI hiding.")
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "ai",
    form.Flag,
    "enable_watchdog",
    _("Enable Watchdog"),
    _(
      "Enables the background watchdog process to monitor services and auto-recover on failures.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  // AI Agent API Settings
  o = section.taboption(
    "ai",
    form.Value,
    "agent_api_token",
    _("AI Agent REST API Bearer Token"),
    _(
      "Secret token for authorizing WRITE operations (POST/PUT) on /cgi-bin/tachyon-agent/. Leave empty if auth is not required.",
    ),
  );
  o.password = true;
  o.rmempty = true;

  // AI Doctor (ChatGPT / LLM Integration)
  o = section.taboption(
    "ai",
    form.Flag,
    "enable_ai_doctor",
    _("Enable AI Doctor (ChatGPT / LLM Analysis)"),
    _(
      "Allows Tachyon to send diagnostic snapshots to ChatGPT or DeepSeek API for intelligent root-cause analysis and auto-repair recommendations.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "ai",
    form.ListValue,
    "ai_doctor_provider",
    _("AI Provider"),
    _("Select AI LLM provider for diagnostics"),
  );
  o.depends("enable_ai_doctor", "1");
  o.value("openai", "OpenAI (ChatGPT)");
  o.value("anthropic", "Anthropic (Claude API)");
  o.value("deepseek", "DeepSeek API");
  o.value("ollama", _("Ollama (Local PC / Server)"));
  o.value("lmstudio", _("LM Studio (Local PC / Server)"));
  o.value("custom", _("Custom OpenAI-Compatible API (OpenRouter)"));
  o.default = "openai";

  o = section.taboption(
    "ai",
    form.Value,
    "ai_doctor_model",
    _("AI Model"),
    _(
      "Model name to use. Leave empty to use default (gpt-4o-mini / claude-3-5-haiku / deepseek-chat / llama3:latest).",
    ),
  );
  o.depends("enable_ai_doctor", "1");
  o.rmempty = true;
  o.placeholder = _("(provider default)");

  o = section.taboption(
    "ai",
    form.ListValue,
    "ai_doctor_lang",
    _("AI Doctor Language"),
    _("Language for AI Doctor diagnosis responses"),
  );
  o.depends("enable_ai_doctor", "1");
  o.value("ru", "Русский (Russian)");
  o.value("en", "English");
  o.default = "ru";


  o = section.taboption(
    "ai",
    form.Value,
    "ai_doctor_api_key",
    _("AI API Key"),
    _("API Key for OpenAI (sk-...) or DeepSeek (optional for Ollama / LM Studio)"),
  );
  o.depends("enable_ai_doctor", "1");
  o.password = true;
  o.rmempty = true;

  o = section.taboption(
    "ai",
    form.Value,
    "ai_doctor_custom_url",
    _("Custom API Endpoint URL"),
    _(
      "Custom OpenAI-compatible API endpoint URL (e.g. http://192.168.1.100:11434/v1/chat/completions)",
    ),
  );
  o.depends("ai_doctor_provider", "custom");
  o.depends("ai_doctor_provider", "ollama");
  o.depends("ai_doctor_provider", "lmstudio");
  o.rmempty = true;
  o.placeholder = "http://192.168.1.100:11434/v1/chat/completions";

  // Watchdog runtime status & controls
  const wdStatusOpt = section.taboption(
    "ai",
    form.DummyValue,
    "_watchdog_status",
    _("Watchdog Status"),
  );
  wdStatusOpt.rawhtml = true;
  wdStatusOpt.cfgvalue = function () {
    return createWatchdogStatusWidget();
  };
  wdStatusOpt.depends("enable_watchdog", "1");

  // ─── AI Watchdog Settings ──────────────────────────────────────────────────

  // Proxy Health Monitor
  o = section.taboption("ai", form.Flag, "ai_proxy_health_enabled", _("Enable Proxy Health Monitor"),
    _("Periodically checks if the proxy is responding. Restarts Tachyon after consecutive failures."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption("ai", form.Value, "ai_proxy_health_interval", _("Proxy Health Check Interval (s)"),
    _("How often to check proxy health in seconds (fast tier, default 30)."));
  o.default = "30";
  o.datatype = "min(15)";
  o.depends("ai_proxy_health_enabled", "1");

  o = section.taboption("ai", form.Value, "ai_proxy_health_fail_threshold", _("Proxy Fail Threshold"),
    _("Number of consecutive failures before restarting (default 3)."));
  o.default = "3";
  o.datatype = "min(1)";
  o.depends("ai_proxy_health_enabled", "1");

  o = section.taboption("ai", form.Value, "ai_proxy_health_url", _("Proxy Health Check URL"),
    _("URL to test through the proxy (default: Cloudflare 204)."));
  o.default = "https://cp.cloudflare.com/generate_204";
  o.depends("ai_proxy_health_enabled", "1");

  // DNS Continuous Check
  o = section.taboption("ai", form.Flag, "ai_dns_continuous_enabled", _("Enable DNS Continuous Check"),
    _("Faster DNS health monitoring than the default cycle. Switches bootstrap DNS on failure."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption("ai", form.Value, "ai_dns_interval", _("DNS Check Interval (s)"),
    _("How often to check DNS health in seconds (default 60)."));
  o.default = "60";
  o.datatype = "min(30)";
  o.depends("ai_dns_continuous_enabled", "1");

  // Reload Dedup
  o = section.taboption("ai", form.Flag, "ai_reload_dedup_enabled", _("Enable Firewall Reload Dedup"),
    _("Prevents multiple reload_firewall calls within 120 seconds to avoid connection drops."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Metrics
  o = section.taboption("ai", form.Flag, "ai_metrics_enabled", _("Enable Health Metrics"),
    _("Records proxy/DNS latency and health status in hourly buckets for analysis."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption("ai", form.Value, "ai_metrics_retention_hours", _("Metrics Retention (hours)"),
    _("How many hours of metrics to keep (default 24)."));
  o.default = "24";
  o.datatype = "min(1)";
  o.depends("ai_metrics_enabled", "1");

  // Smart Cooldowns
  o = section.taboption("ai", form.Flag, "ai_smart_cooldowns_enabled", _("Enable Smart Cooldowns"),
    _("Use 3-tier check intervals: fast (15s), normal (120s), slow (300s) instead of a single interval."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Config Validation
  o = section.taboption("ai", form.Flag, "ai_config_validation_enabled", _("Enable Config Validation"),
    _("Validates sing-box config before restart to prevent boot loops on broken configs."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Graceful Degradation
  o = section.taboption("ai", form.Flag, "ai_graceful_degradation_enabled", _("Enable Graceful Degradation"),
    _("If one health check fails with an error, continue running other checks instead of stopping."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Persistent Smart Detect
  o = section.taboption("ai", form.Flag, "ai_persistent_smart_detect", _("Persistent Smart Detect"),
    _("Store auto-detected domains in /etc instead of /tmp to survive reboots."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Adaptive Intervals
  o = section.taboption("ai", form.Flag, "ai_adaptive_intervals_enabled", _("Enable Adaptive Intervals"),
    _("Automatically increase check intervals when healthy (to 5 min) and decrease on problems (to 120s)."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Anomaly Detection
  o = section.taboption("ai", form.Flag, "ai_anomaly_detection_enabled", _("Enable Anomaly Detection"),
    _("Monitors sing-box reconnect frequency. Alerts if too many reconnects per hour."));
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption("ai", form.Value, "ai_anomaly_reconnect_threshold", _("Reconnect Threshold"),
    _("Max reconnects per hour before alert (default 10)."));
  o.default = "10";
  o.datatype = "min(1)";
  o.depends("ai_anomaly_detection_enabled", "1");

  // ─── End AI Watchdog Settings ──────────────────────────────────────────────

  // Smart Detect
  o = section.taboption(
    "services",
    form.Flag,
    "smart_detect",
    _("Enable Smart Detect"),
    _(
      "Auto-detects blocked domains from logs and adds them to the first section where they work via proxy.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  // Smart Detect sections (domain test order)
  const sdSectionsOpt = section.taboption(
    "services",
    form.Value,
    "_smart_detect_sections",
    _("Domain test sections"),
    _(
      "Select and order the sections through which blocked domains are tested. Checked sections are tried top-to-bottom.",
    ),
  );
  sdSectionsOpt.rawhtml = true;
  sdSectionsOpt.depends("smart_detect", "1");
  sdSectionsOpt.renderWidget = function (section_id, option_index, cfgvalue) {
    return createSmartDetectSectionsWidget(section_id);
  };
  sdSectionsOpt.formvalue = function (section_id) {
    const el = document.getElementById("smart-detect-sections-widget-" + section_id);
    return el ? el.value : [];
  };
  sdSectionsOpt.write = function (section_id, formvalue) {
    if (Array.isArray(formvalue) && formvalue.length > 0) {
      uci.set(UCI_PACKAGE, section_id, "smart_detect_sections", formvalue);
    } else {
      uci.unset(UCI_PACKAGE, section_id, "smart_detect_sections");
    }
  };
  sdSectionsOpt.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "smart_detect_sections");
  };

  const sdDomainsOpt = section.option(
    form.DummyValue,
    "_smart_detect_domains",
    _("Auto-detected domains"),
    _("List of domains automatically detected and the section they were added to. To edit or remove them, open the routing rules of the respective section.")
  );
  sdDomainsOpt.depends("smart_detect", "1");
  sdDomainsOpt.rawhtml = true;
  sdDomainsOpt.cfgvalue = function (section_id) {
    const allDomains = [];
    const allSections = uci.sections(UCI_PACKAGE, "section") || [];
    allSections.forEach(function (s) {
      const ud = L.toArray(s.user_domains || []);
      ud.forEach(function (d) {
        allDomains.push({ domain: d, section: s[".name"] });
      });
    });

    if (allDomains.length === 0) {
      return "<em>" + _("No domains detected yet") + "</em>";
    }

    function esc(s) { return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
    let html = "<ul style=\"margin:0;padding-left:1.5rem;\">";
    allDomains.forEach(function (item) {
      html += "<li><code>" + esc(item.domain) + "</code> &rarr; <b>" + esc(item.section) + "</b></li>";
    });
    html += "</ul>";
    return html;
  };
}

function createTelegramStatusWidget() {
  const wrapper = E("div", {
    id: "tachyon-telegram-status-widget",
    style:
      "display:flex;align-items:center;gap:12px;padding:10px 0;flex-wrap:wrap;",
  });

  const indicator = E("span", {
    id: "tachyon-telegram-status-indicator",
    style:
      "display:inline-flex;align-items:center;gap:6px;font-weight:bold;font-size:14px;",
  });

  const dot = E("span", {
    id: "tachyon-telegram-status-dot",
    style:
      "display:inline-block;width:10px;height:10px;border-radius:50%;background:#aaa;",
  });

  const statusText = E("span", {
    id: "tachyon-telegram-status-text",
  });
  statusText.textContent = _("Checking…");

  indicator.appendChild(dot);
  indicator.appendChild(statusText);

  const btnStart = E("button", {
    id: "tachyon-telegram-btn-start",
    class: "btn cbi-button cbi-button-action",
    style: "display:none;",
  });
  btnStart.textContent = _("Start bot");

  const btnStop = E("button", {
    id: "tachyon-telegram-btn-stop",
    class: "btn cbi-button cbi-button-negative",
    style: "display:none;",
  });
  btnStop.textContent = _("Stop bot");

  const statusMsg = E("span", {
    id: "tachyon-telegram-status-msg",
    style: "font-size:12px;color:var(--text-color-medium,#888);",
  });

  function applyStatus(running, pid) {
    if (running) {
      dot.style.background = "#4caf50";
      statusText.textContent = pid
        ? _("Running") + " (PID " + pid + ")"
        : _("Running");
      btnStart.style.display = "none";
      btnStop.style.display = "";
    } else {
      dot.style.background = "#f44336";
      statusText.textContent = _("Stopped");
      btnStart.style.display = "";
      btnStop.style.display = "none";
    }
  }

  function refreshStatus() {
    return fs
      .exec("/usr/bin/tachyon", ["telegram_status"])
      .then(function (res) {
        const out = (res.stdout || "").trim();
        const pidMatch = out.match(/\(pid\s+(\d+)\)/);
        const pid = pidMatch ? pidMatch[1] : null;
        applyStatus(out.indexOf("running") === 0, pid);
      })
      .catch(function () {
        dot.style.background = "#aaa";
        statusText.textContent = _("Unknown");
      });
  }

  btnStart.addEventListener("click", function () {
    btnStart.disabled = true;
    statusMsg.textContent = _("Starting…");
    fs.exec("/usr/bin/tachyon", ["telegram_start"])
      .then(function () {
        statusMsg.textContent = "";
        return refreshStatus();
      })
      .catch(function () {
        statusMsg.textContent = _("Failed to start bot");
        btnStart.disabled = false;
      });
  });

  btnStop.addEventListener("click", function () {
    btnStop.disabled = true;
    statusMsg.textContent = _("Stopping…");
    fs.exec("/usr/bin/tachyon", ["telegram_stop"])
      .then(function () {
        statusMsg.textContent = "";
        return refreshStatus();
      })
      .catch(function () {
        statusMsg.textContent = _("Failed to stop bot");
        btnStop.disabled = false;
      });
  });

  wrapper.appendChild(indicator);
  wrapper.appendChild(btnStart);
  wrapper.appendChild(btnStop);
  wrapper.appendChild(statusMsg);

  // Initial status fetch
  refreshStatus();
  // Refresh every 10s while visible
  const timer = setInterval(refreshStatus, 10000);
  const observer = new MutationObserver(function () {
    if (!document.body.contains(wrapper)) {
      clearInterval(timer);
      observer.disconnect();
    }
  });
  observer.observe(document.body, { childList: true, subtree: true });

  return wrapper;
}

function createTelegramContent(section) {
  // Виджет статуса бота: показывает состояние и кнопки управления
  const statusOpt = section.option(
    form.DummyValue,
    "_telegram_status",
    _("Bot Status"),
  );
  statusOpt.rawhtml = true;
  statusOpt.cfgvalue = function () {
    return createTelegramStatusWidget();
  };

  let o = section.option(
    form.Flag,
    "enabled",
    _("Enable Telegram Bot"),
    _(
      "Enables the background daemon that polls Telegram for commands and sends notifications.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "bot_token",
    _("Telegram Bot Token"),
    _("Enter the API token obtained from @BotFather."),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.password = true;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (this.section.formvalue(section_id, "enabled") === "1" && !value) {
      return _("Token is required when the bot is enabled");
    }
    return true;
  };

  o = section.option(
    form.Value,
    "admin_ids",
    _("Administrator Chat IDs"),
    _(
      "Comma-separated list of Telegram user IDs authorized to control the bot.",
    ),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (this.section.formvalue(section_id, "enabled") === "1") {
      if (!value) {
        return _("At least one Admin Chat ID is required");
      }
      if (!/^-?[0-9]+(,-?[0-9]+)*$/.test(value)) {
        return _("Must be a comma-separated list of numeric IDs");
      }
    }
    return true;
  };

  o = section.option(
    form.Value,
    "poll_interval",
    _("Polling Interval (seconds)"),
    _("How often to check Telegram for new messages (default: 5)."),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "5";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (this.section.formvalue(section_id, "enabled") !== "1") {
      return true;
    }
    const val = parseInt(value);
    if (isNaN(val) || val < 1) {
      return _("Polling interval must be at least 1 second");
    }
    return true;
  };

  o = section.option(
    form.Flag,
    "notify_crash",
    _("Notify on Core Crashes"),
    _(
      "Send a Telegram notification if sing-box or nftables rules crash and get auto-restored.",
    ),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "notify_restart",
    _("Notify on Service Restarts"),
    _(
      "Send a Telegram notification if the Tachyon service is restarted by the watchdog.",
    ),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "notify_server_switch",
    _("Notify on Server Switches"),
    _(
      "Send a Telegram notification when a URLTest group switches to a new server.",
    ),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "notify_subscription",
    _("Notify on Subscription Updates"),
    _(
      "Send a Telegram notification when proxy subscriptions are successfully updated.",
    ),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "notify_cert",
    _("Notify on Certificate Warnings"),
    _(
      "Send a Telegram notification if SSL/TLS certificates are close to expiration.",
    ),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "notify_dns_leak",
    _("Notify on DNS Leaks"),
    _("Send a Telegram notification if a potential DNS leak is detected."),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "bot_proxy_section",
    _("Proxy Section for Bot"),
    _("Route bot API requests through this section. Leave empty to use the default mixed proxy."),
  );
  o.depends("enabled", "1");
  o.retain = true;
  o.default = "";
  o.rmempty = true;
  o.value("", _("Default (auto)"));
  o.load = function (section_id) {
    const sections = this.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};
    for (const secName in sections) {
      const sec = sections[secName];
      if (
        sec[".type"] === "section" &&
        sec.enabled !== "0" &&
        isDownloadSectionAction(sec.action, null)
      ) {
        this.value(secName, sec.label || secName);
      }
    }
    return uci.get(UCI_PACKAGE, "telegram", "bot_proxy_section") || "";
  };
  o.write = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (normalized) {
      uci.set(UCI_PACKAGE, "telegram", "bot_proxy_section", normalized);
    } else {
      uci.unset(UCI_PACKAGE, "telegram", "bot_proxy_section");
    }
  };
  o.remove = function () {
    uci.unset(UCI_PACKAGE, "telegram", "bot_proxy_section");
  };
}

const EntryPoint = {
  createSettingsContent,
  createTelegramContent,
};

return baseclass.extend(EntryPoint);
