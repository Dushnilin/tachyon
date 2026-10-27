"use strict";
"require form";
"require uci";
"require baseclass";
"require fs";
"require network";
"require ui";
"require tools.widgets as widgets";
"require view.tachyon.main as main";
"require view.tachyon.local_devices as local_devices";
"require view.tachyon.dns_speed_test as dns_speed_test";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE;

function _tr(ru, en) {
  const envLang =
    (typeof L !== "undefined" && L.env && L.env.lang) ||
    (typeof window !== "undefined" &&
      window.L &&
      window.L.env &&
      window.L.env.lang) ||
    "";
  const docLang = (
    (typeof document !== "undefined" &&
      document.documentElement &&
      document.documentElement.lang) ||
    (typeof document !== "undefined" &&
      document.querySelector("html")?.getAttribute("lang")) ||
    ""
  ).toLowerCase();
  const lang = (envLang || docLang).toLowerCase();
  const isRu =
    lang.startsWith("ru") ||
    (typeof _ === "function" &&
      (_("Status") === "Статус" ||
        _("Overview") === "Обзор" ||
        _("Save") === "Сохранить"));
  return isRu ? ru : en;
}

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

function disablePasswordAutofill(option) {
  if (!option || typeof option.renderWidget !== "function") return;
  const origRenderWidget = option.renderWidget;
  option.renderWidget = function (section_id, option_index, cfgvalue) {
    const node = origRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    const applyAttrs = function (el) {
      if (!el) return;
      const input = el.querySelector ? el.querySelector("input") || el : el;
      if (input && input.setAttribute) {
        input.setAttribute("autocomplete", "new-password");
        input.setAttribute("data-lpignore", "true");
        input.setAttribute("data-1p-ignore", "true");
        input.setAttribute("data-bwignore", "true");
      }
    };
    if (node instanceof Promise) {
      return node.then(function (res) {
        applyAttrs(res);
        return res;
      });
    }
    applyAttrs(node);
    return node;
  };
}

function isDownloadSectionAction(action, capabilities) {
  switch (action) {
    case "connection":
    case "proxy":
    case "outbound":
    case "vpn":
    case "group":
    case "fptn":
    case "awg":
    case "warp":
    case "anytls":
    case "snell":
    case "mieru":
    case "naive":
    case "sudoku":
    case "masque":
    case "openvpn":
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

function configureDefaultTunnelSectionOption(
  option,
  sectionOption,
  capabilities,
) {
  option.default = "";
  option.rmempty = true;
  option.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, sectionOption) || "";
  };
  option.load = function (section_id) {
    const sections = this.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};
    this.keylist = [""];
    this.vallist = [
      _tr(
        "Автоматически (первая активная секция)",
        "Auto (First available active section)",
      ),
    ];
    for (const secName in sections) {
      const sec = sections[secName];
      if (
        sec[".type"] === "section" &&
        sec.enabled !== "0" &&
        isDownloadSectionAction(sec.action, capabilities)
      ) {
        this.value(secName, sec.label || secName);
      }
    }
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
  const origRenderWidget = option.renderWidget;
  option.renderWidget = function (section_id, option_index, cfgvalue) {
    const node = origRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    if (this.speedTestController && node) {
      this.speedTestController.attachList(node, { alwaysEnabled: true });
    }
    return node;
  };
}

