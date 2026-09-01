"use strict";
"require view";
"require form";
"require baseclass";
"require uci";
"require ui";
"require view.tachyon.main as main";

// Global settings
"require view.tachyon.settings as settings";

// Sections
"require view.tachyon.section as section";

// Server
"require view.tachyon.server as server";

// Parental Control
"require view.tachyon.parental as parental";

// Dashboard
"require view.tachyon.dashboard as dashboard";

// Monitoring
"require view.tachyon.monitoring as monitoring";

// Diagnostic
"require view.tachyon.diagnostic as diagnostic";

// Updates
"require view.tachyon.updates as updates";

const UCI_PACKAGE = main.TACHYON_UCI_PACKAGE;
const CBI_PREFIX = UCI_PACKAGE;

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  return _("Edit");
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  sectionRef.renderRowActions = function (section_id) {
    const els = form.TableSection.prototype.renderRowActions.call(
      this,
      section_id,
      getRuleEditButtonText(),
    );

    if (type === "section") {
      const btn = E(
        "button",
        {
          type: "button",
          class: "btn cbi-button cbi-button-action",
          title: _("Rules"),
          click: function (ev) {
            ev.preventDefault();
            ev.stopPropagation();
            section.showSectionRulesModal(section_id);
          },
        },
        _("Rules"),
      );

      if (els && els.lastElementChild) {
        const div = els.lastElementChild;
        const editBtn = div.querySelector(".cbi-button-edit");
        if (editBtn) {
          div.insertBefore(btn, editBtn);
          btn.style.marginRight = "5px";
        } else {
          div.appendChild(btn);
        }
      }
    }

    return els;
  };
}

