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
  sectionRef.modaltitle = function (section_id) {
    const label =
      uci.get(UCI_PACKAGE, section_id, "label") ||
      uci.get(UCI_PACKAGE, section_id, "name");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return (
      uci.get(UCI_PACKAGE, section_id, "label") ||
      uci.get(UCI_PACKAGE, section_id, "name") ||
      section_id
    );
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    const origRemove = sectionRef.remove;
    sectionRef.remove = function (section_id) {
      if (section && typeof section.cascadeDeleteSection === "function") {
        section.cascadeDeleteSection(section_id);
      }
      return origRemove
        ? origRemove.apply(this, arguments)
        : form.GridSection.prototype.remove.apply(this, arguments);
    };

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
              Promise.resolve(sectionRef.map.load())
                .then(() => sectionRef.map.render())
                .catch(() => null);
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
        main.mountLanguageSelector(uiCapabilities);
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
          (uci.sections(self.config, "section") || []).forEach((sec) => {
            const sname = sec[".name"];
            if (!sname) return;
            const safeSname = String(sname).replace(/[^A-Za-z0-9_]/g, "_");
            const dispName = sec.name || sname;
            const sAct = (sec.action || "connection").toLowerCase();

            if (sec.access_token || sAct === "fptn") {
              const fid = `src_fptn_${safeSname}`;
              if (!uci.get(self.config, fid) && sec.access_token) {
                uci.add(self.config, "outbound_source", fid);
                uci.set(self.config, fid, "enabled", "1");
                uci.set(self.config, fid, "name", dispName);
                uci.set(self.config, fid, "source_type", "fptn");
                uci.set(self.config, fid, "access_token", sec.access_token);
              }
              if (uci.get(self.config, fid)) ensureSourceRef(sname, fid);
            }

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

            const amn = toArr(
              sec.selector_amnezia_configs || sec.amnezia_configs,
            );
            if (amn.length || sec.amnezia_conf_text) {
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

            if (
              sAct === "awg" ||
              (sec.awg_private_key && sec.awg_server_address)
            ) {
              const wid = `src_awg_${safeSname}`;
              if (!uci.get(self.config, wid)) {
                uci.add(self.config, "outbound_source", wid);
                uci.set(self.config, wid, "enabled", "1");
                uci.set(self.config, wid, "name", `${dispName} (AWG)`);
                uci.set(self.config, wid, "source_type", "awg");
                [
                  "awg_private_key",
                  "awg_server_address",
                  "awg_server_port",
                  "awg_peer_public_key",
                  "awg_preshared_key",
                  "awg_local_address",
                ].forEach((k) => {
                  if (sec[k]) uci.set(self.config, wid, k, sec[k]);
                });
              }
              ensureSourceRef(sname, wid);
            }

            if (singleProtoActions.includes(sAct)) {
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

          const existingBalancers = uci.sections(self.config, "balancer") || [];
          (uci.sections(self.config, "urltest") || []).forEach((ut, idx) => {
            const parentSec = ut.section;
            const utName = ut.name || ut[".name"] || `urltest_${idx + 1}`;
            if (!parentSec) return;
            const safeSuffix = String(utName).replace(/[^A-Za-z0-9_]/g, "_");
            const balId = `bal_${parentSec}_${safeSuffix || idx + 1}`;
            const found = existingBalancers.find(
              (b) =>
                b[".name"] === balId ||
                (b.name === utName &&
                  toArr(
                    uci.get(self.config, parentSec, "balancer_refs"),
                  ).includes(b[".name"])),
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

          // Ensure every section's balancers have source_refs populated if empty
          (uci.sections(self.config, "section") || []).forEach((sec) => {
            const sname = sec[".name"];
            if (!sname) return;
            const secSrcRefs = toArr(
              uci.get(self.config, sname, "outbound_source_refs"),
            );
            if (!secSrcRefs.length) return;
            toArr(uci.get(self.config, sname, "balancer_refs")).forEach(
              (bRef) => {
                const curBRefs = toArr(
                  uci.get(self.config, bRef, "source_refs"),
                );
                if (curBRefs.length === 0 && uci.get(self.config, bRef)) {
                  uci.set(self.config, bRef, "source_refs", secSrcRefs);
                }
              },
            );
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

    let activeSectionSubTab = "sections";

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

      selectSubTab(activeSectionSubTab);
    };

    const origMapRender = tachyonMap.render;
    tachyonMap.render = function () {
      return origMapRender.apply(this, arguments).then((mapEl) => {
        mountSectionSubTabs(mapEl);
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

    // Instantiate enabled sections in configured tab order
    for (const tabId of tabOrder) {
      if (
        isTabVisible(tabId) &&
        typeof sectionFactories[tabId] === "function"
      ) {
        sectionFactories[tabId]();
      }
    }

    const capabilitiesTask = loadUiCapabilities().catch(() => null);
    await Promise.race([
      capabilitiesTask,
      new Promise((resolve) => window.setTimeout(resolve, 250)),
    ]);

    const rendered = await tachyonMap.render();
    if (typeof main.mountLanguageSelector === "function") {
      window.requestAnimationFrame(() => {
        main.mountLanguageSelector(uiCapabilities);
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
