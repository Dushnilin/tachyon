"use strict";
"require baseclass";
"require fs";
"require ui";

const DEFAULT_DOMAINS = [
  "google.com",
  "youtube.com",
  "facebook.com",
  "instagram.com",
  "chatgpt.com",
  "x.com",
  "whatsapp.com",
  "reddit.com",
  "wikipedia.org",
  "amazon.com",
  "tiktok.com",
  "pinterest.com",
];
const STORAGE_KEY = "tachyon-dns-speed-test-domains";

function normalizeDomains(value) {
  const domains = [];
  for (const item of String(value || "")
    .split(/[\s,;]+/)
    .filter(Boolean)) {
    let domain;
    try {
      const parsed = new URL(item.includes("://") ? item : "https://" + item);
      if (parsed.username || parsed.password) throw new Error();
      domain = parsed.hostname.toLowerCase().replace(/\.$/, "");
    } catch (_error) {
      throw new Error(_("Enter valid domain names, one per line."));
    }
    if (
      domain.length > 253 ||
      !/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(domain) ||
      /^[0-9.]+$/.test(domain) ||
      domain
        .split(".")
        .some(
          (label) =>
            label.length > 63 || label.startsWith("-") || label.endsWith("-"),
        )
    ) {
      throw new Error(_("Enter valid domain names, one per line."));
    }
    if (!domains.includes(domain)) domains.push(domain);
  }
  if (!domains.length || domains.length > 32) {
    throw new Error(_("Choose between 1 and 32 test domains."));
  }
  return domains;
}

function formatMs(value) {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value.toFixed(2) + " " + _("ms")
    : _("Unavailable");
}

function showResult(result) {
  const stats = result.stats;
  const summary = E(
    "div",
    { class: "tachyon-dns-speed-stats" },
    [
      [_("Minimum"), stats.min],
      [_("Median"), stats.median],
      [_("Average"), stats.avg],
      [_("Maximum"), stats.max],
    ].map(([label, value]) =>
      E("div", {}, [E("div", {}, label), E("strong", {}, formatMs(value))]),
    ),
  );
  const rows = result.samples.map((sample) =>
    E("tr", {}, [
      E("td", { style: "overflow-wrap:anywhere;" }, sample.domain),
      E(
        "td",
        { style: "text-align:right;overflow-wrap:anywhere;" },
        sample.ok ? formatMs(sample.ms) : failureLabel(sample),
      ),
    ]),
  );
  ui.showModal(_("DNS speed test results"), [
    E("p", { style: "overflow-wrap:anywhere;" }, result.server),
    summary,
    E(
      "p",
      {},
      _("Successful queries: %s / %s").format(stats.success, stats.total),
    ),
    E(
      "p",
      {},
      _(
        "Failed queries count as 5000 ms in statistics. All times are measured from the router.",
      ),
    ),
    E("table", { class: "tachyon-dns-speed-results" }, [
      E(
        "thead",
        {},
        E("tr", {}, [
          E("th", { scope: "col" }, _("Domain")),
          E(
            "th",
            { scope: "col", style: "text-align:right;width:35%;" },
            _("Ping"),
          ),
        ]),
      ),
      E("tbody", {}, rows),
    ]),
    E(
      "div",
      { class: "right" },
      E(
        "button",
        {
          type: "button",
          class: "cbi-button",
          click: () => ui.hideModal(),
        },
        _("Close"),
      ),
    ),
  ]);
}

function failureLabel(sample) {
  const error = sample.error || {};
  if (error.kind === "transport" && error.code === 28) return _("Timeout");
  if (error.kind === "transport" && error.code === 60)
    return _("TLS certificate error");
  if (error.kind === "transport")
    return _("Connection error: %s").format(error.code);
  if (error.kind === "http") return _("HTTP error: %s").format(error.code);
  if (error.kind === "dns" && error.code > 0)
    return _("DNS error: %s").format(error.code);
  return _("Invalid or missing DNS response");
}