const EntryPoint = {
  load() {
    // Pre-load UCI so that tab_order and show_tab_* are available
    // synchronously in render() before section factories are registered.
    return uci.load([UCI_PACKAGE]);
  },
  async render() {
    main.injectGlobalStyles();
    const uiCapabilities = {
      loaded: false,
      singBoxExtended: false,
      singBoxTiny: false,
      singBoxTailscale: true,
      zapretInstalled: false,
      zapret2Installed: false,
      byedpiInstalled: false,
      serverInboundsEnabledCount: -1,
    };
    let uiCapabilitiesPromise = null;
    let serverSectionRef = null;

    const applyUiCapabilities = function () {
      if (serverSectionRef) {
        server.applyServerCapabilities(serverSectionRef, uiCapabilities);
      }

      if (typeof window !== "undefined") {
        window.dispatchEvent(
          new CustomEvent(main.TACHYON_ACTION_PROVIDERS_AVAILABILITY_EVENT, {
            detail: {
              zapretInstalled: uiCapabilities.zapretInstalled,
              zapret2Installed: uiCapabilities.zapret2Installed,
              byedpiInstalled: uiCapabilities.byedpiInstalled,
            },
          }),
        );
      }

      if (main.store && typeof main.store.set === "function") {
        const currentSystemInfo = main.store.get().diagnosticsSystemInfo;
        main.store.set({
          diagnosticsSystemInfo: {
            ...currentSystemInfo,
            providerInfoLoaded: true,
            sing_box_extended: uiCapabilities.singBoxExtended ? 1 : 0,
            sing_box_tiny: uiCapabilities.singBoxTiny ? 1 : 0,
            sing_box_tailscale: uiCapabilities.singBoxTailscale ? 1 : 0,
            zapret_installed: uiCapabilities.zapretInstalled ? 1 : 0,
            zapret2_installed: uiCapabilities.zapret2Installed ? 1 : 0,
            byedpi_installed: uiCapabilities.byedpiInstalled ? 1 : 0,
            server_inbounds_enabled_count:
              uiCapabilities.serverInboundsEnabledCount,
            zapret_version: uiCapabilities.zapretInstalled
              ? currentSystemInfo.zapret_version
              : "not installed",
            zapret2_version: uiCapabilities.zapret2Installed
              ? currentSystemInfo.zapret2_version
              : "not installed",
            byedpi_version: uiCapabilities.byedpiInstalled
              ? currentSystemInfo.byedpi_version
              : "not installed",
          },
        });
      }
    };

    const updateUiCapabilities = function (data) {
      uiCapabilities.loaded = true;
      uiCapabilities.singBoxExtended = Boolean(
        Number(data?.sing_box_extended) === 1,
      );
      uiCapabilities.singBoxTiny = Boolean(Number(data?.sing_box_tiny) === 1);
      uiCapabilities.singBoxTailscale =
        typeof data?.sing_box_tailscale === "undefined"
          ? true
          : Boolean(Number(data.sing_box_tailscale) === 1);
      uiCapabilities.zapretInstalled = Boolean(
        Number(data?.zapret_installed) === 1,
      );
      uiCapabilities.zapret2Installed = Boolean(
        Number(data?.zapret2_installed) === 1,
      );
      uiCapabilities.byedpiInstalled = Boolean(
        Number(data?.byedpi_installed) === 1,
      );
      const serverInboundsEnabledCount =
        typeof data?.server_inbounds_enabled_count !== "undefined"
          ? Number(data.server_inbounds_enabled_count)
          : -1;
      uiCapabilities.serverInboundsEnabledCount = Number.isFinite(
        serverInboundsEnabledCount,
      )
        ? serverInboundsEnabledCount
        : -1;

      applyUiCapabilities();

      return uiCapabilities;
    };

    const applyUiState = function (data) {
      const result = updateUiCapabilities(data?.capabilities || data || {});

      if (typeof main.applyUiStateToStore === "function" && data?.service) {
        main.applyUiStateToStore(data);
      } else if (
        main.store &&
        typeof main.store.set === "function" &&
        data?.service
      ) {
        main.store.set({
          servicesInfoWidget: {
            loading: false,
            failed: false,
            data: {
              singbox: Number(data.service.sing_box?.running) || 0,
              tachyonRunning: Number(data.service.tachyon?.running) || 0,
              tachyonEnabled: Number(data.service.tachyon?.enabled) || 0,
              tachyonStatus: data.service.tachyon?.status || "",
            },
          },
        });
      }

      return result;
    };

    const loadFallbackUiCapabilities = function () {
      return Promise.allSettled([
        main.TachyonShellMethods.getServerCapabilities(),
        main.TachyonShellMethods.checkZapretRuntime(),
        main.TachyonShellMethods.checkZapret2Runtime(),
        main.TachyonShellMethods.checkByedpiRuntime(),
        main.TachyonShellMethods.checkInboundsConfig(),
      ]).then(
        ([
          serverCapabilitiesResult,
          zapretRuntimeResult,
          zapret2RuntimeResult,
          byedpiRuntimeResult,
          inboundsConfigResult,
        ]) => {
          const serverCapabilities =
            serverCapabilitiesResult.status === "fulfilled"
              ? serverCapabilitiesResult.value
              : null;
          const zapretRuntime =
            zapretRuntimeResult.status === "fulfilled"
              ? zapretRuntimeResult.value
              : null;
          const zapret2Runtime =
            zapret2RuntimeResult.status === "fulfilled"
              ? zapret2RuntimeResult.value
              : null;
          const byedpiRuntime =
            byedpiRuntimeResult.status === "fulfilled"
              ? byedpiRuntimeResult.value
              : null;
          const inboundsConfig =
            inboundsConfigResult.status === "fulfilled"
              ? inboundsConfigResult.value
              : null;

          return updateUiCapabilities({
            sing_box_extended:
              serverCapabilities?.success &&
              Number(serverCapabilities.data?.sing_box_extended) === 1
                ? 1
                : 0,
            sing_box_tiny:
              serverCapabilities?.success &&
              Number(serverCapabilities.data?.sing_box_tiny) === 1
                ? 1
                : 0,
            sing_box_tailscale:
              !serverCapabilities?.success ||
              typeof serverCapabilities.data?.sing_box_tailscale ===
                "undefined" ||
              Number(serverCapabilities.data?.sing_box_tailscale) === 1
                ? 1
                : 0,
            zapret_installed:
              zapretRuntime?.success &&
              Number(zapretRuntime.data?.zapret_installed) === 1
                ? 1
                : 0,
            zapret2_installed:
              zapret2Runtime?.success &&
              Number(zapret2Runtime.data?.zapret2_installed) === 1
                ? 1
                : 0,
            byedpi_installed:
              byedpiRuntime?.success &&
              Number(byedpiRuntime.data?.byedpi_installed) === 1
                ? 1
                : 0,
            server_inbounds_enabled_count:
              inboundsConfig?.success &&
              typeof inboundsConfig.data?.enabled_count !== "undefined"
                ? inboundsConfig.data.enabled_count
                : -1,
          });
        },
      );
    };

    const loadUiCapabilities = function () {
      if (uiCapabilities.loaded) {
        return Promise.resolve(uiCapabilities);
      }

      if (uiCapabilitiesPromise) {
        return uiCapabilitiesPromise;
      }

      uiCapabilitiesPromise = main.TachyonShellMethods.getUiCapabilities()
        .then((response) => {
          if (!response?.success) {
            throw new Error("UI capabilities request failed");
          }

          return updateUiCapabilities(response.data);
        })
        .catch((error) => {
          console.warn("Failed to load Tachyon UI capabilities", error);
          return main.TachyonShellMethods.getUiState()
            .then((response) => {
              if (!response?.success) {
                throw new Error("UI state request failed");
              }

              return applyUiState(response.data);
            })
            .catch((fallbackError) => {
              console.warn("Failed to load Tachyon UI state", fallbackError);
              return loadFallbackUiCapabilities();
            });
        })
        .finally(() => {
          uiCapabilitiesPromise = null;
        });

      return uiCapabilitiesPromise;
    };
    const tachyonMap = new form.Map(
      UCI_PACKAGE,
      _("Tachyon Settings"),
      _("Configuration for Tachyon service"),
    );
    tachyonMap.tabbed = true;
    tachyonMap.load = function () {
      const self = this;
      return uci.load(self.config).then(() => {
        if (!uci.get(self.config, "settings")) {
          uci.add(self.config, "settings", "settings");
        }
        if (!uci.get(self.config, "telegram")) {
          uci.add(self.config, "telegram", "telegram");
        }
        return form.Map.prototype.load.call(self);
      });
    };
    const originalHandleSaveApply = tachyonMap.handleSaveApply;
    tachyonMap.handleSaveApply = function (ev, mode) {
      const refreshUiState = function () {
        main.TachyonShellMethods.getUiState()
          .then((response) => {
            if (
              response?.success &&
              typeof main.applyUiStateToStore === "function"
            ) {
              main.applyUiStateToStore(response.data);
            }
          })
          .catch(() => null);
      };

      if (main.store && typeof main.store.set === "function") {
        const servicesInfoWidget = main.store.get().servicesInfoWidget;
        main.store.set({
          servicesInfoWidget: {
            ...servicesInfoWidget,
            data: {
              ...servicesInfoWidget.data,
              tachyonStatus: "reloading",
            },
          },
        });
      }

      return Promise.resolve(originalHandleSaveApply.call(this, ev, mode))
        .then((result) => {
          window.setTimeout(refreshUiState, 250);

          return result;
        })
        .catch((error) => {
          refreshUiState();

          throw error;
        });
    };

    const rawTabOrder = uci.get(UCI_PACKAGE, "settings", "tab_order");
    const savedOrder = Array.isArray(rawTabOrder)
      ? rawTabOrder
      : typeof rawTabOrder === "string" && rawTabOrder.trim()
        ? rawTabOrder.trim().split(/\s+/)
        : [];

    const defaultTabOrder = [
      "dashboard",
      "section",
      "server",
      "profile",
      "schedule",
      "monitoring",
      "diagnostic",
      "updates",
      "settings",
      "telegram",
    ];

    const tabOrder = [];
    savedOrder.forEach((id) => {
      if (defaultTabOrder.indexOf(id) >= 0 && tabOrder.indexOf(id) < 0) {
        tabOrder.push(id);
      }
    });
    defaultTabOrder.forEach((id) => {
      if (tabOrder.indexOf(id) < 0) {
        tabOrder.push(id);
      }
    });

    const defaultTab =
      uci.get(UCI_PACKAGE, "settings", "default_tab") || "dashboard";

    const isTabVisible = (id) => {
      if (id === "settings") return true;
      if (id === "server") {
        return (
          uci.get(UCI_PACKAGE, "settings", "show_tab_servers") === "1" ||
          uci.get(UCI_PACKAGE, "settings", "show_tab_server") === "1"
        );
      }
      if (id === "profile") {
        return (
          uci.get(UCI_PACKAGE, "settings", "show_tab_profiles") === "1" ||
          uci.get(UCI_PACKAGE, "settings", "show_tab_profile") === "1"
        );
      }
      if (id === "schedule") {
        return (
          uci.get(UCI_PACKAGE, "settings", "show_tab_parental") === "1" ||
          uci.get(UCI_PACKAGE, "settings", "show_tab_schedule") === "1"
        );
      }
      return uci.get(UCI_PACKAGE, "settings", "show_tab_" + id) !== "0";
    };

    const sectionFactories = {
      dashboard: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "dashboard",
          _("Dashboard"),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["dashboard"];
        };
        dashboard.createDashboardContent(s);
        return s;
      },
      section: () => {
        const s = tachyonMap.section(
          form.GridSection,
          "section",
          _("Sections"),
          _(
            "Drag rows to change priority. The rule at the top is checked first.",
          ),
        );
        configureGridSection(s, "section", _("Section"), _("Add a section"));
        section.configureSectionSection(s, {
          loadActionProvidersAvailability: loadUiCapabilities,
        });
        section.createSectionContent(s);
        return s;
      },
      server: () => {
        const s = tachyonMap.section(
          form.GridSection,
          "server",
          _("Servers"),
          _("Accept external proxy connections and route them with sing-box."),
        );
        configureGridSection(
          s,
          "server",
          _("Server"),
          _("Add a server inbound"),
        );
        serverSectionRef = s;
        server.configureServerSection(s, {
          loadCapabilities: loadUiCapabilities,
        });
        server.createServerContent(s, uiCapabilities);
        return s;
      },
      profile: () => {
        const s = tachyonMap.section(
          form.GridSection,
          "profile",
          _("Family Profiles"),
          _(
            "Group devices into family profiles to manage content filtering, SafeSearch, and screen time limits in one place.",
          ),
        );
        configureGridSection(
          s,
          "profile",
          _("Family Profile"),
          _("Add a family profile"),
        );
        parental.createProfileContent(s);
        return s;
      },
      schedule: () => {
        const s = tachyonMap.section(
          form.GridSection,
          "schedule",
          _("Parental Control"),
          _(
            "Block internet access or specific proxy sections for family profiles or individual devices based on time and days.",
          ),
        );
        configureGridSection(
          s,
          "schedule",
          _("Schedule Rule"),
          _("Add a schedule rule"),
        );
        parental.createParentalContent(s);
        return s;
      },
      monitoring: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "monitoring",
          _("Monitoring"),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["monitoring"];
        };
        monitoring.createMonitoringContent(s);
        return s;
      },
      diagnostic: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "diagnostic",
          _("Diagnostics"),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["diagnostic"];
        };
        diagnostic.createDiagnosticContent(s);
        return s;
      },
      updates: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "updates",
          _("Components"),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["updates"];
        };
        updates.createUpdatesContent(s);
        return s;
      },
      settings: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "settings",
          _("Settings"),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["settings"];
        };
        settings.createSettingsContent(s, uiCapabilities);
        return s;
      },
      telegram: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "telegram",
          _("Telegram Bot"),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["telegram"];
        };
        settings.createTelegramContent(s);
        return s;
      },
    };

    // Instantiate enabled sections in configured tab order
    for (const tabId of tabOrder) {
      if (
        isTabVisible(tabId) &&
        typeof sectionFactories[tabId] === "function"
      ) {
        sectionFactories[tabId]();
      }
    }

    await loadUiCapabilities().catch(() => null);

    const rendered = await tachyonMap.render();
    main.coreService({
      waitForLogWatcherStart: loadUiCapabilities,
      logWatcherStartDelayMs: 5000,
    });

    if (!window.location.hash || window.location.hash === "#") {
      const targetTabKey = defaultTab;
      window.requestAnimationFrame(() => {
        const tabLink = document.querySelector(
          `.cbi-tab[data-tab="cbi-tachyon-${targetTabKey}"] a, ` +
            `.cbi-tab[data-tab="${targetTabKey}"] a, ` +
            `[data-tab="cbi-tachyon-${targetTabKey}"] > a, ` +
            `[data-tab="${targetTabKey}"] > a, ` +
            `li[data-tab="cbi-tachyon-${targetTabKey}"] a, ` +
            `li[data-tab="${targetTabKey}"] a`,
        );
        if (tabLink) {
          tabLink.click();
        }
      });
    }

    return rendered;
  },
};

return view.extend(EntryPoint);