function configureDnsFailoverVisibility(
  option,
  dnsOption,
  bootstrapOption,
  fallbackOption,
) {
  option.depends("dns_server", "__tachyon_multiple_dns__");
  option.depends("bootstrap_dns_server", "__tachyon_multiple_dns__");
  option.retain = true;
  option.checkDepends = function (section_id) {
    if (
      optionListValues(dnsOption, section_id).length > 1 ||
      optionListValues(bootstrapOption, section_id).length > 1
    )
      return true;
    // Also show when explicit fallback servers are configured
    if (fallbackOption) {
      return optionListValues(fallbackOption, section_id).length > 0;
    }
    return false;
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
  const servers =
    main.DNS_SERVERS_BY_PROTOCOL[dnsType] || main.DNS_SERVERS_BY_PROTOCOL.udp;
  return Object.entries(servers).map(([value, label]) => ({
    value,
    label: _(label),
  }));
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
    if (this.speedTestController) this.speedTestController.attachList(node);
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
  const servers =
    main.DNS_SERVERS_BY_PROTOCOL[dnsType] || main.DNS_SERVERS_BY_PROTOCOL.udp;
  const keys = Object.keys(servers);
  return keys.length > 0 ? [keys[0]] : ["77.88.8.8"];
}

function configureDnsDuration(
  option,
  defaultValue,
  dnsOption,
  bootstrapOption,
  fallbackOption,
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
  configureDnsFailoverVisibility(
    option,
    dnsOption,
    bootstrapOption,
    fallbackOption,
  );
}

function createWatchdogStatusWidget() {
  const wrapper = E("div", {
    id: "tachyon-watchdog-status-widget",
    style:
      "display:flex;align-items:center;gap:12px;padding:4px 0;flex-wrap:wrap;",
  });

  const indicator = E("span", {
    style: "display:inline-flex;align-items:center;gap:6px;",
  });

  const dot = E("span", {
    id: "tachyon-watchdog-status-dot",
    style:
      "display:inline-block;width:10px;height:10px;border-radius:50%;background:#aaa;flex-shrink:0;",
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

  let wdInFlight = false;
  let wdHasMounted = false;
  let wdLoadedOnce = false;

  function refreshWdStatus(force) {
    if (wdInFlight) return Promise.resolve();
    if (
      !force &&
      (!wrapper.isConnected || wrapper.offsetParent === null || document.hidden)
    ) {
      return Promise.resolve();
    }
    wdInFlight = true;
    wdLoadedOnce = true;
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
      })
      .finally(function () {
        wdInFlight = false;
      });
  }

  btnStart.addEventListener("click", function () {
    btnStart.disabled = true;
    msgEl.textContent = _("Starting\u2026");
    fs.exec("/usr/bin/tachyon", ["watchdog_start"])
      .then(function () {
        msgEl.textContent = "";
        return refreshWdStatus(true);
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
        return refreshWdStatus(true);
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

  let wdVisibilityObserver = null;
  if (typeof IntersectionObserver !== "undefined") {
    wdVisibilityObserver = new IntersectionObserver(function (entries) {
      if (entries.some((e) => e.isIntersecting) && !wdLoadedOnce) {
        refreshWdStatus(true);
      }
    });
    wdVisibilityObserver.observe(wrapper);
  } else {
    refreshWdStatus(true);
  }

  const wdTimer = setInterval(function () {
    if (wrapper.isConnected) {
      wdHasMounted = true;
    } else if (wdHasMounted) {
      clearInterval(wdTimer);
      if (wdVisibilityObserver) wdVisibilityObserver.disconnect();
      return;
    }
    refreshWdStatus(false);
  }, 10000);

  return wrapper;
}

function createResetSettingsWidget() {
  const wrapper = E("div", {
    id: "tachyon-reset-settings-widget",
    style:
      "display:flex;align-items:center;gap:12px;padding:4px 0;flex-wrap:wrap;",
  });

  const btnReset = E("button", {
    class: "btn cbi-button cbi-button-negative",
    type: "button",
  });
  btnReset.textContent = _("Reset Settings");

  const msgEl = E("span", {
    style: "font-size:12px;color:var(--text-color-medium,#888);",
  });

  function performReset() {
    if (btnReset.disabled) return;
    btnReset.disabled = true;
    msgEl.textContent = _("Resetting\u2026");
    fs.exec("/usr/bin/tachyon", ["reset_settings"])
      .then(function (res) {
        let success = false;
        try {
          success = JSON.parse((res && res.stdout) || "").success !== false;
        } catch (e) {
          success = false;
        }
        if (!success) throw new Error("reset failed");
        msgEl.textContent = "";
        ui.addNotification(
          null,
          E(
            "p",
            {},
            _("Settings have been reset to defaults. The page will reload."),
          ),
          "info",
        );
        setTimeout(function () {
          location.reload();
        }, 1500);
      })
      .catch(function () {
        msgEl.textContent = _("Failed to reset settings");
        btnReset.disabled = false;
      });
  }

  btnReset.addEventListener("click", function () {
    ui.showModal(
      _("Reset Settings"),
      [
        E(
          "p",
          {},
          _(
            "This will erase all Tachyon settings and restore the factory defaults. The service will restart. This action cannot be undone.",
          ),
        ),
        E("div", { class: "button-row" }, [
          E(
            "button",
            {
              class: "btn cbi-button cbi-button-neutral",
              type: "button",
              click: function () {
                ui.hideModal();
              },
            },
            _("Cancel"),
          ),
          E(
            "button",
            {
              class: "btn cbi-button cbi-button-negative",
              type: "button",
              click: function () {
                ui.hideModal();
                performReset();
              },
            },
            _("Reset"),
          ),
        ]),
      ],
      "cbi-modal",
    );
  });

  wrapper.appendChild(btnReset);
  wrapper.appendChild(msgEl);

  return wrapper;
}

function createSnapshotsWidget() {
  const wrapper = E("div", {
    id: "tachyon-snapshots-widget",
    style: "display:flex;flex-direction:column;gap:8px;padding:4px 0;",
  });

  const btnSave = E("button", {
    class: "btn cbi-button cbi-button-positive",
    type: "button",
  });
  btnSave.textContent = _("Save Snapshot");

  const btnImport = E("button", {
    class: "btn cbi-button cbi-button-action",
    type: "button",
  });
  btnImport.textContent = _("Import Profile");

  const listEl = E("div", {
    style: "display:flex;flex-direction:column;gap:6px;",
  });

  function formatStamp(stamp) {
    if (!stamp) return "";
    return stamp.replace(
      /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/,
      "$1-$2-$3 $4:$5",
    );
  }

  function formatSize(size) {
    if (size == null) return "";
    if (size >= 1048576) return (size / 1048576).toFixed(1) + " MB";
    if (size >= 1024) return Math.round(size / 1024) + " KB";
    return size + " B";
  }

  function execSnapshotJson(args) {
    return fs.exec("/usr/bin/tachyon", args).then(function (res) {
      let parsed = null;
      try {
        const stdout = ((res && res.stdout) || "").trim();
        const match = stdout.match(/\{[\s\S]*\}/);
        parsed = JSON.parse(match ? match[0] : stdout);
      } catch (e) {
        parsed = null;
      }
      if (!parsed || parsed.success === false) {
        throw new Error((parsed && parsed.message) || "command failed");
      }
      return parsed;
    });
  }

  function execSnapshot(args) {
    return execSnapshotJson(args).then(function () {});
  }

  function showDiffModal(snap) {
    execSnapshotJson(["snapshot_diff", snap.file])
      .then(function (data) {
        const diffPre = E(
          "pre",
          {
            style:
              "max-height:320px;overflow:auto;padding:10px;border-radius:6px;border:1px solid var(--border-color,#dee2e6);background:var(--background-color-low,#f8f9fa);font-family:monospace;font-size:12px;white-space:pre-wrap;margin:8px 0;",
          },
          data.has_changes
            ? data.diff || ""
            : _("No differences with active configuration (secrets masked)."),
        );

        ui.showModal(
          _("Snapshot Diff") + ": " + (snap.name || ""),
          [
            E(
              "p",
              {
                style: "font-size:12px;color:var(--text-color-medium,#888);",
              },
              _(
                "Secrets and credentials are masked as ***. Added lines (+): ",
              ) +
                String(data.added_count || 0) +
                " · " +
                _("Removed lines (-): ") +
                String(data.removed_count || 0),
            ),
            diffPre,
            E("div", { class: "button-row" }, [
              E(
                "button",
                {
                  class: "btn cbi-button cbi-button-neutral",
                  type: "button",
                  click: function () {
                    ui.hideModal();
                  },
                },
                _("Close"),
              ),
              E(
                "button",
                {
                  class: "btn cbi-button cbi-button-negative",
                  type: "button",
                  click: function () {
                    ui.hideModal();
                    performRestore(snap.file);
                  },
                },
                _("Restore"),
              ),
            ]),
          ],
          "cbi-modal",
        );
      })
      .catch(function () {
        ui.addNotification(
          null,
          E("p", {}, _("Failed to compare snapshot")),
          "error",
        );
      });
  }

  function performExport(snap) {
    execSnapshotJson(["snapshot_export", snap.file])
      .then(function (data) {
        const payload = JSON.stringify(data.profile || data, null, 2);
        const blob = new Blob([payload], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download =
          (snap.name || "tachyon") +
          (snap.stamp ? "-" + snap.stamp : "") +
          ".tachyon-profile.json";
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
      })
      .catch(function () {
        ui.addNotification(
          null,
          E("p", {}, _("Failed to export snapshot")),
          "error",
        );
      });
  }

  function performRestore(file) {
    execSnapshot(["snapshot_restore", file])
      .then(function () {
        ui.addNotification(
          null,
          E(
            "p",
            {},
            _(
              "Snapshot restored. The service restarts and the page will reload.",
            ),
          ),
          "info",
        );
        setTimeout(function () {
          location.reload();
        }, 2500);
      })
      .catch(function () {
        ui.addNotification(
          null,
          E("p", {}, _("Failed to restore snapshot")),
          "error",
        );
        loadSnapshots();
      });
  }

  function performDelete(file) {
    execSnapshot(["snapshot_delete", file])
      .then(function () {
        loadSnapshots();
      })
      .catch(function () {
        ui.addNotification(
          null,
          E("p", {}, _("Failed to delete snapshot")),
          "error",
        );
      });
  }

  function loadSnapshots() {
    listEl.innerHTML = "";
    fs.exec("/usr/bin/tachyon", ["snapshot_list"])
      .then(function (res) {
        let snapshots = [];
        try {
          snapshots = (
            JSON.parse((res && res.stdout) || "").snapshots || []
          ).slice(0, 10);
        } catch (e) {
          snapshots = [];
        }
        if (snapshots.length === 0) {
          listEl.appendChild(
            E(
              "span",
              {
                style: "font-size:12px;color:var(--text-color-medium,#888);",
              },
              _("No snapshots yet"),
            ),
          );
          return;
        }
        snapshots.forEach(function (snap) {
          const row = E("div", {
            style:
              "display:flex;align-items:center;gap:10px;padding:2px 0;flex-wrap:wrap;",
          });
          row.appendChild(
            E("span", { style: "font-weight:bold;" }, snap.name || ""),
          );
          row.appendChild(
            E(
              "span",
              {
                style: "font-size:12px;color:var(--text-color-medium,#888);",
              },
              formatStamp(snap.stamp) +
                (snap.size != null ? " \u00b7 " + formatSize(snap.size) : ""),
            ),
          );
          row.appendChild(
            E(
              "button",
              {
                class: "btn cbi-button cbi-button-neutral",
                type: "button",
                click: function () {
                  showDiffModal(snap);
                },
              },
              _("Diff"),
            ),
          );
          row.appendChild(
            E(
              "button",
              {
                class: "btn cbi-button cbi-button-neutral",
                type: "button",
                click: function () {
                  performExport(snap);
                },
              },
              _("Export"),
            ),
          );
          row.appendChild(
            E(
              "button",
              {
                class: "btn cbi-button cbi-button-action",
                type: "button",
                click: function () {
                  ui.showModal(
                    _("Restore Snapshot"),
                    [
                      E(
                        "p",
                        {},
                        _(
                          "This will replace the current Tachyon settings with the snapshot",
                        ) +
                          ": \u201c" +
                          (snap.name || "") +
                          "\u201d. The service will restart.",
                      ),
                      E("div", { class: "button-row" }, [
                        E(
                          "button",
                          {
                            class: "btn cbi-button cbi-button-neutral",
                            type: "button",
                            click: function () {
                              ui.hideModal();
                            },
                          },
                          _("Cancel"),
                        ),
                        E(
                          "button",
                          {
                            class: "btn cbi-button cbi-button-negative",
                            type: "button",
                            click: function () {
                              ui.hideModal();
                              performRestore(snap.file);
                            },
                          },
                          _("Restore"),
                        ),
                      ]),
                    ],
                    "cbi-modal",
                  );
                },
              },
              _("Restore"),
            ),
          );
          row.appendChild(
            E(
              "button",
              {
                class: "btn cbi-button cbi-button-negative",
                type: "button",
                click: function () {
                  ui.showModal(
                    _("Delete Snapshot"),
                    [
                      E(
                        "p",
                        {},
                        _("Delete the snapshot") +
                          ": \u201c" +
                          (snap.name || "") +
                          "\u201d?",
                      ),
                      E("div", { class: "button-row" }, [
                        E(
                          "button",
                          {
                            class: "btn cbi-button cbi-button-neutral",
                            type: "button",
                            click: function () {
                              ui.hideModal();
                            },
                          },
                          _("Cancel"),
                        ),
                        E(
                          "button",
                          {
                            class: "btn cbi-button cbi-button-negative",
                            type: "button",
                            click: function () {
                              ui.hideModal();
                              performDelete(snap.file);
                            },
                          },
                          _("Delete"),
                        ),
                      ]),
                    ],
                    "cbi-modal",
                  );
                },
              },
              _("Delete"),
            ),
          );
          listEl.appendChild(row);
        });
      })
      .catch(function () {
        listEl.appendChild(
          E(
            "span",
            {
              style: "font-size:12px;color:var(--text-color-medium,#888);",
            },
            _("Failed to load snapshots"),
          ),
        );
      });
  }

  btnSave.addEventListener("click", function () {
    const input = E("input", {
      type: "text",
      class: "cbi-input-text",
      style: "width:100%;",
      maxlength: 64,
    });
    input.placeholder = _("Snapshot name");
    ui.showModal(
      _("Save Snapshot"),
      [
        E(
          "p",
          {},
          _(
            "Give the snapshot a name. It is saved with the current date and can be restored from this list later.",
          ),
        ),
        input,
        E("div", { class: "button-row" }, [
          E(
            "button",
            {
              class: "btn cbi-button cbi-button-neutral",
              type: "button",
              click: function () {
                ui.hideModal();
              },
            },
            _("Cancel"),
          ),
          E(
            "button",
            {
              class: "btn cbi-button cbi-button-positive",
              type: "button",
              click: function () {
                const name = (input.value || "").trim();
                if (!name) return;
                ui.hideModal();
                execSnapshot(["snapshot_save", name])
                  .then(function () {
                    loadSnapshots();
                  })
                  .catch(function () {
                    ui.addNotification(
                      null,
                      E("p", {}, _("Failed to save snapshot")),
                      "error",
                    );
                  });
              },
            },
            _("Save"),
          ),
        ]),
      ],
      "cbi-modal",
    );
  });

  btnImport.addEventListener("click", function () {
    const textarea = E("textarea", {
      class: "cbi-input-textarea",
      style:
        "width:100%;min-height:140px;font-family:monospace;font-size:12px;",
      placeholder: '{"format": "tachyon-profile-v1", ...}',
    });
    const fileInput = E("input", {
      type: "file",
      accept: ".json,application/json",
      style: "margin-bottom:8px;",
    });
    fileInput.addEventListener("change", function () {
      const f = fileInput.files && fileInput.files[0];
      if (!f) return;
      const reader = new FileReader();
      reader.onload = function (ev) {
        textarea.value = String((ev && ev.target && ev.target.result) || "");
      };
      reader.readAsText(f);
    });

    ui.showModal(
      _("Import Snapshot Profile"),
      [
        E(
          "p",
          {},
          _(
            "Select an exported .tachyon-profile.json file or paste its JSON contents below.",
          ),
        ),
        fileInput,
        textarea,
        E("div", { class: "button-row" }, [
          E(
            "button",
            {
              class: "btn cbi-button cbi-button-neutral",
              type: "button",
              click: function () {
                ui.hideModal();
              },
            },
            _("Cancel"),
          ),
          E(
            "button",
            {
              class: "btn cbi-button cbi-button-positive",
              type: "button",
              click: function () {
                const raw = (textarea.value || "").trim();
                if (!raw) return;
                ui.hideModal();
                execSnapshot(["snapshot_import", raw])
                  .then(function () {
                    loadSnapshots();
                  })
                  .catch(function () {
                    ui.addNotification(
                      null,
                      E("p", {}, _("Failed to import snapshot profile")),
                      "error",
                    );
                  });
              },
            },
            _("Import"),
          ),
        ]),
      ],
      "cbi-modal",
    );
  });

  wrapper.appendChild(
    E(
      "div",
      {
        style: "display:flex;align-items:center;gap:12px;flex-wrap:wrap;",
      },
      [
        btnSave,
        btnImport,
        E(
          "span",
          {
            style: "font-size:12px;color:var(--text-color-medium,#888);",
          },
          _(
            "Up to 10 snapshots are kept; the oldest ones are removed automatically.",
          ),
        ),
      ],
    ),
  );
  wrapper.appendChild(listEl);

  if (typeof IntersectionObserver !== "undefined") {
    let snapshotsLoaded = false;
    const snapObserver = new IntersectionObserver(function (entries) {
      if (entries.some((e) => e.isIntersecting) && !snapshotsLoaded) {
        snapshotsLoaded = true;
        snapObserver.disconnect();
        loadSnapshots();
      }
    });
    snapObserver.observe(wrapper);
  } else {
    loadSnapshots();
  }

  return wrapper;
}

function createSmartDetectSectionsWidget(section_id) {
  const TESTABLE_ACTIONS = [
    "connection",
    "proxy",
    "outbound",
    "vpn",
    "group",
    "awg",
    "warp",
    "anytls",
    "snell",
    "mieru",
    "sudoku",
    "masque",
    "openvpn",
    "wdtt",
    "olcrtc",
    "fptn",
  ];
  const sectionActionByName = {};
  const allSections = (uci.sections(UCI_PACKAGE, "section") || [])
    .filter(function (s) {
      return s.enabled !== "0" && TESTABLE_ACTIONS.indexOf(s.action) >= 0;
    })
    .map(function (s) {
      sectionActionByName[s[".name"]] = s.action;
      return s[".name"];
    });

  if (allSections.length === 0) {
    const empty = E("em", {
      style: "color:var(--text-color-medium,#888);font-size:0.9rem;",
    });
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
    savedSections.forEach(function (name) {
      enabledSet[name] = true;
    });
  } else if (ordered.length > 0) {
    enabledSet[ordered[0]] = true;
  }

  const wrapper = E("div", {
    id: "smart-detect-sections-widget-" + section_id,
  });
  const listEl = E("div", {
    style:
      "border:1px solid var(--border-color,#dee2e6);border-radius:4px;overflow:hidden;margin-bottom:8px;max-width:480px;",
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
        idx < totalLen - 1
          ? "border-bottom:1px solid var(--border-color,#dee2e6);"
          : "",
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

    const label = E("span", {
      style: "flex:1;font-family:monospace;font-size:0.9rem;user-select:none;",
    });
    label.textContent = name;

    const upBtn = E("button", {
      class: "btn",
      type: "button",
      style:
        "padding:1px 8px;font-size:0.75rem;line-height:1.4;border:1px solid var(--border-color,#ccc);border-radius:3px;background:transparent;cursor:pointer;",
    });
    upBtn.disabled = idx === 0;
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
      style:
        "padding:1px 8px;font-size:0.75rem;line-height:1.4;border:1px solid var(--border-color,#ccc);border-radius:3px;background:transparent;cursor:pointer;",
    });
    downBtn.disabled = idx === totalLen - 1;
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
    if (sectionActionByName[name] === "group") {
      const groupBadge = E("span", {
        "data-section-type": "group",
        title: _(
          "Routing rule target: detected domains are saved to the group's rules, and the group's own logic selects the active member.",
        ),
        style:
          "display:inline-block;padding:1px 6px;font-size:0.75rem;font-weight:600;line-height:1.4;border-radius:4px;background:rgba(49,130,206,0.12);color:var(--blue-color,#3182ce);border:1px solid rgba(49,130,206,0.3);user-select:none;",
      });
      groupBadge.textContent = _("Group");
      row.appendChild(groupBadge);
    }
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

function createMenuTabsOrderWidget(option, section_id) {
  const ALL_MENU_TABS = [
    {
      id: "dashboard",
      label: _tr("Дашборд", "Dashboard"),
      desc: _tr(
        "Главный экран и виджеты статуса",
        "Main overview and status widgets",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "section",
      label: _tr("Секции", "Sections"),
      desc: _tr(
        "Секции маршрутизации, правила и стратегии",
        "Routing sections, rules and strategies",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "server",
      label: _tr("Серверы", "Servers"),
      desc: _tr(
        "Внешние серверы и входящие подключения",
        "External inbound proxy servers",
      ),
      defaultVisible: false,
      fixed: false,
    },
    {
      id: "profile",
      label: _tr("Семейные профили", "Family Profiles"),
      desc: _tr(
        "Семейные профили и группы устройств",
        "Family profiles and device grouping",
      ),
      defaultVisible: false,
      fixed: false,
    },
    {
      id: "schedule",
      label: _tr("Родительский контроль", "Parental Control"),
      desc: _tr(
        "Расписание доступа и лимиты экранного времени",
        "Access schedule and screen time limits",
      ),
      defaultVisible: false,
      fixed: false,
    },
    {
      id: "guest_mode",
      label: _tr("Гостевой режим", "Guest Mode"),
      desc: _tr(
        "Изоляция гостевой сети и квоты устройств",
        "Guest network isolation and device quotas",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "monitoring",
      label: _tr("Мониторинг", "Monitoring"),
      desc: _tr(
        "Статистика трафика и активные соединения",
        "Traffic statistics and active connections",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "diagnostic",
      label: _tr("Диагностика", "Diagnostics"),
      desc: _tr(
        "Системная диагностика, AI Доктор и журналы",
        "System diagnostics, AI Doctor and logs",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "updates",
      label: _tr("Компоненты", "Components"),
      desc: _tr(
        "Версии компонентов и менеджер обновлений",
        "Component versions and update manager",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "settings",
      label: _tr("Настройки", "Settings"),
      desc: _tr(
        "Основные настройки системы",
        "Core configuration and preferences",
      ),
      defaultVisible: true,
      fixed: true,
    },
    {
      id: "telegram",
      label: _tr("Телеграм-бот", "Telegram Bot"),
      desc: _tr(
        "Удаленное управление через Telegram",
        "Remote management Telegram daemon",
      ),
      defaultVisible: true,
      fixed: false,
    },
  ];

  const rawTabOrder = uci.get(UCI_PACKAGE, section_id, "tab_order");
  const savedOrder = Array.isArray(rawTabOrder)
    ? rawTabOrder
    : typeof rawTabOrder === "string" && rawTabOrder.trim()
      ? rawTabOrder.trim().split(/\s+/)
      : [];

  const tabMap = {};
  ALL_MENU_TABS.forEach(function (t) {
    tabMap[t.id] = t;
  });

  const ordered = [];
  savedOrder.forEach(function (id) {
    if (tabMap[id] && ordered.indexOf(id) < 0) {
      ordered.push(id);
    }
  });
  ALL_MENU_TABS.forEach(function (t) {
    if (ordered.indexOf(t.id) < 0) {
      ordered.push(t.id);
    }
  });

  const visibility = {};
  ALL_MENU_TABS.forEach(function (t) {
    if (t.fixed) {
      visibility[t.id] = true;
    } else {
      let optKey = "show_tab_" + t.id;
      if (t.id === "server") optKey = "show_tab_servers";
      else if (t.id === "profile") optKey = "show_tab_profiles";
      else if (t.id === "schedule") optKey = "show_tab_parental";

      const val = uci.get(UCI_PACKAGE, section_id, optKey);
      if (val === undefined || val === null || val === "") {
        visibility[t.id] = t.defaultVisible;
      } else {
        visibility[t.id] = val === "1" || val === true;
      }
    }
  });

  const wrapper = E("div", { id: "menu-tabs-order-widget-" + section_id });
  const listEl = E("div", {
    style:
      "border:1px solid var(--border-color,#dee2e6);border-radius:6px;overflow:hidden;margin-bottom:8px;max-width:560px;background:var(--card-bg,transparent);",
  });

  function syncToUci() {
    // Only write what actually differs. This ran unconditionally at the end of
    // every widget render, so simply opening the settings page rewrote the whole
    // tab_order list plus one show_tab_* option per tab into the UCI session -
    // a burst of add_list operations on /etc/config/tachyon for a value that had
    // not changed. That is flash wear for nothing, and it is what showed up in a
    // Telegram ticket as a config change list with nothing actually changed.
    const sameOrder =
      Array.isArray(savedOrder) &&
      savedOrder.length === ordered.length &&
      savedOrder.every((id, i) => id === ordered[i]);
    if (!sameOrder) {
      uci.set(UCI_PACKAGE, section_id, "tab_order", ordered);
    }
    wrapper._order = ordered.slice();
    wrapper._vis = Object.assign({}, visibility);
    ALL_MENU_TABS.forEach(function (t) {
      if (!t.fixed) {
        let optKey = "show_tab_" + t.id;
        if (t.id === "server") optKey = "show_tab_servers";
        else if (t.id === "profile") optKey = "show_tab_profiles";
        else if (t.id === "schedule") optKey = "show_tab_parental";
        const next = visibility[t.id] ? "1" : "0";
        // uci.get returns undefined for an option that was never set, which is
        // not the same as "0" and must not be read as a match.
        const prev = uci.get(UCI_PACKAGE, section_id, optKey);
        if (prev !== next) {
          uci.set(UCI_PACKAGE, section_id, optKey, next);
        }
      }
    });
  }

  function renderTabRow(id, idx, totalLen) {
    const tabMeta = tabMap[id] || { id: id, label: id, desc: "", fixed: false };
    const isVisible = Boolean(visibility[id]);
    const isFixed = Boolean(tabMeta.fixed);

    const row = E("div", {
      style: [
        "display:flex;align-items:center;gap:12px;padding:8px 12px;",
        idx < totalLen - 1
          ? "border-bottom:1px solid var(--border-color,#dee2e6);"
          : "",
        isVisible ? "" : "opacity:0.5;background:rgba(0,0,0,0.02);",
      ].join(""),
    });

    const badge = E(
      "span",
      {
        style:
          "font-size:0.75rem;font-weight:bold;color:var(--text-color-medium,#888);min-width:18px;text-align:center;",
      },
      String(idx + 1),
    );

    // Use a <button> toggle instead of <input type="checkbox"> to avoid LuCI
    // theme pointer-events overrides that swallow checkbox click events.
    const toggleBtn = E("button", {
      type: "button",
      title: isFixed
        ? _("Always visible")
        : isVisible
          ? _("Click to hide")
          : _("Click to show"),
      style: [
        "width:20px;height:20px;padding:0;border-radius:3px;border:2px solid;",
        "display:flex;align-items:center;justify-content:center;",
        "font-size:13px;font-weight:bold;line-height:1;cursor:",
        isFixed ? "default;" : "pointer;",
        "flex-shrink:0;",
        isFixed || isVisible
          ? "border-color:var(--primary-color,#2196f3);background:var(--primary-color,#2196f3);color:#fff;"
          : "border-color:var(--border-color,#aaa);background:transparent;color:transparent;",
      ].join(""),
    });
    toggleBtn.textContent = "✓";
    if (isFixed) toggleBtn.disabled = true;

    if (!isFixed) {
      toggleBtn.addEventListener("click", function (ev) {
        ev.preventDefault();
        visibility[id] = !visibility[id];
        syncToUci();
        renderList();
      });
    }

    const textCol = E(
      "div",
      {
        style: "flex:1;display:flex;flex-direction:column;",
      },
      [
        E("span", { style: "font-weight:600;font-size:0.95rem;" }, [
          tabMeta.label,
          isFixed
            ? E(
                "em",
                {
                  style:
                    "font-size:0.75rem;font-weight:normal;margin-left:6px;color:var(--text-color-medium,#888);",
                },
                " (" + _("Always visible") + ")",
              )
            : "",
        ]),
        tabMeta.desc
          ? E(
              "span",
              {
                style: "font-size:0.75rem;color:var(--text-color-medium,#888);",
              },
              tabMeta.desc,
            )
          : "",
      ],
    );

    const upBtn = E(
      "button",
      {
        class: "btn cbi-button",
        type: "button",
        title: _("Move Up"),
        style:
          "padding:2px 8px;font-size:0.8rem;line-height:1.2;cursor:pointer;",
      },
      "▲",
    );
    upBtn.disabled = idx === 0;
    upBtn.addEventListener("click", function (ev) {
      ev.preventDefault();
      if (idx > 0) {
        const tmp = ordered[idx - 1];
        ordered[idx - 1] = ordered[idx];
        ordered[idx] = tmp;
        syncToUci();
        renderList();
      }
    });

    const downBtn = E(
      "button",
      {
        class: "btn cbi-button",
        type: "button",
        title: _("Move Down"),
        style:
          "padding:2px 8px;font-size:0.8rem;line-height:1.2;cursor:pointer;",
      },
      "▼",
    );
    downBtn.disabled = idx === totalLen - 1;
    downBtn.addEventListener("click", function (ev) {
      ev.preventDefault();
      if (idx < ordered.length - 1) {
        const tmp = ordered[idx + 1];
        ordered[idx + 1] = ordered[idx];
        ordered[idx] = tmp;
        syncToUci();
        renderList();
      }
    });

    row.appendChild(badge);
    row.appendChild(toggleBtn);
    row.appendChild(textCol);
    row.appendChild(upBtn);
    row.appendChild(downBtn);
    return row;
  }

  function renderList() {
    while (listEl.firstChild) listEl.removeChild(listEl.firstChild);
    ordered.forEach(function (id, idx) {
      listEl.appendChild(renderTabRow(id, idx, ordered.length));
    });
  }

  renderList();
  syncToUci();

  wrapper.appendChild(listEl);
  return wrapper;
}

function createComponentsVisibilityWidget(option, section_id) {
  const ALL_COMPONENTS = [
    {
      id: "tachyon",
      label: "Tachyon",
      desc: _tr(
        "Основной сервис оркестрации и веб-интерфейс LuCI",
        "Core orchestration service and LuCI application",
      ),
      defaultVisible: true,
      fixed: true,
    },
    {
      id: "sing_box",
      label: "Sing-box",
      desc: _tr(
        "Универсальная платформа и движок маршрутизации",
        "Universal proxy platform routing engine",
      ),
      defaultVisible: true,
      fixed: true,
    },
    {
      id: "zapret",
      label: "Zapret",
      desc: _tr("Движок обхода DPI (nfqws v1)", "DPI bypass engine (nfqws v1)"),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "zapret2",
      label: "Zapret2",
      desc: _tr(
        "Продвинутый движок обхода DPI со скриптами Lua (nfqws2)",
        "Advanced DPI bypass engine with Lua scripts (nfqws2)",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "byedpi",
      label: "ByeDPI",
      desc: _tr(
        "Локальный десинхронизатор SOCKS (ciadpi)",
        "Local SOCKS proxy desynchronizer (ciadpi)",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "wdtt",
      label: "WDTT",
      desc: _tr("Туннель WireGuard поверх TURN", "WireGuard over TURN Tunnel"),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "olcrtc",
      label: "OlcRTC",
      desc: _tr(
        "Антицензурный WebRTC-туннель реального времени",
        "Real-time WebRTC anti-censorship tunnel",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "fptn",
      label: "FPTN",
      desc: _tr(
        "Клиент быстрого протокола FPTN",
        "Fast packet transport network client",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "tailscale",
      label: "Tailscale",
      desc: _tr(
        "Mesh VPN демон с автоматической настройкой",
        "Zero config mesh VPN daemon",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "direct_bypass",
      label: _tr("Direct Proxy", "Direct Proxy"),
      desc: _tr(
        "Выделенный прямой прокси HTTP/SOCKS5",
        "Dedicated direct HTTP/SOCKS5 outbound proxy",
      ),
      defaultVisible: true,
      fixed: false,
    },
    {
      id: "torrserver_direct",
      label: _tr("TorrServer Direct", "TorrServer Direct"),
      desc: _tr(
        "Прямой обход cgroup для TorrServer",
        "Direct cgroup bypass for TorrServer",
      ),
      defaultVisible: true,
      fixed: false,
    },
  ];

  const visibility = {};
  ALL_COMPONENTS.forEach(function (c) {
    if (c.fixed) {
      visibility[c.id] = true;
    } else {
      const optKey = "show_component_" + c.id;
      const val = uci.get(UCI_PACKAGE, section_id, optKey);
      if (val === undefined || val === null || val === "") {
        visibility[c.id] = c.defaultVisible;
      } else {
        visibility[c.id] = val === "1" || val === true;
      }
    }
  });

  const wrapper = E("div", {
    id: "components-visibility-widget-" + section_id,
  });
  const listEl = E("div", {
    style:
      "border:1px solid var(--border-color,#dee2e6);border-radius:6px;overflow:hidden;margin-bottom:8px;max-width:560px;background:var(--card-bg,transparent);",
  });

  function syncToUci() {
    wrapper._vis = Object.assign({}, visibility);
    ALL_COMPONENTS.forEach(function (c) {
      if (!c.fixed) {
        const optKey = "show_component_" + c.id;
        const next = visibility[c.id] ? "1" : "0";
        // Same reasoning as the tab-order widget: an unset option reads as
        // undefined, which is not "0", so it still has to be written once.
        const prev = uci.get(UCI_PACKAGE, section_id, optKey);
        if (prev !== next) {
          uci.set(UCI_PACKAGE, section_id, optKey, next);
        }
      }
    });
  }
  wrapper._syncToUci = syncToUci;

  function renderList() {
    listEl.innerHTML = "";
    ALL_COMPONENTS.forEach(function (c, idx) {
      const isVisible = Boolean(visibility[c.id]);
      const isFixed = Boolean(c.fixed);

      const row = E("div", {
        style: [
          "display:flex;align-items:center;gap:12px;padding:8px 12px;",
          idx < ALL_COMPONENTS.length - 1
            ? "border-bottom:1px solid var(--border-color,#dee2e6);"
            : "",
          isVisible ? "" : "opacity:0.5;background:rgba(0,0,0,0.02);",
        ].join(""),
      });

      const toggleBtn = E("button", {
        type: "button",
        title: isFixed
          ? _("Always visible")
          : isVisible
            ? _("Click to hide")
            : _("Click to show"),
        style: [
          "width:20px;height:20px;padding:0;border-radius:3px;border:2px solid;",
          "display:flex;align-items:center;justify-content:center;",
          "font-size:13px;font-weight:bold;line-height:1;cursor:",
          isFixed ? "default;" : "pointer;",
          "flex-shrink:0;",
          isFixed || isVisible
            ? "border-color:var(--primary-color,#2196f3);background:var(--primary-color,#2196f3);color:#fff;"
            : "border-color:var(--border-color,#aaa);background:transparent;color:transparent;",
        ].join(""),
      });
      toggleBtn.textContent = "✓";
      if (isFixed) toggleBtn.disabled = true;

      if (!isFixed) {
        toggleBtn.addEventListener("click", function (ev) {
          ev.preventDefault();
          visibility[c.id] = !visibility[c.id];
          syncToUci();
          renderList();
        });
      }

      const textWrap = E(
        "div",
        { style: "flex:1;min-width:0;line-height:1.3;" },
        [
          E(
            "div",
            {
              style: "font-weight:600;font-size:0.875rem;color:inherit;",
            },
            c.label,
          ),
          E(
            "div",
            {
              style: "font-size:0.75rem;opacity:0.75;",
            },
            c.desc,
          ),
        ],
      );

      row.appendChild(toggleBtn);
      row.appendChild(textWrap);
      listEl.appendChild(row);
    });
  }

  renderList();
  syncToUci();

  wrapper.appendChild(listEl);
  return wrapper;
}

function createSettingsContent(section, capabilities) {
  section.tab("navigation", _tr("Меню и навигация", "Menu & Navigation"));
  section.tab("dns", _("DNS Settings"));
  section.tab("network", _("Network & Interfaces"));
  section.tab("services", _("Services & Access"));
  section.tab("updates", _("Updates & Downloads"));
  section.tab("ai", _("AI & Watchdog"));
  section.tab("advanced", _("Advanced System"));

  // ── Navigation & Menu Settings ──────────────────────────────────────────

  let o = section.taboption(
    "navigation",
    form.ListValue,
    "default_tab",
    _tr("Вкладка по умолчанию при входе", "Default Tab on Startup"),
    _tr(
      "Выберите, какая вкладка открывается автоматически при входе в Tachyon.",
      "Select which tab opens automatically when entering Tachyon.",
    ),
  );
  o.value("dashboard", _tr("Дашборд", "Dashboard"));
  o.value("section", _tr("Секции", "Sections"));
  o.value("server", _tr("Серверы", "Servers"));
  o.value("profile", _tr("Семейные профили", "Family Profiles"));
  o.value("schedule", _tr("Родительский контроль", "Parental Control"));
  o.value("monitoring", _tr("Мониторинг", "Monitoring"));
  o.value("diagnostic", _tr("Диагностика", "Diagnostics"));
  o.value("updates", _tr("Компоненты", "Components"));
  o.value("settings", _tr("Настройки", "Settings"));
  o.value("telegram", _tr("Телеграм-бот", "Telegram Bot"));
  o.default = "dashboard";
  o.rmempty = false;

  const tabsOrderOpt = section.taboption(
    "navigation",
    form.Value,
    "_tabs_order_widget",
    _tr("Порядок и видимость вкладок меню", "Tab Order & Visibility"),
    _tr(
      "Настройте порядок и видимость вкладок главного меню. Используйте стрелки для перемещения и переключатели для показа/скрытия.",
      "Customize the order and visibility of tabs in the main navigation menu. Use the arrows to reorder and checkboxes to show or hide tabs.",
    ),
  );
  tabsOrderOpt.renderWidget = function (section_id) {
    return createMenuTabsOrderWidget(this, section_id);
  };
  tabsOrderOpt.formvalue = function (section_id) {
    const el = document.getElementById("menu-tabs-order-widget-" + section_id);
    // Return serialized state so LuCI knows something changed
    return el ? JSON.stringify({ order: el._order, vis: el._vis }) : "";
  };
  tabsOrderOpt.write = function (_section_id) {
    // UCI is written directly by syncToUci() inside the widget on every interaction.
    // Nothing extra to do here.
  };
  tabsOrderOpt.remove = function () {};

  const compVisOpt = section.taboption(
    "navigation",
    form.Value,
    "_components_visibility_widget",
    _tr("Видимость карточек компонентов", "Component Cards Visibility"),
    _tr(
      "Настройте, какие карточки компонентов отображаются во вкладке «Компоненты».",
      "Customize which component cards are displayed in the Components tab. Checkboxes show or hide components.",
    ),
  );
  compVisOpt.renderWidget = function (section_id) {
    return createComponentsVisibilityWidget(this, section_id);
  };
  compVisOpt.formvalue = function (section_id) {
    const el = document.getElementById(
      "components-visibility-widget-" + section_id,
    );
    return el ? JSON.stringify(el._vis) : "";
  };
  compVisOpt.write = function (section_id) {
    const el = document.getElementById(
      "components-visibility-widget-" + section_id,
    );
    if (el && typeof el._syncToUci === "function") {
      el._syncToUci();
    }
  };
  compVisOpt.remove = function () {};

  // ── Dashboard Outbound Display & Navigation ──────────────────────────────

  o = section.taboption(
    "navigation",
    form.ListValue,
    "dashboard_country_grouping",
    _tr("Группировка серверов по странам", "Server Grouping by Country"),
    _tr(
      "Выберите способ группировки и навигации по серверам на дашборде.",
      "Choose how servers are grouped and navigated on the Dashboard.",
    ),
  );
  o.value(
    "chips",
    _tr("Кнопки фильтра по странам (Чипсы)", "Country filter buttons (Chips)"),
  );
  o.value(
    "accordion",
    _tr("Группы по странам (Аккордеоны)", "Country groups (Accordions)"),
  );
  o.value("none", _tr("Отключено (Общий список)", "Disabled (Flat list)"));
  o.default = "chips";
  o.rmempty = false;

  o = section.taboption(
    "navigation",
    form.ListValue,
    "dashboard_chips_grouping",
    _tr("Организация чипсов стран", "Country Chips Grouping"),
    _tr(
      "Выберите порядок и способ отображения чипсов стран на дашборде.",
      "Select how country chips are organized and displayed on the Dashboard.",
    ),
  );
  o.value(
    "regions",
    _tr(
      "По частям света (Регионы: Европа, Азия, Америка...)",
      "By world regions (Europe, Asia, Americas...)",
    ),
  );
  o.value(
    "smart_top",
    _tr(
      "Умный топ (Активная и популярные страны впереди)",
      "Smart top (Active and popular countries first)",
    ),
  );
  o.value(
    "latency",
    _tr("По качеству связи (Пинг первыми)", "By latency (Best ping first)"),
  );
  o.value("alphabetical", _tr("По алфавиту (А–Я)", "Alphabetical (A–Z)"));
  o.default = "regions";
  o.depends("dashboard_country_grouping", "chips");
  o.rmempty = false;

  o = section.taboption(
    "navigation",
    form.ListValue,
    "dashboard_country_chips_latency_mode",
    _tr("Отображение пинга на чипсах стран", "Country Chips Ping Display"),
    _tr(
      "Выберите, какой пинг отображать на кнопках-чипсах стран при наличии нескольких серверов.",
      "Choose which ping to display on country chip buttons when multiple servers exist in a country.",
    ),
  );
  o.value(
    "min",
    _tr("Минимальный пинг (По умолчанию)", "Minimum ping (Default)"),
  );
  o.value("max", _tr("Максимальный пинг", "Maximum ping"));
  o.default = "min";
  o.depends("dashboard_country_grouping", "chips");
  o.rmempty = false;

  o = section.taboption(
    "navigation",
    form.ListValue,
    "dashboard_sort_mode",
    _tr("Сортировка серверов на дашборде", "Dashboard Server Sorting"),
    _tr(
      "Выберите порядок сортировки серверов на дашборде.",
      "Select the server sorting order on the Dashboard.",
    ),
  );
  o.value(
    "latency",
    _tr("По задержке (Пинг - По умолчанию)", "By latency (Ping - Default)"),
  );
  o.value(
    "country_latency",
    _tr("По странам, затем по задержке", "By country, then by latency"),
  );
  o.value(
    "country_alpha",
    _tr("По алфавиту (Страна и имя)", "Alphabetical (Country and name)"),
  );
  o.value(
    "default",
    _tr("Исходный порядок из подписки", "Original subscription order"),
  );
  o.default = "latency";
  o.rmempty = false;

  o = section.taboption(
    "navigation",
    form.Flag,
    "dashboard_hover_freeze",
    _tr(
      "Защита от случайных кликов (Hover Freeze)",
      "Prevent Misclicks (Hover Freeze)",
    ),
    _tr(
      "Временно фиксирует позиции карточек серверов, пока курсор мыши находится над списком, предотвращая случайные клики при обновлении пинга.",
      "Temporarily lock server card positions while the mouse cursor is over the server grid to prevent misclicks when latencies update.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.taboption(
    "navigation",
    form.Flag,
    "dashboard_show_subscription_metadata",
    _tr(
      "Показывать информацию о подписках на дашборде",
      "Show Subscription Info on Dashboard",
    ),
    _tr(
      "Отображать шапки с информацией о трафике, сроке действия и объявлениями подписок над списками серверов на дашборде.",
      "Display subscription info headers (traffic usage, expiration date, announcements) above server lists on the Dashboard.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  // ── DNS Settings ────────────────────────────────────────────────────────

  const dnsBenchmarkBtn = section.taboption(
    "dns",
    form.Button,
    "_dns_benchmark_btn",
    _("DNS Auto-Tuner & Benchmark"),
    _(
      "Automatically benchmark latency, packet loss, and anti-censorship reliability of major DNS servers (UDP/DoH) from this router to find and apply the optimal configuration.",
    ),
  );
  dnsBenchmarkBtn.inputtitle = _("Auto-Tune & Benchmark DNS");
  dnsBenchmarkBtn.inputstyle = "action important";
  dnsBenchmarkBtn.onclick = function () {
    if (main && typeof main.renderDnsBenchmarkModal === "function") {
      main.renderDnsBenchmarkModal();
    }
  };

  settingsDnsDynamicState.dnsType =
    uci.get(UCI_PACKAGE, "settings", "dns_type") || "udp";

  const dnsSpeedController = dns_speed_test.createController();
  const dnsSpeedOption = section.taboption(
    "dns",
    form.DummyValue,
    "_dns_speed_test",
    _("DNS speed test"),
    _(
      "Test the selected Main, Bootstrap, and Fallback DNS servers from this router without changing settings. Click a ping for details.",
    ),
  );
  dnsSpeedOption.renderWidget = function (section_id) {
    return dnsSpeedController.renderToolbar(() => {
      const protocol =
        dnsTypeOption.formvalue(section_id) ||
        settingsDnsDynamicState.dnsType ||
        "udp";
      const mainServers =
        protocol === "doh" || protocol === "udp"
          ? optionListValues(dnsOption, section_id)
          : [];
      const udpServers = [
        ...optionListValues(bootstrapOption, section_id),
        ...optionListValues(fallbackDnsOption, section_id),
      ];
      return {
        protocol,
        servers: mainServers,
        udp_servers: udpServers,
      };
    });
  };
  dnsSpeedOption.write = function () {};
  dnsSpeedOption.remove = function () {};

  o = section.taboption(
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

  o = section.taboption(
    "dns",
    form.ListValue,
    "dns_upstream_mode",
    _("Upstream Mode"),
    _(
      "Sequential: failover to the next server after N failures. Parallel: aggressive failover — switches in seconds (1 failure = switch), best if your ISP blocks DoH/DoT.",
    ),
  );
  o.value("sequential", _("Sequential (one active at a time)"));
  o.value("parallel", _("Parallel (fast failover, ≤3 s)"));
  o.default = "sequential";
  o.rmempty = false;

  const dnsModeOption = o;

  const dnsOption = section.taboption(
    "dns",
    form.DynamicList,
    "dns_server",
    _("DNS Servers"),
    _(
      "Main DNS server. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  dnsOption.speedTestController = dnsSpeedController;
  configureDnsDynamicList(
    dnsOption,
    (_section_id) => {
      const dnsType = settingsDnsDynamicState.dnsType || "udp";
      return getDnsServerChoices(dnsType);
    },
    "77.88.8.8",
  );

  const bootstrapOption = section.taboption(
    "dns",
    form.DynamicList,
    "bootstrap_dns_server",
    _("Bootstrap DNS Servers"),
    _(
      "DNS server used to obtain IP addresses for upstream DNS and proxies. If multiple servers are selected, a timeout switches to a backup.",
    ),
  );
  bootstrapOption.speedTestController = dnsSpeedController;
  configureDnsList(
    bootstrapOption,
    main.BOOTSTRAP_DNS_SERVER_OPTIONS,
    "77.88.8.8",
  );

  const fallbackDnsOption = section.taboption(
    "dns",
    form.DynamicList,
    "dns_fallback_server",
    _("Fallback DNS Servers"),
    _(
      "Plain-UDP DNS servers used as a last resort when all primary DNS fail. These are always unencrypted (no DoH/DoT). Example: 1.1.1.1, 8.8.8.8. Unlike the ISP fallback toggle, these are your own chosen servers.",
    ),
  );
  fallbackDnsOption.speedTestController = dnsSpeedController;
  configureDnsList(fallbackDnsOption, main.BOOTSTRAP_DNS_SERVER_OPTIONS, "");
  fallbackDnsOption.rmempty = true;
  fallbackDnsOption.default = [];
  fallbackDnsOption.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) return true; // allow empty list
    // Fallback servers are plain-UDP only — reject DoH/DoT/DoQ URLs and
    // path-style DoH (e.g. "cloudflare-dns.com/dns-query"). This mirrors
    // the backend validator.uc check so the user gets immediate feedback.
    if (normalized.includes("://"))
      return _(
        "Fallback DNS servers must be plain UDP (IP or hostname). DoH/DoT URLs are not allowed here.",
      );
    if (normalized.includes("/"))
      return _(
        "Fallback DNS servers must be plain UDP (IP or hostname). Path-style DoH (e.g. domain/path) is not allowed here.",
      );
    const validation = main.validateDNS(normalized);
    return validation.valid ? true : validation.message;
  };

  dnsTypeOption.onchange = function (_ev, section_id, value) {
    const newType = value || "udp";
    if (newType === settingsDnsDynamicState.dnsType) return;
    settingsDnsDynamicState.dnsType = newType;
    dnsSpeedController.refresh();

    const widget = settingsDnsDynamicState.widget;
    if (widget) {
      const servers =
        main.DNS_SERVERS_BY_PROTOCOL[newType] ||
        main.DNS_SERVERS_BY_PROTOCOL.udp;
      const defaultLabels = {};
      Object.entries(servers).forEach(([v, l]) => {
        defaultLabels[v] = _(l);
      });
      const defaultServers = getDefaultDnsServers(newType);
      widget.choices = defaultLabels;
      widget.setValue(defaultServers);
    }

    const refreshers = settingsDnsDynamicState.refreshers.get(section_id);
    if (refreshers) {
      refreshers.forEach((fn) => {
        if (fn() === false) {
          refreshers.delete(fn);
        }
      });
      if (refreshers.size === 0) {
        settingsDnsDynamicState.refreshers.delete(section_id);
      }
    }
  };

  o = section.taboption(
    "dns",
    form.Flag,
    "fallback_wan_main",
    _("Enable WAN DNS Fallback for Main DNS"),
    _(
      "⚠️ If all Main DNS fail 3 times, queries will be sent to your ISP's DNS in plaintext. Only use as a last resort to prevent complete internet loss.",
    ),
  );
  o.default = o.disabled;

  o = section.taboption(
    "dns",
    form.Flag,
    "fallback_wan_bootstrap",
    _("Enable WAN DNS Fallback for Bootstrap DNS"),
    _(
      "⚠️ If all Bootstrap DNS fail 3 times, queries will be sent to your ISP's DNS in plaintext. Only use as a last resort to prevent complete internet loss.",
    ),
  );
  o.default = o.disabled;

  // Timing controls — hidden in parallel mode (auto-configured) and when only one server
  function configureTimingVisibility(opt) {
    opt.retain = true;
    opt.checkDepends = function (section_id) {
      // hide when parallel (auto-tuned) unless there are multiple servers
      const mode =
        uci.get(UCI_PACKAGE, "settings", "dns_upstream_mode") || "sequential";
      if (mode === "parallel") return false;
      return (
        optionListValues(dnsOption, section_id).length > 1 ||
        optionListValues(bootstrapOption, section_id).length > 1 ||
        optionListValues(fallbackDnsOption, section_id).length > 0
      );
    };
  }

  o = section.taboption(
    "dns",
    form.Value,
    "dns_check_interval",
    _("DNS Check Interval"),
    _("How often to check the active DNS servers."),
  );
  configureDnsDuration(o, "10s", dnsOption, bootstrapOption, fallbackDnsOption);
  configureTimingVisibility(o);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_recovery_check_interval",
    _("Higher-priority DNS Check"),
    _("How often to check whether a higher-priority DNS server has recovered."),
  );
  configureDnsDuration(o, "60s", dnsOption, bootstrapOption, fallbackDnsOption);
  configureTimingVisibility(o);

  o = section.taboption(
    "dns",
    form.Value,
    "dns_check_timeout",
    _("DNS Unavailability Timeout"),
    _(
      "Maximum time to wait for example.com to resolve during a DNS health check.",
    ),
  );
  configureDnsDuration(o, "2s", dnsOption, bootstrapOption, fallbackDnsOption);
  configureTimingVisibility(o);

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
  configureDnsFailoverVisibility(
    o,
    dnsOption,
    bootstrapOption,
    fallbackDnsOption,
  );
  configureTimingVisibility(o);

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
  configureDnsFailoverVisibility(
    o,
    dnsOption,
    bootstrapOption,
    fallbackDnsOption,
  );
  configureTimingVisibility(o);

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

  o = section.taboption(
    "dns",
    form.Flag,
    "dns_local_cache",
    _("Local DNS Cache"),
    _(
      "Enables high-capacity local DNS caching in dnsmasq to accelerate DNS queries and absorb transient latency during service restarts.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "dns",
    form.Value,
    "dns_cache_size",
    _("DNS Cache Size (entries)"),
    _(
      "Maximum number of cached domain entries in dnsmasq (default: 10000 ≈ 1.2 MB RAM). Memory is allocated dynamically per request (~120 B per domain), not pre-allocated upfront. Recommended: 10000 for routers with ≥128 MB RAM, 2500–5000 for 64 MB devices.",
    ),
  );
  o.depends("dns_local_cache", "1");
  o.default = "10000";
  o.datatype = "uinteger";
  o.placeholder = "10000";
  o.rmempty = true;

  const originalDnsCacheRenderWidget = o.renderWidget;
  o.renderWidget = function (section_id, option_index, cfgvalue) {
    const node = originalDnsCacheRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
    const input =
      node && typeof node.querySelector === "function"
        ? node.querySelector("input")
        : node;

    const calcNode = document.createElement("div");
    calcNode.className = "cbi-value-description";
    calcNode.style.marginTop = "4px";
    calcNode.style.fontSize = "12px";

    const updateCalc = () => {
      const rawVal =
        input && input.value !== undefined && input.value !== ""
          ? input.value
          : cfgvalue || 10000;
      const val = parseInt(rawVal, 10);
      if (isNaN(val) || val <= 0) {
        calcNode.textContent = _("Local DNS caching disabled (0 entries)");
        return;
      }
      const bytes = val * 120;
      const sizeText =
        bytes < 1024 * 1024
          ? (bytes / 1024).toFixed(0) + " KB"
          : (bytes / (1024 * 1024)).toFixed(1) + " MB";

      calcNode.innerHTML =
        _("Estimated RAM usage (max):") +
        " <strong>~" +
        sizeText +
        "</strong> " +
        "<span style='opacity: 0.8;'>(" +
        _("allocated dynamically on demand, not upfront") +
        ")</span>";
    };

    if (input && typeof input.addEventListener === "function") {
      input.addEventListener("input", updateCalc);
      input.addEventListener("change", updateCalc);
    }
    updateCalc();

    if (node && typeof node.appendChild === "function") {
      node.appendChild(calcNode);
    }
    return node;
  };

  // ─── DNS Strategy ────────────────────────────────────────────────────────

  o = section.taboption(
    "dns",
    form.ListValue,
    "dns_strategy",
    _("DNS Strategy"),
  );
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
    form.ListValue,
    "routing_strategy",
    _tr("Глобальная стратегия маршрутизации", "Global Routing Strategy"),
    _tr(
      "Выберите общую модель маршрутизации: выборочный обход (по спискам секций) или «Всё в туннель» (весь трафик через прокси, кроме исключений).",
      "Choose overall routing model: Selective split routing (only domains/subnets from sections go to proxy) or Full tunnel (all traffic routes through proxy, sections define exceptions and bypasses).",
    ),
  );
  o.value(
    "split",
    _tr(
      "Выборочная маршрутизация (по умолчанию)",
      "Selective Split Routing (Default)",
    ),
  );
  o.value(
    "full_tunnel",
    _tr(
      "Всё в туннель, кроме исключений",
      "Full Tunnel (All traffic via proxy, exceptions direct)",
    ),
  );
  o.default = "split";
  o.rmempty = false;

  o = section.taboption(
    "network",
    form.ListValue,
    "default_tunnel_section",
    _tr("Основная секция для туннеля", "Default Tunnel Section"),
    _tr(
      "Секция (прокси, VPN или группа), через которую будет направляться весь остальной трафик в режиме «Всё в туннель».",
      "Section (proxy, VPN, or group) through which all remaining traffic will be routed in Full Tunnel mode.",
    ),
  );
  o.depends("routing_strategy", "full_tunnel");
  configureDefaultTunnelSectionOption(
    o,
    "default_tunnel_section",
    capabilities,
  );

  o = section.taboption(
    "network",
    form.ListValue,
    "proxy_mode",
    _tr("Режим перехвата трафика", "Traffic Interception Mode"),
    _tr(
      "TProxy: ядро Tachyon перехватывает трафик через nftables (по умолчанию). TUN: ядро само владеет маршрутами через tun-интерфейс, nftables не перехватывает. SOCKS: прокси доступен только по SOCKS/HTTP на порту Tachyon.",
      "TProxy: the Tachyon core intercepts traffic through nftables (default). TUN: the core owns the routes itself through a tun interface, nftables does not intercept. SOCKS: the proxy is only reachable over SOCKS/HTTP on the Tachyon port.",
    ),
  );
  o.value(
    "tproxy",
    _tr("TProxy + nftables (по умолчанию)", "TProxy + nftables (Default)"),
  );
  o.value(
    "tun",
    _tr("TUN (ядро владеет маршрутами)", "TUN (the core owns the routes)"),
  );
  o.value(
    "socks",
    _tr(
      "SOCKS/HTTP только (без перехвата)",
      "SOCKS/HTTP only (no interception)",
    ),
  );
  o.default = "tproxy";
  o.rmempty = false;

  o = section.taboption(
    "network",
    form.Value,
    "tun_interface",
    _tr("Имя TUN-интерфейса", "TUN Interface Name"),
    _tr(
      "Имя tun-интерфейса, который создаёт ядро в режиме TUN.",
      "The name of the tun interface the core creates in TUN mode.",
    ),
  );
  o.depends("proxy_mode", "tun");
  o.default = "tun0";
  o.rmempty = false;

  o = section.taboption(
    "network",
    form.ListValue,
    "tun_stack",
    _tr("Сетевой стек TUN", "TUN Network Stack"),
    _tr(
      "Стек пользовательского пространства в tun-интерфейсе: mixed (быстрее), system (системный стек ядра), gvisor.",
      "The user-space stack behind the tun interface: mixed (faster), system (the kernel stack), gvisor.",
    ),
  );
  o.value("mixed", _tr("Mixed (по умолчанию)", "Mixed (Default)"));
  o.value("system", _tr("System", "System"));
  o.value("gvisor", _tr("gVisor", "gVisor"));
  o.depends("proxy_mode", "tun");
  o.default = "mixed";
  o.rmempty = false;

  o = section.taboption(
    "network",
    form.Flag,
    "tun_auto_route",
    _tr(
      "Ядро само ставит маршрут по умолчанию",
      "The core installs the default route itself",
    ),
    _tr(
      "Ядро переносит маршрут по умолчанию в таблицу 2022 и не трогает main. Выключите, если маршруты управляются вручную.",
      "The core moves the default route into table 2022 and leaves main alone. Turn this off when the routes are managed by hand.",
    ),
  );
  o.depends("proxy_mode", "tun");
  o.default = "1";

  o = section.taboption(
    "network",
    form.Value,
    "tun_mtu",
    _tr("MTU TUN-интерфейса", "TUN Interface MTU"),
    _tr(
      "MTU tun-интерфейса. Слишком большое значение ломает передачу пакетов, слишком маленькое снижает скорость.",
      "The MTU of the tun interface. Too large a value breaks packet delivery, too small a value costs throughput.",
    ),
  );
  o.depends("proxy_mode", "tun");
  o.default = "9000";
  o.rmempty = false;

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
  o.default = "wan";
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
    "network",
    form.Flag,
    "route_router_traffic",
    _("Route Router's Own Traffic"),
    _(
      "Route local traffic originating directly from the router (e.g. wget, curl, opkg, torrent clients on the router) through Tachyon.",
    ),
  );
  configureDownloadViaProxyFlag(o, "route_router_traffic_section");

  o = section.taboption(
    "network",
    form.ListValue,
    "route_router_traffic_section",
    _("Router Traffic Target Section"),
    _("Select the section to route router's own traffic through."),
  );
  o.depends("route_router_traffic", "1");
  configureDownloadSectionOption(
    o,
    "route_router_traffic_section",
    capabilities,
  );

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
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (
      this.section.formvalue(section_id, "enable_yacd_wan_access") === "1" &&
      (!value || !`${value}`.trim())
    ) {
      return _("Secret key is required when WAN access is enabled");
    }
    return true;
  };

  o = section.taboption(
    "services",
    form.ListValue,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming. Tunneled rejects QUIC for proxied traffic; All rejects every UDP/443 outright.",
    ),
  );
  o.value("off", _("No"));
  o.value("tunneled", _("Only for proxy"));
  o.value("all", _("Yes (all traffic)"));
  o.default = "off";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    const value = uci.get(UCI_PACKAGE, section_id, "disable_quic");
    // legacy flag values keep their meaning across the mode split
    if (value === "1" || value === "true" || value === "yes" || value === "on")
      return "tunneled";
    return value === "all" ? "all" : "off";
  };

  o = section.taboption(
    "services",
    form.Flag,
    "block_doh",
    _("Block DoH"),
    _(
      "Block well-known DNS-over-HTTPS resolver IPs so LAN clients cannot bypass the router DNS",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.Flag,
    "wifi_calling_direct",
    _("Wi-Fi Calling Direct (VoWiFi)"),
    _(
      "Route IPsec IKEv2 / ESP-in-UDP (UDP 500, 4500) directly via WAN so mobile Wi-Fi Calling works reliably without VPN interference",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "services",
    form.ListValue,
    "bittorrent_policy",
    _("BitTorrent / P2P Policy"),
    _(
      "Control how BitTorrent and P2P traffic is handled: allow normal routing, force direct via WAN to prevent VPN bans, or block completely.",
    ),
  );
  o.value("off", _("Off (Allow)"));
  o.value("direct", _("Direct (Bypass Proxy / Leak Protection)"));
  o.value("block", _("Block BitTorrent Traffic"));
  o.default = "off";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    const val = uci.get(UCI_PACKAGE, section_id, "bittorrent_policy");
    if (val === "direct" || val === "block" || val === "off") return val;
    const legacy = uci.get(UCI_PACKAGE, section_id, "isolate_p2p");
    return legacy === "1" ? "direct" : "off";
  };
  o.write = function (section_id, value) {
    uci.set(UCI_PACKAGE, section_id, "bittorrent_policy", value);
    uci.set(
      UCI_PACKAGE,
      section_id,
      "isolate_p2p",
      value === "direct" ? "1" : "0",
    );
  };

  o = section.taboption(
    "services",
    form.Value,
    "p2p_ports",
    _("P2P Client Ports"),
    _(
      'Pin P2P policy to the torrent client\'s own ports, comma separated. Each entry is "proto", "proto:port" or "proto:port-port" (tcp/udp). Without a port the whole protocol is matched.',
    ),
  );
  o.depends("bittorrent_policy", "direct");
  o.depends("bittorrent_policy", "block");
  o.placeholder = "tcp:6881,udp:6881-6889";
  o.validate = function (_section_id, value) {
    if (!value || !value.trim()) {
      return true;
    }

    const entries = value.split(",");
    for (const entry of entries) {
      const trimmed = entry.trim();
      if (
        !/^((tcp|udp):)?[0-9]{1,5}(-[0-9]{1,5})?$|^(tcp|udp)$/.test(trimmed)
      ) {
        return _(
          'Each entry must be "proto", "proto:port" or "proto:port-port" (tcp/udp), e.g. tcp:6881,udp:6881-6889',
        );
      }

      const portSpec = trimmed.includes(":")
        ? trimmed.split(":")[1]
        : /^[0-9]/.test(trimmed)
          ? trimmed
          : null;
      if (!portSpec) {
        continue;
      }

      const bounds = portSpec.split("-").map(Number);
      if (
        bounds.some(
          (port) => !Number.isInteger(port) || port < 1 || port > 65535,
        )
      ) {
        return _("Ports must be between 1 and 65535");
      }

      if (bounds.length === 2 && bounds[0] > bounds[1]) {
        return _("Port range start must not exceed its end");
      }
    }

    return true;
  };

  o = section.taboption(
    "services",
    form.Flag,
    "game_console_optimizer",
    _("Game Console Optimizer (NAT Type 1)"),
    _(
      "Bypasses UDP traffic for selected game consoles (PS5/Xbox) to achieve NAT Type 1 / 2 (Full Cone NAT) for P2P matchmaking, while keeping TCP (PSN/Auth) routed through the proxy.",
    ),
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
  gameConsoleIpsOpt.renderWidget = function (
    section_id,
    option_index,
    cfgvalue,
  ) {
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

  // ── GitHub API token (issue #226) ─────────────────────────────────────────
  // GitHub counts the unauthenticated API budget per IP. Everyone behind the
  // same exit node (WARP, CGNAT) shares 60 requests/hour; a personal access
  // token lifts that to 5000 per account without any other change.
  o = section.taboption(
    "updates",
    form.Value,
    "github_token",
    _("GitHub API Token (optional)"),
    _(
      "Personal access token to avoid the 60 req/hour per-IP GitHub API limit during update checks. Leave empty if update checks work fine.",
    ),
  );
  o.password = true;
  o.rmempty = true;
  o.validate = function (section_id, value) {
    const v = (value || "").trim();
    if (
      v !== "" &&
      !/^(?:gh[pousr]_[A-Za-z0-9_]{36,255}|github_pat_[A-Za-z0-9_]{22,255}|[A-Fa-f0-9]{40})$/.test(
        v,
      )
    )
      return _(
        "Does not look like a GitHub token (expected ghp_… / github_pat_… or a 40-hex classic token)",
      );
    return true;
  };
  disablePasswordAutofill(o);

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

  const updateListsBtn = section.taboption(
    "updates",
    form.Button,
    "_update_lists_now",
    _("Manual list update"),
    _("Force immediate download and refresh of all remote lists and rule sets"),
  );
  updateListsBtn.inputtitle = _("Update lists now");
  updateListsBtn.inputstyle = "action";
  updateListsBtn.depends("list_update_enabled", "1");
  updateListsBtn.onclick = function () {
    const steps = [
      { key: "starting", label: _("Preparing") },
      { key: "downloading", label: _("Downloading lists") },
      { key: "applying", label: _("Applying rules") },
    ];

    function renderStepIcon(state) {
      if (state === "done")
        return E(
          "span",
          {
            style:
              "color: var(--color-green-base, #2ecc71); font-weight: bold;",
          },
          "\u2713",
        );
      if (state === "error")
        return E(
          "span",
          {
            style: "color: var(--color-red-base, #e74c3c); font-weight: bold;",
          },
          "\u2717",
        );
      if (state === "active")
        return E(
          "span",
          {
            class: "spinning",
            style: "color: var(--color-blue-base, #3498db);",
          },
          "\u25CB",
        );
      return E(
        "span",
        { style: "color: var(--text-color-medium, #999);" },
        "\u25CB",
      );
    }

    const stepsContainer = E("div", {
      style: "display: flex; flex-direction: column; gap: 8px; margin: 12px 0;",
    });
    const stepEls = steps.map((step) => {
      const row = E(
        "div",
        {
          style:
            "display: flex; align-items: center; gap: 8px; padding: 4px 0; transition: opacity 0.3s;",
        },
        [
          renderStepIcon("pending"),
          E(
            "span",
            {
              style: "font-size: 13px; color: var(--text-color-medium, #666);",
            },
            step.label,
          ),
        ],
      );
      stepsContainer.appendChild(row);
      return {
        el: row,
        iconEl: row.childNodes[0],
        labelEl: row.childNodes[1],
        key: step.key,
      };
    });

    const detailText = E(
      "p",
      {
        style:
          "margin: 4px 0 0; font-size: 12px; color: var(--text-color-medium, #999); min-height: 18px;",
      },
      _("Starting lists update..."),
    );

    let pollTimer = null;
    let pollAttempts = 0;
    const maxPollAttempts = 120;

    function stopPolling() {
      if (pollTimer) {
        window.clearInterval(pollTimer);
        pollTimer = null;
      }
    }

    function updateSteps(progress) {
      let reached = false;
      for (const s of stepEls) {
        if (s.key === progress) {
          s.iconEl.replaceChildren(renderStepIcon("active"));
          s.labelEl.style.color = "var(--text-color-high, #333)";
          s.labelEl.style.fontWeight = "500";
          reached = true;
        } else if (!reached) {
          s.iconEl.replaceChildren(renderStepIcon("done"));
          s.labelEl.style.color = "var(--text-color-medium, #999)";
          s.labelEl.style.fontWeight = "normal";
        } else {
          s.iconEl.replaceChildren(renderStepIcon("pending"));
          s.labelEl.style.color = "var(--text-color-medium, #999)";
          s.labelEl.style.fontWeight = "normal";
        }
      }
    }

    function markAllDone() {
      for (const s of stepEls) {
        s.iconEl.replaceChildren(renderStepIcon("done"));
        s.labelEl.style.color = "var(--text-color-medium, #999)";
      }
    }

    function markError(failedKey) {
      let found = false;
      for (const s of stepEls) {
        if (s.key === failedKey) {
          s.iconEl.replaceChildren(renderStepIcon("error"));
          s.labelEl.style.color = "var(--color-red-base, #e74c3c)";
          found = true;
        } else if (!found) {
          s.iconEl.replaceChildren(renderStepIcon("done"));
        }
      }
    }

    const closeBtn = E(
      "button",
      {
        class: "btn cbi-button cbi-button-neutral",
        type: "button",
        click: function () {
          stopPolling();
          ui.hideModal();
          ui.addNotification(
            null,
            E("p", _("Lists update is continuing in the background.")),
            "info",
          );
        },
      },
      _("Close"),
    );

    const modalBody = E(
      "div",
      { style: "display: flex; flex-direction: column; gap: 4px;" },
      [stepsContainer, detailText],
    );

    ui.showModal(_("Updating lists..."), [
      modalBody,
      E(
        "div",
        { class: "button-row", style: "margin-top: 16px; text-align: right;" },
        [closeBtn],
      ),
    ]);

    let checkInFlight = false;

    function checkStatus() {
      if (checkInFlight) return;
      if (!modalBody.isConnected) {
        stopPolling();
        return;
      }
      checkInFlight = true;
      pollAttempts++;
      return fs
        .exec("/usr/bin/tachyon", ["list_update_status"])
        .then(function (res) {
          if (!modalBody.isConnected) {
            stopPolling();
            return;
          }
          let data = {};
          try {
            data = JSON.parse((res.stdout || "").trim() || "{}");
          } catch (e) {}

          if (data.running) {
            if (data.progress) {
              updateSteps(data.progress);
            }
            if (data.message) {
              detailText.textContent = _(data.message) || data.message;
            }
            if (pollAttempts >= maxPollAttempts) {
              stopPolling();
              if (modalBody.isConnected) ui.hideModal();
              ui.addNotification(
                null,
                E(
                  "p",
                  _(
                    "Lists update is still running in background. You can check system logs.",
                  ),
                ),
                "info",
              );
            }
          } else {
            stopPolling();
            if (data.success !== false) {
              markAllDone();
              detailText.textContent = _(
                "Lists and rule sets successfully updated!",
              );
              detailText.style.color = "var(--color-green-base, #2ecc71)";
              setTimeout(function () {
                if (modalBody.isConnected) ui.hideModal();
                ui.addNotification(
                  null,
                  E("p", _("Lists and rule sets successfully updated!")),
                  "info",
                );
              }, 1200);
            } else {
              if (data.progress) markError(data.progress);
              detailText.textContent = data.message || _("Update failed");
              detailText.style.color = "var(--color-red-base, #e74c3c)";
              setTimeout(function () {
                if (modalBody.isConnected) ui.hideModal();
                ui.addNotification(
                  null,
                  E(
                    "p",
                    _("Error updating lists:") +
                      " " +
                      (data.message || _("Update failed")),
                  ),
                  "error",
                );
              }, 2000);
            }
          }
        })
        .catch(function () {
          if (pollAttempts >= maxPollAttempts) {
            stopPolling();
            if (modalBody.isConnected) ui.hideModal();
          }
        })
        .finally(function () {
          checkInFlight = false;
        });
    }

    return fs
      .exec("/usr/bin/tachyon", ["list_update_async"])
      .then(function () {
        pollTimer = window.setInterval(checkStatus, 2000);
      })
      .catch(function (err) {
        ui.hideModal();
        ui.addNotification(
          null,
          E("p", _("Error updating lists:") + " " + (err.message || err)),
          "error",
        );
      });
  };

  o = section.taboption(
    "updates",
    form.Flag,
    "download_all_presets",
    _("Pre-download all preset lists"),
    _(
      "Cache all built-in lists, databases, and remote lists configured in sections. Recommended if you have plenty of storage space or USB drive.",
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
    form.Flag,
    "component_auto_update_enabled",
    _("Automatic component updates"),
    _("Automatically download and install new versions of components"),
  );
  o.depends("component_update_check_enabled", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "updates",
    form.ListValue,
    "component_auto_update_mode",
    _("Auto-update mode"),
    _(
      "Choose whether to install updates immediately when detected or at a scheduled time (e.g. maintenance window)",
    ),
  );
  o.depends("component_auto_update_enabled", "1");
  o.value("immediate", _("Immediately upon release"));
  o.value("schedule", _("By schedule"));
  o.default = "immediate";
  o.rmempty = false;

  o = section.taboption(
    "updates",
    form.Value,
    "component_auto_update_time",
    _("Scheduled auto-update time"),
    _(
      "Time of day to run scheduled component updates in HH:MM (24h) format, e.g. 04:00",
    ),
  );
  o.depends({
    component_auto_update_enabled: "1",
    component_auto_update_mode: "schedule",
  });
  o.placeholder = "04:00";
  o.default = "04:00";
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (/^([01]?[0-9]|2[0-3]):[0-5][0-9]$/.test(normalized)) {
      return true;
    }
    return _("Enter a valid time in HH:MM format (00:00 to 23:59)");
  };

  o = section.taboption(
    "updates",
    form.MultiValue,
    "component_auto_update_targets",
    _("Eligible components for auto-update"),
    _("Select which components are permitted to update automatically"),
  );
  o.depends("component_auto_update_enabled", "1");
  o.value("all", _("All components"));
  o.value("tachyon", _("Tachyon Core"));
  o.value("luci_app_tachyon", _("LuCI Web UI"));
  o.value("sing_box", _("sing-box"));
  o.value("zapret", _("Zapret"));
  o.value("zapret2", _("Zapret2"));
  o.value("byedpi", _("ByeDPI"));
  o.value("tailscale", _("Tailscale"));
  o.default = ["all"];
  o.rmempty = false;

  o = section.taboption(
    "updates",
    form.Flag,
    "component_backup_enabled",
    _("Save component backup before update"),
    _(
      "Keep the previous working binary/package on the router flash for instant offline rollback if needed. Consumes extra storage.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

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
    form.Flag,
    "section_failover_enabled",
    _("Auto-failover of proxy sections"),
    _(
      "Watchdog probes every Connection section; when the active one fails several checks in a row, traffic switches to a healthy backup and Telegram is notified. Requires a config reload to take effect.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Value,
    "section_failover_threshold",
    _("Failover failure threshold"),
    _("Number of consecutive failed probes before switching sections"),
  );
  o.depends("section_failover_enabled", "1");
  o.default = "3";
  o.placeholder = "3";
  o.rmempty = false;
  o.datatype = "range(1,30)";

  o = section.taboption(
    "advanced",
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for tachyon-core config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value(
    "/etc/tachyon-core/config.json",
    "Flash (/etc/tachyon-core/config.json)",
  );
  o.value(
    "/tmp/tachyon-core/config.json",
    "RAM (/tmp/tachyon-core/config.json)",
  );
  o.default = "/etc/tachyon-core/config.json";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for tachyon-core cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value(
    "/usr/share/tachyon-core/cache.db",
    "Flash (/usr/share/tachyon-core/cache.db)",
  );
  o.value("/tmp/tachyon-core/cache.db", "RAM (/tmp/tachyon-core/cache.db)");
  o.default = "/usr/share/tachyon-core/cache.db";
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
    _(
      "Detects and drops STUN/TURN packets in nftables to prevent real IP leaks via WebRTC.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.Flag,
    "dns_doq_ech",
    _("Strict ECH + DoQ DNS Enforcer"),
    _(
      "Forces sing-box to tunnel DNS requests via DoQ with Encrypted Client Hello (ECH) for SNI hiding.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.taboption(
    "advanced",
    form.ListValue,
    "qos_priority_engine",
    _("QoS Priority Engine (DSCP)"),
    _(
      "Prioritizes interactive DNS, VoIP/WebRTC and gaming via DSCP marking in nftables. Works cooperatively with OpenWrt SQM (CAKE/FQ_CoDel) without bufferbloat degradation.",
    ),
  );
  o.value("", _("Auto (cooperative with SQM/CAKE)"));
  o.value("1", _("Enabled (always prioritize)"));
  o.value("0", _("Disabled"));
  o.default = "";
  o.rmempty = true;

  // WARP Generator Proxy Section
  o = section.taboption(
    "advanced",
    form.ListValue,
    "warp_proxy_section",
    _("WARP Generator Proxy Section"),
    _(
      "Section used for Cloudflare WARP API registration. If your ISP blocks Cloudflare API on WAN, select a proxy section (with Mixed proxy enabled) or a tunnel interface section (WireGuard / AmneziaWG / VPN). Leave empty to use direct WAN / default mixed proxy.",
    ),
  );
  o.value("", _("Default (Direct WAN / Default mixed proxy)"));
  o.cfgvalue = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "warp_proxy_section") ||
      uci.get(UCI_PACKAGE, "settings", "warp_proxy_section") ||
      ""
    );
  };
  o.load = function (section_id) {
    const sections = this.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};
    this.keylist = [];
    this.vallist = [];
    this.value("", _("Default (Direct WAN / Default mixed proxy)"));
    for (const secName in sections) {
      const sec = sections[secName];
      if (sec[".type"] === "section" && sec.enabled !== "0") {
        const action = sec.action || "section";
        const iface = sec.section_interface || sec.interface || "";
        const desc = iface ? ` (${action}: ${iface})` : ` (${action})`;
        this.value(secName, `${_("Section")}: ${sec.label || secName}${desc}`);
      }
    }

    const currentVal = this.cfgvalue(section_id);
    if (currentVal && !this.keylist.includes(currentVal)) {
      this.value(currentVal, `${_("Interface")}: ${currentVal}`);
    }

    if (
      typeof network !== "undefined" &&
      typeof network.getDevices === "function"
    ) {
      network
        .getDevices()
        .then(
          L.bind(function (devices) {
            (devices || []).forEach((dev) => {
              const name =
                typeof dev.getName === "function" ? dev.getName() : dev.name;
              if (name && name !== "lo" && !this.keylist.includes(name)) {
                const type =
                  typeof dev.getTypeI18n === "function"
                    ? dev.getTypeI18n()
                    : typeof dev.getType === "function"
                      ? dev.getType()
                      : "";
                const desc = type ? ` (${type})` : "";
                this.value(name, `${_("Interface")}: ${name}${desc}`);
              }
            });
          }, this),
        )
        .catch(() => null);
    }

    return currentVal;
  };
  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";
    if (normalized) {
      uci.set(UCI_PACKAGE, section_id, "warp_proxy_section", normalized);
      if (section_id !== "settings" && uci.get(UCI_PACKAGE, "settings")) {
        uci.set(UCI_PACKAGE, "settings", "warp_proxy_section", normalized);
      }
    } else {
      uci.unset(UCI_PACKAGE, section_id, "warp_proxy_section");
      if (section_id !== "settings" && uci.get(UCI_PACKAGE, "settings")) {
        uci.unset(UCI_PACKAGE, "settings", "warp_proxy_section");
      }
    }
  };
  o.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "warp_proxy_section");
    if (section_id !== "settings" && uci.get(UCI_PACKAGE, "settings")) {
      uci.unset(UCI_PACKAGE, "settings", "warp_proxy_section");
    }
  };

  const resetOpt = section.taboption(
    "advanced",
    form.DummyValue,
    "_reset_settings",
    _("Reset Settings"),
    _(
      "Restores the Tachyon factory defaults: all rules, subscriptions, custom DNS servers and other options will be lost.",
    ),
  );
  resetOpt.rawhtml = true;
  resetOpt.cfgvalue = function () {
    return createResetSettingsWidget();
  };

  const snapshotsOpt = section.taboption(
    "advanced",
    form.DummyValue,
    "_snapshots",
    _("Config Snapshots"),
    _(
      "Save a snapshot of the working config and restore it later if something breaks.",
    ),
  );
  snapshotsOpt.rawhtml = true;
  snapshotsOpt.cfgvalue = function () {
    return createSnapshotsWidget();
  };

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
  disablePasswordAutofill(o);

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
  o.value("openrouter", "OpenRouter (openrouter.ai)");
  o.value("gemini", _("Google Gemini API (gemini-2.5-flash / pro)"));
  o.value("ollama", _("Ollama (Local PC / Server)"));
  o.value("lmstudio", _("LM Studio (Local PC / Server)"));
  o.value("custom", _("Custom OpenAI-Compatible API"));
  o.default = "openai";

  o = section.taboption(
    "ai",
    form.Value,
    "ai_doctor_model",
    _("AI Model"),
    _(
      "Model name to use. Leave empty to auto-detect or use provider default (gpt-4o-mini / claude-haiku-4-5 / deepseek-chat / gemini-2.5-flash / llama3.2).",
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
    _(
      "API Key for OpenAI (sk-...), Anthropic, DeepSeek, OpenRouter, or Gemini (optional for Ollama / LM Studio)",
    ),
  );
  o.depends("enable_ai_doctor", "1");
  o.password = true;
  o.rmempty = true;
  disablePasswordAutofill(o);

  o = section.taboption(
    "ai",
    form.Value,
    "ai_doctor_custom_url",
    _("Custom API Endpoint URL"),
    _(
      "Custom OpenAI-compatible API endpoint or base URL (e.g. http://192.168.1.100:1234 or http://192.168.1.100:11434/v1/chat/completions). Leave empty to use official provider URL.",
    ),
  );
  o.depends("enable_ai_doctor", "1");
  o.rmempty = true;
  o.placeholder = "http://192.168.1.100:1234/v1/chat/completions";

  // RAG (Knowledge Base Retrieval)
  o = section.taboption(
    "ai",
    form.Flag,
    "enable_rag",
    _("Enable RAG (Knowledge Base Retrieval)"),
    _(
      "Pre-built index of Tachyon documentation chunks. When enabled, AI Doctor searches relevant docs before generating a diagnosis.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

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
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_proxy_health_enabled",
    _("Enable Proxy Health Monitor"),
    _(
      "Periodically checks if the proxy is responding. Restarts Tachyon after consecutive failures.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "ai_proxy_health_interval",
    _("Proxy Health Check Interval (s)"),
    _("How often to check proxy health in seconds (fast tier, default 30)."),
  );
  o.default = "30";
  o.datatype = "min(15)";
  o.depends("ai_proxy_health_enabled", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "ai_proxy_health_fail_threshold",
    _("Proxy Fail Threshold"),
    _("Number of consecutive failures before restarting (default 3)."),
  );
  o.default = "3";
  o.datatype = "min(1)";
  o.depends("ai_proxy_health_enabled", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "ai_proxy_health_url",
    _("Proxy Health Check URL"),
    _("URL to test through the proxy (default: Cloudflare 204)."),
  );
  o.default = "https://cp.cloudflare.com/generate_204";
  o.depends("ai_proxy_health_enabled", "1");

  // DNS Continuous Check
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_dns_continuous_enabled",
    _("Enable DNS Continuous Check"),
    _(
      "Faster DNS health monitoring than the default cycle. Switches bootstrap DNS on failure.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "ai_dns_interval",
    _("DNS Check Interval (s)"),
    _("How often to check DNS health in seconds (default 60)."),
  );
  o.default = "60";
  o.datatype = "min(30)";
  o.depends("ai_dns_continuous_enabled", "1");

  // Reload Dedup
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_reload_dedup_enabled",
    _("Enable Firewall Reload Dedup"),
    _(
      "Prevents multiple reload_firewall calls within 120 seconds to avoid connection drops.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Metrics
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_metrics_enabled",
    _("Enable Health Metrics"),
    _(
      "Records proxy/DNS latency and health status in hourly buckets for analysis.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "ai_metrics_retention_hours",
    _("Metrics Retention (hours)"),
    _("How many hours of metrics to keep (default 24)."),
  );
  o.default = "24";
  o.datatype = "min(1)";
  o.depends("ai_metrics_enabled", "1");

  // Smart Cooldowns
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_smart_cooldowns_enabled",
    _("Enable Smart Cooldowns"),
    _(
      "Use 3-tier check intervals: fast (15s), normal (120s), slow (300s) instead of a single interval.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Config Validation
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_config_validation_enabled",
    _("Enable Config Validation"),
    _(
      "Validates sing-box config before restart to prevent boot loops on broken configs.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Graceful Degradation
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_graceful_degradation_enabled",
    _("Enable Graceful Degradation"),
    _(
      "If one health check fails with an error, continue running other checks instead of stopping.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Persistent Smart Detect
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_persistent_smart_detect",
    _("Persistent Smart Detect"),
    _(
      "Store auto-detected domains in /etc instead of /tmp to survive reboots.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Adaptive Intervals
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_adaptive_intervals_enabled",
    _("Enable Adaptive Intervals"),
    _(
      "Automatically increase check intervals when healthy (to 5 min) and decrease on problems (to 120s).",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  // Anomaly Detection
  o = section.taboption(
    "ai",
    form.Flag,
    "ai_anomaly_detection_enabled",
    _("Enable Anomaly Detection"),
    _(
      "Monitors sing-box reconnect frequency. Alerts if too many reconnects per hour.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enable_watchdog", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "ai_anomaly_reconnect_threshold",
    _("Reconnect Threshold"),
    _("Max reconnects per hour before alert (default 10)."),
  );
  o.default = "10";
  o.datatype = "min(1)";
  o.depends("ai_anomaly_detection_enabled", "1");

  o = section.taboption(
    "ai",
    form.Value,
    "memory_limit_mb",
    _("Memory Limit (MB)"),
    _(
      "Dynamic GOMEMLIMIT memory cap in MB for sing-box / tachyon-core. Set 0 for auto (50% RAM on low-memory devices or when OOM occurs).",
    ),
  );
  o.default = "0";
  o.datatype = "uinteger";

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

  // Default is the upstream 1.4.4 detector; Plus is explicitly opt-in.
  const smartDetectDescriptions = {
    default: _(
      "Default: uses sing-box error logs and HTTPS HEAD probes. Adds the detected hostname after repeated Direct failures confirmed at least 120 seconds apart and a successful shared proxy probe.",
    ),
    plus: _(
      "Plus: also watches stalled LAN HTTP/HTTPS connections and checks full GET responses. Two failed Direct GET probes and a successful shared proxy GET are required. Saves the main domain with its subdomains using the Public Suffix List. DNS resolution and local certificate errors defer detection.",
    ),
  };
  o = section.taboption(
    "services",
    form.ListValue,
    "smart_detect_mode",
    _("Smart Detect mode"),
    smartDetectDescriptions.default,
  );
  o.value("default", _("Default (upstream)"));
  o.value("plus", _("Plus"));
  o.default = "default";
  o.rmempty = false;
  o.depends("smart_detect", "1");
  o.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "smart_detect_mode") === "plus"
      ? "plus"
      : "default";
  };
  const smartDetectRenderWidget = o.renderWidget;
  o.renderWidget = function (section_id, option_index, cfgvalue) {
    this.description =
      smartDetectDescriptions[cfgvalue === "plus" ? "plus" : "default"];
    return smartDetectRenderWidget.call(
      this,
      section_id,
      option_index,
      cfgvalue,
    );
  };
  o.onchange = function (_ev, section_id, value) {
    this.description =
      smartDetectDescriptions[value === "plus" ? "plus" : "default"];
    const field = this.map.findElement("data-field", this.cbid(section_id));
    const description = field && field.querySelector(".cbi-value-description");
    if (description) description.textContent = this.description;
  };

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
    const el = document.getElementById(
      "smart-detect-sections-widget-" + section_id,
    );
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

  const sdExpandOpt = section.taboption(
    "services",
    form.Flag,
    "smart_detect_expand_to_root",
    _("Expand detected subdomains to root domain"),
    _(
      "When enabled, detecting a blocked subdomain (e.g. sub.example.com) adds the entire base domain (example.com), unless this would include an excluded subdomain. When disabled, only the specific subdomain is routed through the proxy.",
    ),
  );
  sdExpandOpt.default = "1";
  sdExpandOpt.rmempty = false;
  sdExpandOpt.depends("smart_detect", "1");

  const sdExcludeOpt = section.taboption(
    "services",
    form.DynamicList,
    "smart_detect_exclude",
    _("Excluded domains from Smart Detect"),
    _(
      "Domains and subdomains that should never be automatically proxied by Smart Detect (e.g. yandex.net, mail.ru, vk.com).",
    ),
  );
  sdExcludeOpt.placeholder = "example.com";
  sdExcludeOpt.depends("smart_detect", "1");

  const sdExcludeListsOpt = section.taboption(
    "services",
    form.DynamicList,
    "smart_detect_exclude_lists",
    _("Preset exclusions for Smart Detect"),
    _(
      "Selected presets exclude their domains and subdomains from automatic Smart Detect additions. Manual routing rules and previously added domains are kept. Presets follow regular list updates; if a selected preset has no cached copy, detection waits until lists are updated.",
    ),
  );
  sdExcludeListsOpt.placeholder = _("Service list");
  sdExcludeListsOpt.depends("smart_detect", "1");
  const sdIpOnlyPresets = new Set([
    "cloudflare",
    "cloudfront",
    "hetzner",
    "ovh",
    "digitalocean",
  ]);
  const sdPresetChoices = Object.entries(main.DOMAIN_LIST_OPTIONS).filter(
    ([name]) => !sdIpOnlyPresets.has(name),
  );
  sdPresetChoices.forEach(([name, label]) =>
    sdExcludeListsOpt.value(name, label),
  );
  sdExcludeListsOpt.validate = function (_section_id, value) {
    const names = Array.isArray(value) ? value : value ? [value] : [];
    return names.every((name) => sdPresetChoices.some(([key]) => key === name))
      ? true
      : _("Select a predefined domain list");
  };

  const sdDomainsOpt = section.option(
    form.DummyValue,
    "_smart_detect_domains",
    _("Auto-detected domains"),
    _(
      "List of domains automatically detected and the section they were added to. To edit or remove them, open the routing rules of the respective section.",
    ),
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

    function esc(s) {
      return String(s || "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
    }
    let html = '<ul style="margin:0;padding-left:1.5rem;">';
    allDomains.forEach(function (item) {
      html +=
        "<li><code>" +
        esc(item.domain) +
        "</code> &rarr; <b>" +
        esc(item.section) +
        "</b></li>";
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

  let tgInFlight = false;
  let tgHasMounted = false;
  let tgLoadedOnce = false;

  function refreshStatus(force) {
    if (tgInFlight) return Promise.resolve();
    if (
      !force &&
      (!wrapper.isConnected || wrapper.offsetParent === null || document.hidden)
    ) {
      return Promise.resolve();
    }
    tgInFlight = true;
    tgLoadedOnce = true;
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
      })
      .finally(function () {
        tgInFlight = false;
      });
  }

  btnStart.addEventListener("click", function () {
    btnStart.disabled = true;
    statusMsg.textContent = _("Starting…");
    fs.exec("/usr/bin/tachyon", ["telegram_start"])
      .then(function () {
        statusMsg.textContent = "";
        return refreshStatus(true);
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
        return refreshStatus(true);
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

  let tgVisibilityObserver = null;
  if (typeof IntersectionObserver !== "undefined") {
    tgVisibilityObserver = new IntersectionObserver(function (entries) {
      if (entries.some((e) => e.isIntersecting) && !tgLoadedOnce) {
        refreshStatus(true);
      }
    });
    tgVisibilityObserver.observe(wrapper);
  } else {
    refreshStatus(true);
  }

  // Refresh every 10s while visible
  const timer = setInterval(function () {
    if (wrapper.isConnected) {
      tgHasMounted = true;
    } else if (tgHasMounted) {
      clearInterval(timer);
      if (tgVisibilityObserver) tgVisibilityObserver.disconnect();
      return;
    }
    refreshStatus(false);
  }, 10000);

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
  o.password = true;
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (this.section.formvalue(section_id, "enabled") === "1" && !value) {
      return _("Token is required when the bot is enabled");
    }
    return true;
  };
  disablePasswordAutofill(o);
  o.write = function (section_id, value) {
    const val = value ? `${value}`.trim() : "";
    if (val) {
      uci.set(UCI_PACKAGE, section_id, "bot_token", val);
    } else {
      uci.unset(UCI_PACKAGE, section_id, "bot_token");
    }
  };
  o.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "bot_token");
  };

  o = section.option(
    form.Value,
    "admin_ids",
    _("Administrator Chat IDs"),
    _(
      "Comma-separated list of Telegram user IDs authorized to control the bot.",
    ),
  );
  o.rmempty = true;
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
  o.write = function (section_id, value) {
    const val = value ? `${value}`.trim() : "";
    if (val) {
      uci.set(UCI_PACKAGE, section_id, "admin_ids", val);
    } else {
      uci.unset(UCI_PACKAGE, section_id, "admin_ids");
    }
  };
  o.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "admin_ids");
  };

  o = section.option(
    form.Value,
    "router_name",
    _("Router Name"),
    _(
      "Optional name displayed at the top of all Telegram bot messages to identify this router when multiple routers share the same bot token.",
    ),
  );
  o.placeholder = _("Home Router / Office / Dacha");
  o.rmempty = true;
  o.write = function (section_id, value) {
    const val = value ? `${value}`.trim() : "";
    if (val) {
      uci.set(UCI_PACKAGE, section_id, "router_name", val);
    } else {
      uci.unset(UCI_PACKAGE, section_id, "router_name");
    }
  };
  o.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "router_name");
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
  o.rmempty = true;
  o.validate = function (section_id, value) {
    if (this.section.formvalue(section_id, "enabled") !== "1" || !value) {
      return true;
    }
    const val = parseInt(value);
    if (isNaN(val) || val < 1) {
      return _("Polling interval must be at least 1 second");
    }
    return true;
  };
  o.write = function (section_id, value) {
    const val = value ? `${value}`.trim() : "";
    if (val && val !== "5") {
      uci.set(UCI_PACKAGE, section_id, "poll_interval", val);
    } else {
      uci.unset(UCI_PACKAGE, section_id, "poll_interval");
    }
  };
  o.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, "poll_interval");
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
    _(
      "Route bot API requests through this section. Leave empty to use the default mixed proxy.",
    ),
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

  // ── Telegram API Connection Test ──────────────────────────────────────────

  const testOpt = section.option(
    form.DummyValue,
    "_test_telegram_connection",
    _("Test Telegram Connection"),
  );
  testOpt.rawhtml = true;
  testOpt.cfgvalue = function () {
    const wrapper = E("div", { style: "margin-top: 8px;" });
    const btn = E(
      "button",
      {
        class: "btn cbi-button cbi-button-action",
        type: "button",
        id: "tachyon-telegram-test-btn",
      },
      "\uD83D\uDD0C " + _("Test Connection"),
    );
    const result = E("div", {
      id: "tachyon-telegram-test-result",
      style:
        "margin-top: 8px; white-space: pre-wrap; font-family: monospace; font-size: 12px; display: none;",
    });
    wrapper.appendChild(btn);
    wrapper.appendChild(result);

    btn.addEventListener("click", function () {
      btn.disabled = true;
      btn.textContent = "\u23F3 " + _("Testing…");
      result.style.display = "block";
      result.style.color = "";
      result.textContent = _("Running diagnostics…");

      fs.exec("/usr/bin/tachyon", ["telegram_diagnose"])
        .then(function (res) {
          var data;
          try {
            data = JSON.parse(res.stdout || "{}");
          } catch (e) {
            data = null;
          }

          if (!data || !data.checks) {
            result.textContent =
              "\u274C " +
              _("Failed to run diagnostics — is the tachyon binary installed?");
            btn.disabled = false;
            btn.textContent = "\uD83D\uDD0C " + _("Test Connection");
            return;
          }

          var lines = [];
          for (var i = 0; i < data.checks.length; i++) {
            var c = data.checks[i];
            lines.push((c.ok ? "\u2705" : "\u274C") + " " + c.message);
          }
          if (data.ok) {
            lines.push("");
            lines.push(
              "\u2705 " +
                _("All checks passed — Telegram bot should work correctly"),
            );
          }
          result.textContent = lines.join("\n");
          result.style.color = data.ok ? "" : "#e53935";
          btn.disabled = false;
          btn.textContent = "\uD83D\uDD0C " + _("Test Connection");
        })
        .catch(function () {
          result.textContent =
            "\u274C " +
            _("Failed to run diagnostics — is the tachyon binary installed?");
          btn.disabled = false;
          btn.textContent = "\uD83D\uDD0C " + _("Test Connection");
        });
    });

    return wrapper;
  };
}

const EntryPoint = {
  createSettingsContent,
  createTelegramContent,
};

return baseclass.extend(EntryPoint);