function createController() {
  let domains = [...DEFAULT_DOMAINS];
  try {
    const saved = JSON.parse(
      window.localStorage.getItem(STORAGE_KEY) || "null",
    );
    if (Array.isArray(saved)) domains = normalizeDomains(saved.join("\n"));
  } catch (_error) {
    /* Keep defaults when storage is unavailable or invalid. */
  }
  let results = new Map();
  let listNode = null,
    toolbar = null,
    runButton = null,
    gearButton = null,
    progress = null;
  let running = false,
    timer = null,
    jobId = null;
  let getSelection = null;
  let generation = 0;

  function updateRows() {
    if (!listNode) return;
    listNode.querySelectorAll(".item").forEach((item) => {
      const value = item.querySelector('input[type="hidden"]')?.value;
      if (!value) return;
      let button = item.querySelector(".tachyon-dns-speed-value");
      if (!button) {
        button = E("button", {
          type: "button",
          class: "cbi-button tachyon-dns-speed-value",
        });
        // Stop LuCI DynamicList's click/delete and touch/drag handlers for this control.
        ["click", "touchstart", "keydown", "dragstart"].forEach((name) =>
          button.addEventListener(name, (event) => event.stopPropagation()),
        );
        item.appendChild(button);
      }
      const result = results.get(value);
      button.textContent = result ? formatMs(result.stats.median) : "—";
      button.disabled = !result;
      button.title = result
        ? _("Median; successful queries: %s / %s. Click for details.").format(
            result.stats.success,
            result.stats.total,
          )
        : _("Run the DNS speed test to see results.");
      button.setAttribute(
        "aria-label",
        result
          ? _("DNS speed test results") +
              ": " +
              value +
              ", " +
              button.textContent
          : _("Run the DNS speed test to see results."),
      );
      button.onclick = (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (result) showResult(result);
      };
    });
  }

  function updateControls() {
    if (!runButton) return;
    const protocol = getSelection().protocol;
    runButton.disabled = running || protocol !== "doh";
    gearButton.disabled = running;
    progress.textContent = running
      ? _("Testing selected DNS…")
      : protocol !== "doh"
        ? _("This speed test uses DNS over HTTPS (DoH).")
        : "";
    if (listNode)
      listNode.classList.toggle(
        "tachyon-dns-speed-enabled",
        protocol === "doh",
      );
  }

  async function command(name, args = []) {
    const response =
      name === "dns_speed_test_status"
        ? await fs.exec("/usr/bin/tachyon-read", [name, ...args])
        : await fs.exec("/usr/bin/tachyon", [name, ...args]);
    let data;
    try {
      data = JSON.parse(response.stdout || "{}");
    } catch (_error) {
      throw new Error(_("Unable to read DNS speed test results."));
    }
    if (response.code !== 0 || data.success === false) {
      throw new Error(data.error || _("DNS speed test failed."));
    }
    return data;
  }

  async function poll() {
    const currentGeneration = generation;
    timer = null;
    if (!toolbar?.isConnected) return;
    try {
      const state = await command("dns_speed_test_status");
      if (currentGeneration !== generation) return;
      if (jobId && state.id !== jobId)
        throw new Error(
          _("DNS speed test results have changed. Run the test again."),
        );
      if (JSON.stringify(state.domains) === JSON.stringify(domains)) {
        results = new Map(
          (state.results || []).map((result) => [result.server, result]),
        );
      } else {
        results.clear();
      }
      running = Boolean(state.running);
      updateControls();
      updateRows();
      if (running) {
        jobId = state.id;
        progress.textContent =
          _("Testing selected DNS…") + " " + (state.progress || 0) + "%";
        timer = window.setTimeout(poll, 1000);
      } else if (state.error) {
        progress.textContent = _("DNS speed test failed.");
      }
    } catch (error) {
      running = false;
      updateControls();
      progress.textContent = error.message;
    }
  }

  function configureDomains() {
    const textarea = E(
      "textarea",
      {
        class: "cbi-input-text",
        rows: 12,
        style: "width:100%;box-sizing:border-box;",
        "aria-label": _("Test domains"),
        spellcheck: "false",
      },
      domains.join("\n"),
    );
    const error = E("p", { role: "alert" });
    ui.showModal(_("Test domains"), [
      E(
        "p",
        {},
        _(
          "One domain per line. These settings are saved in this browser and do not change DNS routing.",
        ),
      ),
      textarea,
      error,
      E("div", { class: "right" }, [
        E(
          "button",
          {
            type: "button",
            class: "cbi-button",
            click: () => {
              textarea.value = DEFAULT_DOMAINS.join("\n");
            },
          },
          _("Reset"),
        ),
        " ",
        E(
          "button",
          { type: "button", class: "cbi-button", click: () => ui.hideModal() },
          _("Cancel"),
        ),
        " ",
        E(
          "button",
          {
            type: "button",
            class: "cbi-button cbi-button-positive",
            click: () => {
              try {
                const next = normalizeDomains(textarea.value);
                // A test belongs to its hostname snapshot; changed settings invalidate old numbers.
                if (JSON.stringify(next) !== JSON.stringify(domains))
                  results.clear();
                domains = next;
                try {
                  window.localStorage.setItem(
                    STORAGE_KEY,
                    JSON.stringify(domains),
                  );
                } catch (_storageError) {
                  /* Still usable for this page session. */
                }
                updateRows();
                ui.hideModal();
              } catch (invalid) {
                error.textContent = invalid.message;
              }
            },
          },
          _("Save"),
        ),
      ]),
    ]);
  }

  return {
    renderToolbar(selection) {
      getSelection = selection;
      runButton = E(
        "button",
        {
          type: "button",
          class: "cbi-button cbi-button-action",
          click: async () => {
            const selected = getSelection();
            if (running || selected.protocol !== "doh") return;
            if (!selected.servers.length || selected.servers.length > 8) {
              progress.textContent = _("Choose between 1 and 8 DNS servers.");
              return;
            }
            running = true;
            generation++;
            results.clear();
            updateControls();
            updateRows();
            try {
              const response = await command("dns_speed_test_start", [
                JSON.stringify({ ...selected, domains }),
              ]);
              jobId = response.id;
              if (timer) window.clearTimeout(timer);
              await poll();
            } catch (error) {
              running = false;
              updateControls();
              progress.textContent = error.message;
            }
          },
        },
        _("Test DNS speed"),
      );
      gearButton = E(
        "button",
        {
          type: "button",
          class: "cbi-button",
          title: _("Test domains"),
          "aria-label": _("Test domains"),
          click: configureDomains,
        },
        "⚙",
      );
      progress = E("span", { role: "status", "aria-live": "polite" });
      toolbar = E("div", { class: "tachyon-dns-speed-toolbar" }, [
        runButton,
        gearButton,
        progress,
        E(
          "style",
          {},
          `
          .tachyon-dns-speed-toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem}
          .tachyon-dns-speed-enabled{max-width:calc(100% - 112px)}
          @media(max-width:600px){.tachyon-dns-speed-enabled{min-width:0}.tachyon-dns-speed-enabled .add-item .cbi-dropdown{min-width:0;max-width:100%}}
          .tachyon-dns-speed-list .item{position:relative;overflow:visible}
          .tachyon-dns-speed-value{display:none!important}
          .tachyon-dns-speed-enabled .tachyon-dns-speed-value{display:block!important;position:absolute;left:calc(100% + 10px);top:50%;transform:translateY(-50%);min-width:96px;max-width:102px;font-size:.85rem;white-space:nowrap}
          .tachyon-dns-speed-stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(100px,1fr));gap:1rem;margin:1rem 0}
          .tachyon-dns-speed-results{width:100%;table-layout:fixed;margin:1rem 0;border:1px solid var(--border-color-medium,#666)}
          .tachyon-dns-speed-results th,.tachyon-dns-speed-results td{padding:9px 12px;text-align:left;vertical-align:middle;border-bottom:1px solid var(--border-color-low,#555)}
          .tachyon-dns-speed-results th{background:var(--background-color-low,#333)}
          .tachyon-dns-speed-results tbody tr:nth-child(even){background:var(--background-color-medium,#292929)}
          .tachyon-dns-speed-results td:last-child{font-variant-numeric:tabular-nums}
        `,
        ),
      ]);
      updateControls();
      window.setTimeout(poll, 0);
      return toolbar;
    },
    attachList(node) {
      listNode = node;
      node.classList.add("tachyon-dns-speed-list");
      node.addEventListener("cbi-dynlist-change", updateRows);
      new MutationObserver(() => updateRows()).observe(node, {
        childList: true,
      });
      updateControls();
      updateRows();
    },
    refresh: updateControls,
  };
}

return baseclass.extend({ createController, normalizeDomains, formatMs });
