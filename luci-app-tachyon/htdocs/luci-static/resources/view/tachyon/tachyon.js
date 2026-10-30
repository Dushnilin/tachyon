"use strict";
"require view";
"require form";
"require baseclass";
"require dom";
"require fs";
"require network";
"require rpc";
"require uci";
"require ui";
"require tools.widgets as widgets";
"require view.tachyon.main as main";
"require view.tachyon.local_devices as localDevices";
"require view.tachyon.dns_speed_test as dnsSpeedTest";

// Global settings
"require view.tachyon.settings as settings";

// Sections
"require view.tachyon.section as section";

// Modular Conditions, Outbounds, Balancers (#242)
"require view.tachyon.conditions as conditions";
"require view.tachyon.outbounds as outbounds";
"require view.tachyon.balancers as balancers";

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

function createSvgIcon(children, attrs = {}) {
  const baseAttrs = {
    viewBox: "0 0 24 24",
    width: "16",
    height: "16",
    fill: "none",
    stroke: "currentColor",
    "stroke-width": "2",
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
    "aria-hidden": "true",
    focusable: "false",
    ...attrs,
  };
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  Object.entries(baseAttrs).forEach(([key, value]) =>
    svg.setAttribute(key, `${value}`),
  );
  children.forEach(({ tag, attrs: childAttrs }) => {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    Object.entries(childAttrs).forEach(([key, value]) =>
      node.setAttribute(key, `${value}`),
    );
    svg.appendChild(node);
  });
  return svg;
}

