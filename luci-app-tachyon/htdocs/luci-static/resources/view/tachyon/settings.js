"use strict";
"require form";
"require uci";
"require baseclass";
"require fs";
"require tools.widgets as widgets";
"require view.tachyon.main as main";

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
  let o = section.option(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;

  const dnsOption = section.option(
    form.DynamicList,
    "dns_server",
    _("DNS Servers"),
    _(
      "Main DNS server. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  configureDnsList(dnsOption, main.DNS_SERVER_OPTIONS, "77.88.8.8");

  const bootstrapOption = section.option(
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

  o = section.option(
    form.Flag,
    "fallback_wan_main",
    _("Enable WAN DNS Fallback for Main DNS"),
    _("⚠️ If all Main DNS fail 3 times, queries will be sent to your ISP's DNS in plaintext. Only use as a last resort to prevent complete internet loss."),
  );
  o.default = o.disabled;

  o = section.option(
    form.Flag,
    "fallback_wan_bootstrap",
    _("Enable WAN DNS Fallback for Bootstrap DNS"),
    _("⚠️ If all Bootstrap DNS fail 3 times, queries will be sent to your ISP's DNS in plaintext. Only use as a last resort to prevent complete internet loss."),
  );
  o.default = o.disabled;


  o = section.option(
    form.Value,
    "dns_check_interval",
    _("DNS Check Interval"),
    _("How often to check the active DNS servers."),
  );
  configureDnsDuration(o, "10s", dnsOption, bootstrapOption);

  o = section.option(
    form.Value,
    "dns_recovery_check_interval",
    _("Higher-priority DNS Check"),
    _("How often to check whether a higher-priority DNS server has recovered."),
  );
  configureDnsDuration(o, "60s", dnsOption, bootstrapOption);

  o = section.option(
    form.Value,
    "dns_check_timeout",
    _("DNS Unavailability Timeout"),
    _(
      "Maximum time to wait for example.com to resolve during a DNS health check.",
    ),
  );
  configureDnsDuration(o, "2s", dnsOption, bootstrapOption);

  o = section.option(
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _("Time in seconds for DNS record caching (default: 60)"),
  );
  o.default = "60";
  o.rmempty = false;

  o = section.option(
    form.DynamicList,
    "dns_hosts",
    _("Custom DNS Records (Hosts)"),
    _("Map domains to specific IP addresses (A/AAAA). Format: <code>example.com 192.168.1.100</code>"),
  );
  o.validate = function(section_id, value) {
    if (!value) return true;
    var parts = value.trim().split(/\s+/);
    if (parts.length !== 2) {
      return _("Invalid format. Use: domain ip");
    }
    return true;
  };
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

  o = section.option(form.ListValue, "dns_strategy", _("DNS Strategy"));
  o.value("prefer_ipv4", _("Prefer IPv4"));
  o.value("ipv4_only", _("IPv4 only"));
  o.value("prefer_ipv6", _("Prefer IPv6"));
  o.value("ipv6_only", _("IPv6 only"));
  o.default = "prefer_ipv4";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "dns_detour_enabled",
    _("DNS through proxy"),
    _("Route main DNS requests through the selected section."),
  );
  configureDownloadViaProxyFlag(o, "dns_detour_section");

  o = section.option(
    form.ListValue,
    "dns_detour_section",
    _("DNS requests through section"),
  );
  o.depends("dns_detour_enabled", "1");
  configureDownloadSectionOption(o, "dns_detour_section", capabilities);

  o = section.option(
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

  o = section.option(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret key for authenticating remote access to YACD when WAN access is enabled.",
    ),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "isolate_p2p",
    _("P2P Leak Protection"),
    _(
      "Isolate BitTorrent traffic and force it direct to prevent VPN bans",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "list_update_enabled",
    _("Enable list updates"),
    _("Enable automatic updates for remote lists and rule sets"),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
    form.Flag,
    "component_update_check_enabled",
    _("Automatic component update checks"),
    _("Automatically check installed components for new versions"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download lists through a section"),
    _("Download remote lists and rule sets via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_lists_via_proxy_section");

  o = section.option(
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

  o = section.option(
    form.Flag,
    "download_components_via_proxy",
    _("Download components through a section"),
    _("Download component packages via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_components_via_proxy_section");

  o = section.option(
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

  o = section.option(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("Tachyon will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
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

  o = section.option(
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

  o = section.option(
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

  o = section.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o = section.option(
    form.Flag,
    "enable_watchdog",
    _("Enable Watchdog"),
    _(
      "Enables the background watchdog process to monitor services and auto-recover on failures.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  // Watchdog runtime status & controls
  const wdStatusOpt = section.option(
    form.DummyValue,
    "_watchdog_status",
    _("Watchdog Status"),
  );
  wdStatusOpt.rawhtml = true;
  wdStatusOpt.cfgvalue = function () {
    return createWatchdogStatusWidget();
  };
  wdStatusOpt.depends("enable_watchdog", "1");

  // Smart Detect
  o = section.option(
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
  const sdSectionsOpt = section.option(
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
}

const EntryPoint = {
  createSettingsContent,
  createTelegramContent,
};

return baseclass.extend(EntryPoint);