function createCloneIcon() {
  return createSvgIcon([
    {
      tag: "rect",
      attrs: { x: "9", y: "9", width: "12", height: "12", rx: "2.5" },
    },
    {
      tag: "path",
      attrs: {
        d: "M6 15H5.5A2.5 2.5 0 0 1 3 12.5v-7A2.5 2.5 0 0 1 5.5 3h7A2.5 2.5 0 0 1 15 5.5V6",
      },
    },
  ]);
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.cfgsections = function () {
    return (uci.sections(this.map.config, this.sectiontype) || [])
      .map((s) => (s ? s[".name"] : null))
      .filter(Boolean);
  };
  const getDisplayLabel = (sid) =>
    type === "section" || type === "profile"
      ? uci.get(UCI_PACKAGE, sid, "label") ||
        uci.get(UCI_PACKAGE, sid, "name") ||
        sid
      : uci.get(UCI_PACKAGE, sid, "name") ||
        uci.get(UCI_PACKAGE, sid, "label") ||
        sid;
  sectionRef.modaltitle = function (section_id) {
    return section_id ? `${title}: ${getDisplayLabel(section_id)}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return getDisplayLabel(section_id);
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  const origMoreModal = sectionRef.renderMoreOptionsModal;
  sectionRef.renderMoreOptionsModal = function () {
    const res = origMoreModal
      ? origMoreModal.apply(this, arguments)
      : form.GridSection.prototype.renderMoreOptionsModal.apply(
          this,
          arguments,
        );
    return Promise.resolve(res).finally(() => {
      if (typeof sectionRef._refreshStudioDeck === "function") {
        window.setTimeout(() => sectionRef._refreshStudioDeck(), 80);
      }
    });
  };

  const origModalSave = sectionRef.handleModalSave;
  sectionRef.handleModalSave = function () {
    const res = origModalSave
      ? origModalSave.apply(this, arguments)
      : form.GridSection.prototype.handleModalSave.apply(this, arguments);
    return Promise.resolve(res).finally(() => {
      try {
        if (typeof uci !== "undefined" && typeof uci.save === "function") {
          Promise.resolve(uci.save())
            .then(() => {
              if (
                typeof ui !== "undefined" &&
                ui.changes &&
                typeof ui.changes.init === "function"
              ) {
                return ui.changes.init();
              }
              return null;
            })
            .finally(() => {
              if (typeof sectionRef._refreshStudioDeck === "function") {
                sectionRef._refreshStudioDeck();
              }
            });
        } else if (typeof sectionRef._refreshStudioDeck === "function") {
          sectionRef._refreshStudioDeck();
        }
      } catch (_e) {
        if (typeof sectionRef._refreshStudioDeck === "function") {
          sectionRef._refreshStudioDeck();
        }
      }
    });
  };

  const origModalCancel = sectionRef.handleModalCancel;
  sectionRef.handleModalCancel = function () {
    const res = origModalCancel
      ? origModalCancel.apply(this, arguments)
      : form.GridSection.prototype.handleModalCancel.apply(this, arguments);
    return Promise.resolve(res).finally(() => {
      if (typeof sectionRef._refreshStudioDeck === "function") {
        window.setTimeout(() => sectionRef._refreshStudioDeck(), 80);
      }
    });
  };

  const origRemove = sectionRef.remove;
  sectionRef.remove = function (section_id) {
    if (
      type === "section" &&
      section &&
      typeof section.cascadeDeleteSection === "function"
    ) {
      section.cascadeDeleteSection(section_id);
    }
    if (origRemove) {
      return origRemove.apply(this, arguments);
    }
    if (typeof form.GridSection.prototype.remove === "function") {
      return form.GridSection.prototype.remove.apply(this, arguments);
    }
    return uci.remove(UCI_PACKAGE, section_id);
  };

  if (type === "section") {
    const origAdd = sectionRef.handleAdd;
    sectionRef.handleAdd = function (ev, name) {
      let sectionName =
        typeof name === "string" && name.trim() ? name.trim() : null;
      if (!sectionName && ev && ev.target) {
        const container = ev.target.closest
          ? ev.target.closest(".cbi-section-create")
          : null;
        const input = container
          ? container.querySelector(".cbi-section-create-name")
          : this.map
            ? document.querySelector(".cbi-section-create-name")
            : null;
        if (input && input.value) {
          sectionName = input.value.trim();
        }
      }
      if (
        sectionName &&
        section &&
        typeof section.cascadeDeleteSection === "function"
      ) {
        section.cascadeDeleteSection(sectionName);
      }
      return origAdd
        ? origAdd.apply(this, arguments)
        : form.GridSection.prototype.handleAdd.apply(this, arguments);
    };
  }

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

      const cloneBtn = E(
        "button",
        {
          type: "button",
          class: "btn cbi-button cbi-button-action",
          title: _("Clone"),
          "aria-label": _("Clone"),
          style:
            "display: inline-flex; align-items: center; justify-content: center; padding: 4px 8px;",
          click: function (ev) {
            ev.preventDefault();
            ev.stopPropagation();
            const newId = section.cloneSection(section_id);
            if (newId) {
              Promise.resolve(
                typeof sectionRef.map.reset === "function"
                  ? sectionRef.map.reset()
                  : sectionRef.map
                      .load()
                      .then(() =>
                        typeof sectionRef.map.renderContents === "function"
                          ? sectionRef.map.renderContents()
                          : sectionRef.map.render(),
                      ),
              ).catch(() => null);
              ui.addNotification(
                null,
                E("p", {}, _("Section cloned") + `: ${newId}`),
                "info",
              );
            }
          },
        },
        createCloneIcon(),
      );

      if (els && els.lastElementChild) {
        const div = els.lastElementChild;
        const editBtn = div.querySelector(".cbi-button-edit");
        if (editBtn) {
          div.insertBefore(btn, editBtn);
          div.insertBefore(cloneBtn, editBtn);
          btn.style.marginRight = "5px";
          cloneBtn.style.marginRight = "5px";
        } else {
          div.appendChild(btn);
          div.appendChild(cloneBtn);
        }
      }
    }

    return els;
  };
}

let preloadedUiCapabilitiesResponsePromise = null;

const EntryPoint = {
  load() {
    // Pre-load UCI, UI capabilities, and LuCI network device cache in parallel
    // so render() does not stall on a sequential 3-step RPC waterfall.
    if (
      main.TachyonShellMethods &&
      typeof main.TachyonShellMethods.getUiCapabilities === "function"
    ) {
      preloadedUiCapabilitiesResponsePromise =
        main.TachyonShellMethods.getUiCapabilities();
    }
    if (typeof network !== "undefined") {
      if (typeof network.getDevices === "function") {
        network.getDevices().catch(() => null);
      }
      if (typeof network.getNetworks === "function") {
        network.getNetworks().catch(() => null);
      }
    }
    return uci.load([UCI_PACKAGE]);
  },
  async render() {
    main.injectGlobalStyles();
    // Password managers treat any page holding a password field as a login
    // form and offer to store the neighbouring text inputs as the username.
    main.applyAutofillProtection();
    const uiCapabilities = {
      loaded: false,
      singBoxExtended: false,
      singBoxTachyonCore: false,
      singBoxTiny: false,
      singBoxTailscale: true,
      zapretInstalled: false,
      zapret2Installed: false,
      byedpiInstalled: false,
      i18nRuInstalled: false,
      luciLang: "auto",
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
              singBoxTachyonCore: uiCapabilities.singBoxTachyonCore,
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

      if (typeof main.mountLanguageSelector === "function") {
        const langSlot =
          typeof document !== "undefined"
            ? document.querySelector(".tachyon-topbar__lang-slot")
            : null;
        main.mountLanguageSelector(uiCapabilities, langSlot || undefined);
      }
    };

    const updateUiCapabilities = function (data) {
      uiCapabilities.loaded = true;
      uiCapabilities.singBoxExtended = Boolean(
        Number(data?.sing_box_extended) === 1,
      );
      // The deepest fallback payload (get-server-capabilities) predates
      // tachyon-core and carries no such key: leave a known value alone
      // rather than clearing it to false.
      if (typeof data?.sing_box_tachyon_core !== "undefined") {
        uiCapabilities.singBoxTachyonCore = Boolean(
          Number(data.sing_box_tachyon_core) === 1,
        );
      }
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
      if (typeof data?.i18n_ru_installed !== "undefined") {
        uiCapabilities.i18nRuInstalled = Boolean(
          Number(data.i18n_ru_installed) === 1,
        );
      }
      if (typeof data?.luci_lang === "string" && data.luci_lang.trim()) {
        uiCapabilities.luciLang = data.luci_lang.trim();
      }
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

      const initialRequest = preloadedUiCapabilitiesResponsePromise
        ? preloadedUiCapabilitiesResponsePromise
        : main.TachyonShellMethods.getUiCapabilities();
      preloadedUiCapabilitiesResponsePromise = null;

      uiCapabilitiesPromise = initialRequest
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
        if (!uci.get(self.config, "guest_mode")) {
          uci.add(self.config, "guest_mode", "guest_mode");
        }
        // Sync any section outbound connections & child urltest/priority_group items into outbound_source / balancer sections
        // only when modular_entities_v1 migration has not run yet; otherwise prune dangling references.
        try {
          const toArr = (v) =>
            Array.isArray(v)
              ? v.map((x) => String(x).trim()).filter(Boolean)
              : v
                ? String(v)
                    .trim()
                    .split(/[\s,]+/)
                    .filter(Boolean)
                : [];
          const toRawArr = (v) =>
            Array.isArray(v)
              ? v.map((x) => String(x).trim()).filter(Boolean)
              : v
                ? [String(v).trim()].filter(Boolean)
                : [];
          const stripPrefix = (tok) => String(tok || "").replace(/^[+!-]/, "");
          const appliedMigrations = toArr(
            uci.get(self.config, "settings", "applied_migrations"),
          );
          const alreadyMigrated =
            appliedMigrations.includes("modular_entities_v1") ||
            (uci.sections(self.config, "outbound_source") || []).length > 0 ||
            (uci.sections(self.config, "condition") || []).length > 0 ||
            (uci.sections(self.config, "balancer") || []).length > 0;

          const ensureSourceRef = (secName, srcId) => {
            const cur = toArr(
              uci.get(self.config, secName, "outbound_source_refs"),
            );
            if (!cur.includes(srcId)) {
              uci.set(self.config, secName, "outbound_source_refs", [
                ...cur,
                srcId,
              ]);
            }
          };
          const singleProtoActions = [
            "anytls",
            "naive",
            "mieru",
            "snell",
            "sudoku",
            "masque",
            "tewfai",
            "trusttunnel",
            "openconnect",
            "shadowtls",
            "warp",
            "openvpn",
            "tailscale",
            "tor",
            "desync",
          ];
          const awgFieldKeys = [
            "awg_private_key",
            "awg_server_address",
            "awg_server_port",
            "awg_peer_public_key",
            "awg_preshared_key",
            "awg_local_address",
            "awg_mtu",
            "awg_jc",
            "awg_jmin",
            "awg_jmax",
            "awg_s1",
            "awg_s2",
            "awg_s3",
            "awg_s4",
            "awg_h1",
            "awg_h2",
            "awg_h3",
            "awg_h4",
            "awg_i1",
            "awg_i2",
            "awg_i3",
            "awg_i4",
            "awg_i5",
            "awg_j1",
            "awg_j2",
            "awg_j3",
            "awg_itime",
            "awg_version",
            "awg_header_protection_key",
            "awg_content_padding_addition",
            "awg_rekey_after_time",
            "awg_rekey_timeout",
            "awg_reject_after_time",
            "awg_keepalive_timeout",
            "awg_max_handshake_attempts",
            "awg_random_trailers",
            "awg_disable_cookies",
            "awg_reserved",
            "awg_persistent_keepalive",
          ];

          (uci.sections(self.config, "section") || []).forEach((sec) => {
            if (!sec) return;
            const sname = sec[".name"];
            if (!sname) return;
            const safeSname = String(sname).replace(/[^A-Za-z0-9_]/g, "_");
            const dispName = sec.name || sec.label || sname;
            const sAct = (sec.action || "connection").toLowerCase();

            if (!alreadyMigrated && sec.access_token) {
              const fid = `src_fptn_${safeSname}`;
              if (!uci.get(self.config, fid)) {
                uci.add(self.config, "outbound_source", fid);
                uci.set(self.config, fid, "enabled", "1");
                uci.set(self.config, fid, "name", dispName);
                uci.set(self.config, fid, "source_type", "fptn");
                uci.set(self.config, fid, "access_token", sec.access_token);
              }
              ensureSourceRef(sname, fid);
            }

            if (!alreadyMigrated) {
              const links = toArr(sec.selector_proxy_links || sec.proxy_links);
              if (links.length || sec.selector_proxy_links_text) {
                const lid = `src_links_${safeSname}`;
                if (!uci.get(self.config, lid)) {
                  uci.add(self.config, "outbound_source", lid);
                  uci.set(self.config, lid, "enabled", "1");
                  uci.set(self.config, lid, "name", `${dispName} (Links)`);
                  uci.set(self.config, lid, "source_type", "proxy_links");
                  if (links.length)
                    uci.set(self.config, lid, "proxy_links", links);
                  if (sec.selector_proxy_links_text) {
                    uci.set(
                      self.config,
                      lid,
                      "proxy_links_text",
                      sec.selector_proxy_links_text,
                    );
                  }
                }
                ensureSourceRef(sname, lid);
              }
            }

            const amn = toRawArr(
              sec.selector_amnezia_configs || sec.amnezia_configs,
            );
            if (!alreadyMigrated && (amn.length || sec.amnezia_conf_text)) {
              const aid = `src_amnezia_${safeSname}`;
              if (!uci.get(self.config, aid)) {
                uci.add(self.config, "outbound_source", aid);
                uci.set(self.config, aid, "enabled", "1");
                uci.set(self.config, aid, "name", `${dispName} (Amnezia)`);
                uci.set(self.config, aid, "source_type", "amnezia_config");
                if (amn.length)
                  uci.set(self.config, aid, "amnezia_configs", amn);
                if (sec.amnezia_conf_text) {
                  uci.set(
                    self.config,
                    aid,
                    "amnezia_conf_text",
                    sec.amnezia_conf_text,
                  );
                }
              }
              ensureSourceRef(sname, aid);
            }

            const hasAwgInline = Boolean(
              sec.awg_private_key && sec.awg_server_address,
            );
            if (!alreadyMigrated && hasAwgInline) {
              const wid = `src_awg_${safeSname}`;
              if (!uci.get(self.config, wid)) {
                uci.add(self.config, "outbound_source", wid);
                uci.set(self.config, wid, "enabled", "1");
                uci.set(self.config, wid, "name", `${dispName} (AWG)`);
                uci.set(self.config, wid, "source_type", "awg");
                awgFieldKeys.forEach((k) => {
                  if (sec[k]) uci.set(self.config, wid, k, sec[k]);
                });
              }
              ensureSourceRef(sname, wid);
            }

            if (!alreadyMigrated && singleProtoActions.includes(sAct)) {
              const pid = `src_${sAct}_${safeSname}`;
              if (!uci.get(self.config, pid)) {
                uci.add(self.config, "outbound_source", pid);
                uci.set(self.config, pid, "enabled", "1");
                uci.set(self.config, pid, "name", dispName);
                uci.set(self.config, pid, "source_type", sAct);
              }
              ensureSourceRef(sname, pid);
            }
          });

          if (!alreadyMigrated) {
            const existingBalancers =
              uci.sections(self.config, "balancer") || [];
            (uci.sections(self.config, "urltest") || []).forEach((ut, idx) => {
              if (!ut) return;
              const parentSec = ut.section;
              const utName = ut.name || ut[".name"] || `urltest_${idx + 1}`;
              if (!parentSec) return;
              const safeSuffix = String(utName).replace(/[^A-Za-z0-9_]/g, "_");
              const balId = `bal_${parentSec}_${safeSuffix || idx + 1}`;
              const found = existingBalancers.find(
                (b) =>
                  b &&
                  (b[".name"] === balId ||
                    (b.name === utName &&
                      toArr(
                        uci.get(self.config, parentSec, "balancer_refs"),
                      ).includes(b[".name"]))),
              );
              if (!found && !uci.get(self.config, balId)) {
                uci.add(self.config, "balancer", balId);
                uci.set(self.config, balId, "enabled", "1");
                uci.set(self.config, balId, "balancer_type", "urltest");
                uci.set(self.config, balId, "name", utName);
                [
                  "testing_url",
                  "check_interval",
                  "tolerance",
                  "idle_timeout",
                  "interrupt_exist_connections",
                  "pin_dashboard",
                  "filter_mode",
                  "include_countries",
                  "exclude_countries",
                  "include_regex",
                  "exclude_regex",
                  "include_outbounds",
                  "exclude_outbounds",
                ].forEach((k) => {
                  if (ut[k] !== undefined && ut[k] !== null && ut[k] !== "") {
                    uci.set(self.config, balId, k, ut[k]);
                  }
                });
                const arr = toArr(
                  uci.get(self.config, parentSec, "balancer_refs"),
                );
                if (!arr.includes(balId)) {
                  uci.set(self.config, parentSec, "balancer_refs", [
                    ...arr,
                    balId,
                  ]);
                }
              }
            });
          }

          // Prune dangling references across sections, balancers, outbound_groups, and conditions
          const validSources = new Set(
            (uci.sections(self.config, "outbound_source") || [])
              .map((s) => (s ? s[".name"] : null))
              .filter(Boolean),
          );
          const validGroups = new Set(
            (uci.sections(self.config, "outbound_group") || [])
              .map((g) => (g ? g[".name"] : null))
              .filter(Boolean),
          );
          const validBalancers = new Set(
            (uci.sections(self.config, "balancer") || [])
              .map((b) => (b ? b[".name"] : null))
              .filter(Boolean),
          );
          const validConditions = new Set(
            (uci.sections(self.config, "condition") || [])
              .map((c) => (c ? c[".name"] : null))
              .filter(Boolean),
          );

          const pruneList = (sid, key, validSet, allowPrefix, allowDirect) => {
            const cur = toArr(uci.get(self.config, sid, key));
            if (!cur.length) return;
            const next = cur.filter((tok) => {
              if (allowDirect && tok === "direct") return true;
              const bare = allowPrefix ? stripPrefix(tok) : tok;
              return validSet.has(bare);
            });
            if (next.length !== cur.length) {
              if (next.length) uci.set(self.config, sid, key, next);
              else uci.unset(self.config, sid, key);
            }
          };

          (uci.sections(self.config, "section") || []).forEach((sec) => {
            const sid = sec ? sec[".name"] : null;
            if (!sid) return;
            pruneList(sid, "condition_refs", validConditions, true, false);
            pruneList(sid, "outbound_source_refs", validSources, false, false);
            pruneList(sid, "outbound_group_refs", validGroups, false, false);
            pruneList(sid, "balancer_refs", validBalancers, false, false);
          });
          const validGroupsAndSources = new Set([
            ...validGroups,
            ...validSources,
          ]);
          (uci.sections(self.config, "balancer") || []).forEach((bal) => {
            const bid = bal ? bal[".name"] : null;
            if (!bid) return;
            pruneList(bid, "source_refs", validSources, false, false);
            pruneList(bid, "group_refs", validGroups, false, false);
            pruneList(
              bid,
              "outbound_group_levels",
              validGroupsAndSources,
              false,
              true,
            );
          });
          (uci.sections(self.config, "outbound_group") || []).forEach((grp) => {
            const gid = grp ? grp[".name"] : null;
            if (!gid) return;
            pruneList(gid, "source_refs", validSources, false, false);
            pruneList(gid, "outbound_sources", validSources, false, false);
          });
          (uci.sections(self.config, "condition") || []).forEach((cond) => {
            const cid = cond ? cond[".name"] : null;
            if (!cid) return;
            pruneList(cid, "members", validConditions, true, false);
          });
          const validSectionIds = new Set(
            (uci.sections(self.config, "section") || [])
              .map((s) => (s ? s[".name"] : null))
              .filter(Boolean),
          );
          [
            "urltest",
            "priority_group",
            "priority_level",
            "subscription_url",
            "section_interface",
          ].forEach((childType) => {
            (uci.sections(self.config, childType) || []).forEach((child) => {
              if (!child) return;
              const cid = child[".name"];
              const parentSec = String(child.section || "").trim();
              if (cid && parentSec && !validSectionIds.has(parentSec)) {
                uci.remove(self.config, cid);
              }
            });
          });
        } catch (_e) {}
        return form.Map.prototype.load.call(self);
      });
    };
    tachyonMap.handleSaveApply = EntryPoint.handleSaveApply;

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
      "guest_mode",
      "monitoring",
      "diagnostic",
      "updates",
      "settings",
      "telegram",
    ];

    const tabOrder = ["dashboard"];
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

    const configuredDefaultTab = uci.get(
      UCI_PACKAGE,
      "settings",
      "default_tab",
    );
    const defaultTab =
      configuredDefaultTab && configuredDefaultTab !== "settings"
        ? configuredDefaultTab
        : "dashboard";

    const isTabVisible = (id) => {
      if (id === "settings" || id === "settings:navigation") return true;
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
      if (id === "outbounds" || id === "conditions" || id === "balancers") {
        if (uci.get(UCI_PACKAGE, "settings", "show_tab_section") === "0") {
          return false;
        }
      }
      return uci.get(UCI_PACKAGE, "settings", "show_tab_" + id) !== "0";
    };

    let activeSectionSubTab = "sections";
    let selectSectionSubTabFn = null;
    const gridSectionRegistry = {};

    const subTabToEntityType = {
      sections: "section",
      section: "section",
      conditions: "condition",
      condition: "condition",
      outbounds: "outbound_source",
      outbound_source: "outbound_source",
      balancers: "balancer",
      balancer: "balancer",
      server: "server",
      profile: "profile",
      schedule: "schedule",
    };

    const entityTypeToSubTab = {
      section: "sections",
      condition: "conditions",
      outbound_source: "outbounds",
      balancer: "balancers",
    };

    const openEntityModalDirect = (entityType, targetSid, subTab) => {
      const resolvedSubTab =
        subTab || entityTypeToSubTab[entityType] || activeSectionSubTab;
      const resolvedType =
        subTabToEntityType[entityType] ||
        subTabToEntityType[resolvedSubTab] ||
        entityType;

      try {
        if (typeof ui !== "undefined" && typeof ui.hideModal === "function") {
          ui.hideModal();
        }
      } catch (_e) {
        // ignore
      }

      if (
        ["sections", "conditions", "outbounds", "balancers"].includes(
          resolvedSubTab,
        )
      ) {
        activeSectionSubTab = resolvedSubTab;
        const navSub =
          typeof document !== "undefined"
            ? document.querySelector(
                `.tachyon-sidebar__subitem[data-nav-key="section:${resolvedSubTab}"]`,
              )
            : null;
        if (navSub && typeof navSub.click === "function") {
          navSub.click();
        } else {
          const topTab =
            typeof document !== "undefined"
              ? document.querySelector(
                  '.cbi-tabmenu > li[data-tab="cbi-tachyon-section"] a, .cbi-tabmenu > li[data-tab="section"] a',
                )
              : null;
          if (topTab && typeof topTab.click === "function") {
            topTab.click();
          }
          if (typeof selectSectionSubTabFn === "function") {
            selectSectionSubTabFn(resolvedSubTab);
          }
        }
      }

      if (!targetSid) return;

      const triggerOpen = () => {
        try {
          if (typeof document !== "undefined") {
            const cardEl = document.querySelector(
              `.tachyon-studio-card[data-sid="${targetSid}"]`,
            );
            if (cardEl && typeof cardEl.scrollIntoView === "function") {
              cardEl.scrollIntoView({ behavior: "smooth", block: "center" });
            }
          }
          const ref = gridSectionRegistry[resolvedType];
          if (ref && typeof ref.renderMoreOptionsModal === "function") {
            ref.renderMoreOptionsModal(targetSid);
          }
        } catch (_err) {
          // ignore
        }
      };

      if (
        typeof window !== "undefined" &&
        typeof window.setTimeout === "function"
      ) {
        window.setTimeout(triggerOpen, 30);
      } else {
        triggerOpen();
      }
    };

    if (typeof globalThis !== "undefined") {
      globalThis.__tachyonOpenEntityModal = openEntityModalDirect;
    }

    const selectSectionSubTabExternal = (targetKey, targetSid) => {
      activeSectionSubTab = targetKey;
      if (targetSid) {
        const entityType = subTabToEntityType[targetKey] || targetKey;
        openEntityModalDirect(entityType, targetSid, targetKey);
        return;
      }
      if (typeof selectSectionSubTabFn === "function") {
        selectSectionSubTabFn(targetKey);
      }
    };

    const mountAllStudioDecks = (mapEl) => {
      if (typeof main.mountTachyonStudioDeck !== "function") return;
      const root = mapEl || document;
      const targets = [
        {
          type: "section",
          el:
            root.querySelector(
              '#cbi-tachyon-section .tachyon-section-subpane[data-subtab="sections"]',
            ) || root.querySelector("#cbi-tachyon-section"),
        },
        {
          type: "condition",
          el: root.querySelector("#cbi-tachyon-condition"),
        },
        {
          type: "outbound_source",
          el: root.querySelector("#cbi-tachyon-outbound_source"),
        },
        {
          type: "balancer",
          el: root.querySelector("#cbi-tachyon-balancer"),
        },
        {
          type: "server",
          el: root.querySelector("#cbi-tachyon-server"),
        },
        {
          type: "profile",
          el: root.querySelector("#cbi-tachyon-profile"),
        },
        {
          type: "schedule",
          el: root.querySelector("#cbi-tachyon-schedule"),
        },
      ];
      targets.forEach(({ type, el }) => {
        const ref = gridSectionRegistry[type];
        if (!ref || !el) return;
        const doMount = () => {
          main.mountTachyonStudioDeck({
            type,
            sectionRef: ref,
            containerEl: el,
            onShowSectionRules: (sid) =>
              section && typeof section.showSectionRulesModal === "function"
                ? section.showSectionRulesModal(sid)
                : null,
            onCloneSection: (sid) =>
              section && typeof section.cloneSection === "function"
                ? section.cloneSection(sid)
                : null,
            onNavigateSubTab: selectSectionSubTabExternal,
          });
        };
        ref._refreshStudioDeck = doMount;
        doMount();
      });
    };

    const mountShellOnMap = (mapEl) => {
      if (typeof main.mountTachyonAppShell === "function") {
        main.mountTachyonAppShell({
          mapEl: mapEl || document.getElementById("cbi-tachyon"),
          uiCapabilities,
          onSelectSectionSubTab: selectSectionSubTabExternal,
          getActiveSectionSubTab: () => activeSectionSubTab,
          isTabVisible,
          getTabOrder: () => {
            const raw = uci.get(UCI_PACKAGE, "settings", "tab_order");
            if (Array.isArray(raw)) return raw;
            if (typeof raw === "string" && raw.trim()) {
              return raw.trim().split(/\s+/);
            }
            return tabOrder;
          },
          onReloadMap: () =>
            Promise.resolve(
              typeof tachyonMap.reset === "function"
                ? tachyonMap.reset()
                : tachyonMap
                    .load()
                    .then(() =>
                      typeof tachyonMap.renderContents === "function"
                        ? tachyonMap.renderContents()
                        : tachyonMap.render(),
                    ),
            ).catch(() => null),
        });
      }
    };

    const mountSectionSubTabs = (mapEl) => {
      const root = mapEl || document;
      const secEl = root.querySelector("#cbi-tachyon-section");
      if (!secEl) return;

      const condEl = root.querySelector("#cbi-tachyon-condition");
      const outEl = root.querySelector("#cbi-tachyon-outbound_source");
      const balEl = root.querySelector("#cbi-tachyon-balancer");

      // Remove top-level tab entries for sub-sections so only "Sections" stays in the main navbar
      const stripTopTabs = (scope) => {
        [
          "condition",
          "cbi-tachyon-condition",
          "outbound_source",
          "cbi-tachyon-outbound_source",
          "balancer",
          "cbi-tachyon-balancer",
        ].forEach((tabId) => {
          (scope || document)
            .querySelectorAll(
              `.cbi-tabmenu > li[data-tab="${tabId}"], .cbi-tabmenu > [data-tab="${tabId}"]`,
            )
            .forEach((li) => {
              if (!li.closest(".tachyon-section-subtabs")) {
                li.remove();
              }
            });
        });
      };
      stripTopTabs(root);
      if (typeof window !== "undefined") {
        window.requestAnimationFrame(() => stripTopTabs(document));
        window.setTimeout(() => stripTopTabs(document), 120);
      }

      if (secEl.querySelector(".tachyon-section-subtabs")) {
        return;
      }

      const subTabsDef = [
        { key: "sections", label: _("Sections") },
        { key: "conditions", label: _("Conditions") },
        { key: "outbounds", label: _("Outbounds") },
        { key: "balancers", label: _("Balancers") },
      ];

      const paneSections = E(
        "div",
        {
          class: "tachyon-section-subpane",
          "data-subtab": "sections",
          style: "overflow-x: auto; max-width: 100%;",
        },
        [],
      );
      while (secEl.firstChild) {
        paneSections.appendChild(secEl.firstChild);
      }

      const wrapAuxSection = (key, el) => {
        const pane = E(
          "div",
          {
            class: "tachyon-section-subpane",
            "data-subtab": key,
            style: "display: none; overflow-x: auto; max-width: 100%;",
          },
          [],
        );
        if (el) {
          el.removeAttribute("data-tab");
          el.removeAttribute("data-tab-title");
          el.classList.remove("cbi-tab-disabled");
          el.style.display = "";
          pane.appendChild(el);
        }
        return pane;
      };

      const paneConditions = wrapAuxSection("conditions", condEl);
      const paneOutbounds = wrapAuxSection("outbounds", outEl);
      const paneBalancers = wrapAuxSection("balancers", balEl);

      const panesByKey = {
        sections: paneSections,
        conditions: paneConditions,
        outbounds: paneOutbounds,
        balancers: paneBalancers,
      };

      const tabItems = {};
      const selectSubTab = (targetKey) => {
        activeSectionSubTab = targetKey;
        subTabsDef.forEach(({ key }) => {
          const li = tabItems[key];
          const pane = panesByKey[key];
          const isActive = key === targetKey;
          if (li) {
            li.className = isActive ? "cbi-tab" : "cbi-tab-disabled";
          }
          if (pane) {
            pane.style.display = isActive ? "" : "none";
          }
        });
      };

      const subTabMenu = E(
        "ul",
        {
          class: "cbi-tabmenu tachyon-section-subtabs",
          style: "margin: 0 0 14px 0;",
        },
        subTabsDef.map(({ key, label }) => {
          const li = E(
            "li",
            {
              class:
                key === activeSectionSubTab ? "cbi-tab" : "cbi-tab-disabled",
              "data-subtab": key,
            },
            [
              E(
                "a",
                {
                  href: "#",
                  click: (ev) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    selectSubTab(key);
                  },
                },
                label,
              ),
            ],
          );
          tabItems[key] = li;
          return li;
        }),
      );

      secEl.appendChild(subTabMenu);
      secEl.appendChild(paneSections);
      secEl.appendChild(paneConditions);
      secEl.appendChild(paneOutbounds);
      secEl.appendChild(paneBalancers);

      selectSectionSubTabFn = selectSubTab;
      selectSubTab(activeSectionSubTab);
    };

    const origMapRender = tachyonMap.render;
    tachyonMap.render = function () {
      return origMapRender.apply(this, arguments).then((mapEl) => {
        mountSectionSubTabs(mapEl);
        mountAllStudioDecks(mapEl);
        mountShellOnMap(mapEl);
        return mapEl;
      });
    };

    if (typeof tachyonMap.renderContents === "function") {
      const origRenderContents = tachyonMap.renderContents;
      tachyonMap.renderContents = function () {
        const prevSecEl =
          typeof document !== "undefined"
            ? document.querySelector("#cbi-tachyon-section")
            : null;
        const wasInSectionTab = Boolean(
          prevSecEl && !prevSecEl.classList.contains("cbi-tab-disabled"),
        );
        return origRenderContents.apply(this, arguments).then((mapEl) => {
          mountSectionSubTabs(mapEl);
          mountAllStudioDecks(mapEl);
          mountShellOnMap(mapEl);
          if (wasInSectionTab && typeof document !== "undefined") {
            const root = mapEl || document;
            const secTabLi = root.querySelector(
              '.cbi-tabmenu > li[data-tab="cbi-tachyon-section"], .cbi-tabmenu > li[data-tab="section"]',
            );
            const secTabLink = secTabLi ? secTabLi.querySelector("a") : null;
            if (secTabLink) {
              secTabLink.click();
            }
          }
          return mapEl;
        });
      };
    }

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
        gridSectionRegistry.section = s;
        section.configureSectionSection(s, {
          loadActionProvidersAvailability: loadUiCapabilities,
        });
        section.createSectionContent(s);

        const sCond = tachyonMap.section(
          form.GridSection,
          "condition",
          _("Conditions"),
          _(
            "Reusable atomic traffic conditions and composite boolean rules (AND / OR / NOT) with 2-mode Rule Tracer.",
          ),
        );
        configureGridSection(
          sCond,
          "condition",
          _("Condition"),
          _("Add a condition"),
        );
        gridSectionRegistry.condition = sCond;
        conditions.configureConditionsSection(sCond);
        conditions.createConditionsContent(sCond);

        const sOut = tachyonMap.section(
          form.GridSection,
          "outbound_source",
          _("Outbounds"),
          _(
            "Layer 1: Global Server Pool (subscriptions, proxy share links, network interfaces, JSON outbounds) imported once and shared across all groups and sections.",
          ),
        );
        configureGridSection(
          sOut,
          "outbound_source",
          _("Outbound Source"),
          _("Add an outbound source"),
        );
        gridSectionRegistry.outbound_source = sOut;
        outbounds.configureOutboundsSection(sOut);
        outbounds.createOutboundsContent(sOut);

        const sBal = tachyonMap.section(
          form.GridSection,
          "balancer",
          _("Balancers"),
          _(
            "Reusable URLTest and Priority selection policies decoupled from specific server pools.",
          ),
        );
        configureGridSection(
          sBal,
          "balancer",
          _("Balancer"),
          _("Add a balancer"),
        );
        gridSectionRegistry.balancer = sBal;
        if (typeof balancers.configureBalancersSection === "function") {
          balancers.configureBalancersSection(sBal);
        }
        balancers.createBalancersContent(sBal);

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
        gridSectionRegistry.server = s;
        serverSectionRef = s;
        server.configureServerSubscription(s);
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
        gridSectionRegistry.profile = s;
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
        gridSectionRegistry.schedule = s;
        parental.createParentalContent(s);
        return s;
      },
      guest_mode: () => {
        const s = tachyonMap.section(
          form.TypedSection,
          "guest_mode",
          _("Guest Mode"),
          _(
            "Guest mode isolates guest devices from local LAN and router administration, while allowing internet access with daily quotas and schedules.",
          ),
        );
        s.anonymous = true;
        s.addremove = false;
        s.cfgsections = function () {
          return ["guest_mode"];
        };
        parental.createGuestModeContent(s);
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

    // Instantiate all sections in configured tab order so switching between Simple and Advanced modes works seamlessly
    for (const tabId of tabOrder) {
      if (typeof sectionFactories[tabId] === "function") {
        sectionFactories[tabId]();
      }
    }

    const capabilitiesTask = loadUiCapabilities().catch(() => null);
    await Promise.race([
      capabilitiesTask,
      new Promise((resolve) => window.setTimeout(resolve, 250)),
    ]);

    if (!window.location.hash || window.location.hash === "#") {
      try {
        if (
          typeof L !== "undefined" &&
          L.session &&
          typeof L.session.setLocalData === "function"
        ) {
          L.session.setLocalData("tab", null);
        }
      } catch (_e) {}
    }

    const rendered = await tachyonMap.render();
    if (typeof main.mountLanguageSelector === "function") {
      window.requestAnimationFrame(() => {
        const langSlot = document.querySelector(".tachyon-topbar__lang-slot");
        main.mountLanguageSelector(uiCapabilities, langSlot || undefined);
      });
    }
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

  handleSaveApply: function (ev, mode) {
    const refreshUiState = function () {
      if (
        main.TachyonShellMethods &&
        typeof main.TachyonShellMethods.getUiState === "function"
      ) {
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
      }
    };

    if (main.store && typeof main.store.set === "function") {
      const servicesInfoWidget = main.store.get()?.servicesInfoWidget;
      if (servicesInfoWidget) {
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
    }

    return this.handleSave(ev)
      .then(() => ui.changes.apply(mode == "0"))
      .then((result) => {
        if (
          main.TachyonShellMethods &&
          typeof main.TachyonShellMethods.serviceActionStart === "function"
        ) {
          return main.TachyonShellMethods.serviceActionStart("reload")
            .then(() => {
              window.setTimeout(refreshUiState, 500);
              return result;
            })
            .catch(() => {
              window.setTimeout(refreshUiState, 500);
              return result;
            });
        }
        window.setTimeout(refreshUiState, 500);
        return result;
      })
      .catch((error) => {
        refreshUiState();
        throw error;
      });
  },
};

return view.extend(EntryPoint);
