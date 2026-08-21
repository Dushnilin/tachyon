"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require view.tachyon.main as main";
"require view.tachyon.local_devices as local_devices";

const UCI_PACKAGE = "tachyon";

const DAY_LABELS = {
  monday: _("Monday"),
  tuesday: _("Tuesday"),
  wednesday: _("Wednesday"),
  thursday: _("Thursday"),
  friday: _("Friday"),
  saturday: _("Saturday"),
  sunday: _("Sunday"),
};

const DAY_SHORT_LABELS = {
  monday: _("Mon"),
  tuesday: _("Tue"),
  wednesday: _("Wed"),
  thursday: _("Thu"),
  friday: _("Fri"),
  saturday: _("Sat"),
  sunday: _("Sun"),
};

const DAY_INDEX_MAP = {
  0: "sunday",
  1: "monday",
  2: "tuesday",
  3: "wednesday",
  4: "thursday",
  5: "friday",
  6: "saturday",
};

const DOMAIN_PRESETS = {
  social: {
    label: _("Social media"),
    icon: "📱",
    domains: [
      "facebook.com", "instagram.com", "tiktok.com", "twitter.com", "x.com",
      "vk.com", "snapchat.com", "reddit.com", "discord.com", "discord.gg",
      "twitch.tv", "pinterest.com", "telegram.org", "t.me", "whatsapp.com",
      "signal.org", "wechat.com", "youtube.com", "tumblr.com",
    ],
  },
  video: {
    label: _("Video streaming"),
    icon: "🎬",
    domains: [
      "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
      "netflix.com", "primevideo.com", "hulu.com", "disneyplus.com",
      "hbomax.com", "okko.tv", "ivi.ru", "kinopoisk.ru",
      "twitch.tv", "vimeo.com", "dailymotion.com", "rutube.ru",
    ],
  },
  gaming: {
    label: _("Gaming"),
    icon: "🎮",
    domains: [
      "steampowered.com", "steamcommunity.com", "epicgames.com",
      "roblox.com", "fortnite.com", "xbox.com", "playstation.com",
      "battle.net", "ea.com", "ubisoft.com", "riotgames.com",
      "minecraft.net", "origin.com", "discord.com", "discord.gg",
    ],
  },
  adult: {
    label: _("Adult content"),
    icon: "🔞",
    domains: [
      "pornhub.com", "xvideos.com", "xhamster.com", "xnxx.com",
      "onlyfans.com", "stripchat.com", "chaturbate.com",
      "youporn.com", "redtube.com", "tubegalore.com",
      "porntrex.com", "pornhd.com", "nudevista.com",
      "porn.com", "spankbang.com", "eporner.com",
    ],
  },
  messengers: {
    label: _("Messengers"),
    icon: "💬",
    domains: [
      "telegram.org", "t.me", "whatsapp.com", "wa.me", "viber.com",
      "signal.org", "wechat.com", "qq.com", "icq.com", "discord.com",
      "discord.gg", "skype.com", "zoom.us", "slack.com", "teams.microsoft.com",
    ],
  },
  shopping: {
    label: _("Shopping"),
    icon: "🛒",
    domains: [
      "amazon.com", "ebay.com", "aliexpress.com", "ozon.ru",
      "wildberries.ru", "wb.ru", "yandex.market", "market.yandex.ru",
      "avito.ru", "lamoda.ru", "shein.com", "temu.com", "wish.com",
    ],
  },
};

function validateTime(sectionId, value) {
  if (!value) {
    return _("Time is required (e.g. 22:00)");
  }
  const str = `${value}`.trim();
  if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(str)) {
    return _("Invalid time format. Expected HH:MM (e.g. 22:00)");
  }
  return true;
}

function normalizeDays(raw) {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw.map((d) => `${d}`.toLowerCase().trim()).filter(Boolean);
  return `${raw}`.split(/\s+/).map((d) => d.toLowerCase().trim()).filter(Boolean);
}

function normalizeListValues(raw) {
  if (!raw) return [];
  if (Array.isArray(raw)) return raw.map((item) => `${item}`.trim()).filter(Boolean);
  return `${raw}`.split(/\s+/).map((item) => item.trim()).filter(Boolean);
}

function isScheduleCurrentlyActive(sectionId) {
  const enabled = uci.get(UCI_PACKAGE, sectionId, "enabled") !== "0";
  if (!enabled) return false;

  const startTime = uci.get(UCI_PACKAGE, sectionId, "start_time") || "00:00";
  const endTime = uci.get(UCI_PACKAGE, sectionId, "end_time") || "23:59";
  const rawDays = uci.get(UCI_PACKAGE, sectionId, "days");
  const days = normalizeDays(rawDays);

  const now = new Date();
  const currentDay = DAY_INDEX_MAP[now.getDay()];

  if (days.length > 0 && days.length < 7 && !days.includes(currentDay)) {
    return false;
  }

  const currentMinutes = now.getHours() * 60 + now.getMinutes();

  const [sH, sM] = startTime.split(":").map(Number);
  const [eH, eM] = endTime.split(":").map(Number);
  const startMinutes = (sH || 0) * 60 + (sM || 0);
  const endMinutes = (eH || 0) * 60 + (eM || 0);

  if (startMinutes > endMinutes) {
    // Crosses midnight, e.g. 22:00 -> 08:00
    return currentMinutes >= startMinutes || currentMinutes <= endMinutes;
  }

  return currentMinutes >= startMinutes && currentMinutes <= endMinutes;
}

function formatDaysDisplay(rawDays) {
  const days = normalizeDays(rawDays);
  if (!days || days.length === 0 || days.length === 7) {
    return _("Every day");
  }

  const weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday"];
  const weekends = ["saturday", "sunday"];

  const isWeekdays =
    days.length === 5 && weekdays.every((d) => days.includes(d));
  if (isWeekdays) return _("Weekdays (Mon-Fri)");

  const isWeekends =
    days.length === 2 && weekends.every((d) => days.includes(d));
  if (isWeekends) return _("Weekends (Sat-Sun)");

  return days.map((d) => DAY_SHORT_LABELS[d] || d).join(", ");
}

function validateDevice(sectionId, value) {
  if (!value) return true;
  const str = `${value}`.trim();
  if (main.validateIP(str).valid) return true;
  if (/^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/.test(str)) return true;
  return _("Invalid IP or MAC address. Expected e.g. 192.168.1.150 or AA:BB:CC:DD:EE:FF");
}

function createParentalContent(section) {
  // Enabled switch
  let o = section.option(form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "5rem";

  // Device column in table
  o = section.option(form.DummyValue, "_device_display", _("Device / IP / MAC"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const rawIp = uci.get(UCI_PACKAGE, sectionId, "device_ip");
    const devs = normalizeListValues(rawIp);
    if (devs.length === 0) {
      return '<span style="opacity:0.5;">' + _("All devices") + "</span>";
    }
    const isMacAddr = (dev) =>
      /^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$/.test(dev);
    const macs = devs.filter(isMacAddr);
    const ips = devs.filter((d) => !isMacAddr(d));
    const badges = [...macs, ...ips]
      .map((dev) => {
        const isMac = isMacAddr(dev);
        const bg = isMac ? "#2d3748" : "#2a3441";
        const color = isMac ? "#b794f4" : "#63b3ed";
        const label = isMac ? "MAC" : "IP";
        return (
          `<span class="badge" style="background:${bg};color:${color};padding:3px 8px;border-radius:6px;font-size:11px;font-family:monospace;margin-right:4px;font-weight:600;display:inline-block;margin-bottom:2px;border:1px solid ${color}44;">` +
          `<span style="opacity:0.75;font-weight:700;margin-right:3px;">${label}:</span>` +
          dev +
          "</span>"
        );
      })
      .join("");
    return "<div>" + badges + "</div>";
  };
  o.textvalue = function (sectionId) {
    const devs = normalizeListValues(uci.get(UCI_PACKAGE, sectionId, "device_ip"));
    return devs.length === 0 ? _("All devices") : devs.join(", ");
  };

  // Target column in table
  o = section.option(form.DummyValue, "_target_display", _("Target"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const target = uci.get(UCI_PACKAGE, sectionId, "target") || "all";
    if (target === "all") {
      return '<span style="color:#fc8181;font-weight:600;">🚫 ' + _("All Internet") + "</span>";
    }
    const rawSecs = uci.get(UCI_PACKAGE, sectionId, "sections");
    const secNames = normalizeListValues(rawSecs);
    if (secNames.length === 0 && target !== "sections") {
      secNames.push(target);
    }
    if (secNames.length === 0) {
      return '<span style="opacity:0.6;">' + _("No sections selected") + "</span>";
    }
    const badges = secNames
      .map((name) => {
        const sec = uci.get(UCI_PACKAGE, name);
        const label = (sec && (sec.label || sec[".name"])) || name;
        return (
          '<span class="badge" style="background:#2d3748;color:#f6ad55;padding:2px 6px;border-radius:4px;font-size:11px;margin-right:4px;border:1px solid rgba(246,173,85,0.3);display:inline-block;margin-bottom:2px;">🔒 ' +
          label +
          "</span>"
        );
      })
      .join("");
    return "<div>" + badges + "</div>";
  };
  o.textvalue = function (sectionId) {
    const target = uci.get(UCI_PACKAGE, sectionId, "target") || "all";
    if (target === "all") return _("All Internet");
    const secNames = normalizeListValues(uci.get(UCI_PACKAGE, sectionId, "sections"));
    return secNames.length === 0 ? _("No sections selected") : secNames.join(", ");
  };

  // Action column in table
  o = section.option(form.DummyValue, "_action_display", _("Mode"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const action = uci.get(UCI_PACKAGE, sectionId, "action") || "block";
    if (action === "allow") {
      return '<span style="color:#68d391;font-weight:500;">✅ ' + _("Allow in interval") + "</span>";
    }
    return '<span style="color:#fc8181;font-weight:500;">🚫 ' + _("Block in interval") + "</span>";
  };
  o.textvalue = function (sectionId) {
    const action = uci.get(UCI_PACKAGE, sectionId, "action") || "block";
    return action === "allow" ? _("Allow in interval") : _("Block in interval");
  };

  // Schedule column in table
  o = section.option(form.DummyValue, "_schedule_display", _("Schedule"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const s = uci.get(UCI_PACKAGE, sectionId, "start_time") || "00:00";
    const e = uci.get(UCI_PACKAGE, sectionId, "end_time") || "23:59";
    const days = formatDaysDisplay(uci.get(UCI_PACKAGE, sectionId, "days"));
    return (
      '<div style="line-height:1.3;"><strong style="color:var(--text-color, #fff);">' +
      s +
      " — " +
      e +
      '</strong><br><small style="opacity:0.7;">' +
      days +
      "</small></div>"
    );
  };
  o.textvalue = function (sectionId) {
    const s = uci.get(UCI_PACKAGE, sectionId, "start_time") || "00:00";
    const e = uci.get(UCI_PACKAGE, sectionId, "end_time") || "23:59";
    const days = formatDaysDisplay(uci.get(UCI_PACKAGE, sectionId, "days"));
    return `${s} - ${e}, ${days}`;
  };

  // Blocked sites column in table
  o = section.option(form.DummyValue, "_sites_display", _("Blocked Sites"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const domains = normalizeListValues(uci.get(UCI_PACKAGE, sectionId, "blocked_domains"));
    const mode = uci.get(UCI_PACKAGE, sectionId, "mode") || "block";
    if (domains.length === 0) {
      return '<span style="opacity:0.5;">' + _("None") + "</span>";
    }
    const modeBadge =
      mode === "allow"
        ? '<span style="color:#68d391;font-weight:600;">🟢 ' + _("Allow only") + "</span>"
        : '<span style="color:#fc8181;font-weight:600;">🚫 ' + _("Block") + "</span>";
    const badges = domains
      .map(
        (d) =>
          '<span class="badge" style="background:#2d3748;color:#f687b3;padding:2px 6px;border-radius:4px;font-size:11px;font-family:monospace;margin-right:4px;border:1px solid rgba(246,135,179,0.3);display:inline-block;margin-bottom:2px;">' +
          d +
          "</span>",
      )
      .join("");
    return "<div>" + modeBadge + "<br>" + badges + "</div>";
  };
  o.textvalue = function (sectionId) {
    const domains = normalizeListValues(uci.get(UCI_PACKAGE, sectionId, "blocked_domains"));
    const mode = uci.get(UCI_PACKAGE, sectionId, "mode") || "block";
    if (domains.length === 0) return _("None");
    return (mode === "allow" ? _("Allow only: ") : _("Block: ")) + domains.join(", ");
  };

  // Live status badge in table
  o = section.option(form.DummyValue, "_live_status", _("Status"));
  o.rawhtml = true;
  o.modalonly = false;
  o.cfgvalue = function (sectionId) {
    const enabled = uci.get(UCI_PACKAGE, sectionId, "enabled") !== "0";
    if (!enabled) {
      return (
        '<span style="display:inline-flex;align-items:center;padding:2px 8px;border-radius:12px;font-size:11px;background:#4a5568;color:#e2e8f0;">' +
        '<span style="width:6px;height:6px;border-radius:50%;background:#a0aec0;margin-right:5px;display:inline-block;"></span>' +
        _("Disabled") +
        "</span>"
      );
    }
    const active = isScheduleCurrentlyActive(sectionId);
    const action = uci.get(UCI_PACKAGE, sectionId, "action") || "block";
    if (active) {
      const color = action === "allow" ? "#48bb78" : "#e53e3e";
      const bg = action === "allow" ? "rgba(72,187,120,0.2)" : "rgba(229,62,62,0.2)";
      const border = action === "allow" ? "rgba(72,187,120,0.4)" : "rgba(229,62,62,0.4)";
      const text = action === "allow" ? _("Active (Allowed)") : _("Active (Blocking)");
      return (
        `<span style="display:inline-flex;align-items:center;padding:2px 8px;border-radius:12px;font-size:11px;background:${bg};color:${color};border:1px solid ${border};">` +
        `<span style="width:6px;height:6px;border-radius:50%;background:${color};margin-right:5px;box-shadow:0 0 6px ${color};display:inline-block;"></span>` +
        text +
        "</span>"
      );
    }
    return (
      '<span style="display:inline-flex;align-items:center;padding:2px 8px;border-radius:12px;font-size:11px;background:rgba(74,85,104,0.3);color:#a0aec0;border:1px solid rgba(74,85,104,0.3);">' +
      '<span style="width:6px;height:6px;border-radius:50%;background:#718096;margin-right:5px;display:inline-block;"></span>' +
      _("Pending") +
      "</span>"
    );
  };
  o.textvalue = function (sectionId) {
    const enabled = uci.get(UCI_PACKAGE, sectionId, "enabled") !== "0";
    if (!enabled) return _("Disabled");
    const active = isScheduleCurrentlyActive(sectionId);
    const action = uci.get(UCI_PACKAGE, sectionId, "action") || "block";
    if (active) return action === "allow" ? _("Active (Allowed)") : _("Active (Blocking)");
    return _("Pending");
  };

  // ─── Modal only configuration options ──────────────────────────────────────

  // Label / Rule name (Modal only)
  o = section.option(form.Value, "label", _("Rule Name"));
  o.modalonly = true;
  o.rmempty = true;
  o.placeholder = _("e.g. Kids Phone (Night YouTube)");

  // Device selector with LAN hostnames integration
  o = section.option(
    form.DynamicList,
    "device_ip",
    _("Target Devices (IP / MAC)"),
    _("Select LAN devices to apply this schedule to, or enter IP or MAC addresses manually. MAC addresses (e.g. AA:BB:CC:DD:EE:FF) work even if the device's IP changes. IP addresses (e.g. 192.168.1.150) are used for DNS-level blocking and require a stable lease."),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.placeholder = "192.168.1.150 or AA:BB:CC:DD:EE:FF";
  o.validate = validateDevice;
  o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    return local_devices.createLocalDeviceDynamicListWidget(
      this,
      sectionId,
      cfgvalue,
    );
  };

  // Target Type selector
  o = section.option(
    form.ListValue,
    "target",
    _("Target Scope"),
    _("Choose whether to restrict the entire internet or only specific Tachyon routing sections."),
  );
  o.modalonly = true;
  o.default = "all";
  o.value("all", _("All Internet (Complete internet cutoff)"));
  o.value("sections", _("Specific Sections (Select sections below)"));

  // Multi-select for sections
  o = section.option(
    form.MultiValue,
    "sections",
    _("Select Sections"),
    _("Choose which routing sections to apply this schedule to."),
  );
  o.modalonly = true;
  o.depends("target", "sections");
  o.load = function (sectionId) {
    this.keylist = [];
    this.vallist = [];
    const secList = uci.sections(UCI_PACKAGE, "section") || [];
    secList.forEach((s) => {
      const sName = s[".name"];
      const sLabel = s.label ? `${s.label} (${s.action || "rule"})` : sName;
      this.value(sName, sLabel);
    });
    return form.MultiValue.prototype.load.apply(this, [sectionId]);
  };

  // Action Mode (Block vs Allow)
  o = section.option(
    form.ListValue,
    "action",
    _("Action Mode"),
    _("Select whether to disable the target during the schedule or enable it ONLY during the schedule."),
  );
  o.modalonly = true;
  o.default = "block";
  o.value("block", _("Block / Disable in scheduled hours (Standard)"));
  o.value("allow", _("Allow / Enable ONLY in scheduled hours (White period)"));

  // Start Time
  o = section.option(
    form.Value,
    "start_time",
    _("Start Time (HH:MM)"),
    _("Beginning of the schedule interval (e.g. 22:00)"),
  );
  o.modalonly = true;
  o.default = "22:00";
  o.placeholder = "22:00";
  o.validate = validateTime;

  // End Time
  o = section.option(
    form.Value,
    "end_time",
    _("End Time (HH:MM)"),
    _("End of the schedule interval (e.g. 08:00). Supports spans crossing midnight."),
  );
  o.modalonly = true;
  o.default = "08:00";
  o.placeholder = "08:00";
  o.validate = validateTime;

  // Days of week
  o = section.option(
    form.MultiValue,
    "days",
    _("Days of Week"),
    _("Select active days. If none selected, the rule applies every day."),
  );
  o.modalonly = true;
  o.rmempty = true;
  Object.entries(DAY_LABELS).forEach(([key, label]) => {
    o.value(key, label);
  });

  // ─── Content blocking (domains) ────────────────────────────────────────────

  // Blocked domains with quick presets
  o = section.option(
    form.TextValue,
    "blocked_domains",
    _("Blocked Sites (Domains)"),
    _("Domains to block for the selected devices. Leave empty to block all internet. Enter one domain per line, e.g. youtube.com. Use the preset buttons to quickly add common categories."),
  );
  o.modalonly = true;
  o.rmempty = true;
  o.rows = 6;
  o.wrap = "soft";
  o.textarea = true;
  o.placeholder = "youtube.com\ngooglevideo.com";
  o.validate = function (sectionId, value) {
    if (!value) return true;
    const lines = `${value}`.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    for (const line of lines) {
      const clean = line.replace(/^(full:|keyword:|regex:)/, "");
      if (/^(full:|keyword:|regex:)/.test(line) && !clean) {
        return _("Invalid domain: empty prefix value");
      }
      if (/^regex:/.test(line)) continue;
      if (!/^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/.test(clean)) {
        return _("Invalid domain: " + line);
      }
    }
    return true;
  };
  o.write = function (sectionId, value) {
    const lines = `${value || ""}`.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const existingList = normalizeListValues(uci.get(UCI_PACKAGE, sectionId, "blocked_domains"));
    for (const d of lines) {
      if (!existingList.includes(d)) {
        uci.add_list(UCI_PACKAGE, sectionId, "blocked_domains", d);
      }
    }
    for (const d of existingList) {
      if (!lines.includes(d)) {
        uci.remove_list(UCI_PACKAGE, sectionId, "blocked_domains", d);
      }
    }
  };
  o.load = function (sectionId) {
    return normalizeListValues(uci.get(UCI_PACKAGE, sectionId, "blocked_domains")).join("\n");
  };
  o.remove = function (sectionId) {
    uci.unset(UCI_PACKAGE, sectionId, "blocked_domains");
  };
  o.renderWidget = function (sectionId, optionIndex, cfgvalue) {
    const container = E("div", { style: "width:100%;" });

    // Preset buttons row
    const presetRow = E("div", { style: "margin-bottom:6px;display:flex;flex-wrap:wrap;gap:4px;" });
    Object.entries(DOMAIN_PRESETS).forEach(([key, preset]) => {
      const btn = E(
        "button",
        {
          class: "cbi-button cbi-button-neutral",
          type: "button",
          style: "padding:2px 8px;font-size:11px;",
          title: preset.domains.join(", "),
        },
        preset.icon + " " + preset.label,
      );
      btn.addEventListener("click", function () {
        const textarea = container.querySelector("textarea");
        if (!textarea) return;
        const current = textarea.value.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
        const merged = current.slice();
        for (const d of preset.domains) {
          if (!merged.includes(d)) merged.push(d);
        }
        textarea.value = merged.join("\n");
      });
      presetRow.appendChild(btn);
    });
    container.appendChild(presetRow);

    const textarea = E("textarea", {
      id: `cbid.tachyon.${sectionId}.blocked_domains`,
      class: "cbi-input-textarea",
      style: "width:100%;min-height:110px;",
      placeholder: "youtube.com\ngooglevideo.com",
    });
    if (cfgvalue) textarea.value = cfgvalue;
    container.appendChild(textarea);
    return container;
  };

  // Content mode: block listed vs allow only listed (whitelist)
  o = section.option(
    form.ListValue,
    "mode",
    _("Content Mode"),
    _("Block: deny the listed sites. Allow only (whitelist): deny everything except the listed sites. Whitelist mode requires DNS-level blocking and applies to the schedule window."),
  );
  o.modalonly = true;
  o.default = "block";
  o.value("block", _("Block listed sites (Standard)"));
  o.value("allow", _("Allow only listed sites (Whitelist)"));

  // DNS-level blocking
  o = section.option(
    form.Flag,
    "dns_level",
    _("Block at DNS level"),
    _("Return NXDOMAIN for blocked domains (recommended). When enabled, blocked domains are not resolved at all. When disabled, only direct connections are rejected."),
  );
  o.modalonly = true;
  o.default = "1";
  o.rmempty = false;

  // Telegram notification
  o = section.option(
    form.Flag,
    "notify",
    _("Notify in Telegram"),
    _("Send a Telegram notification to admins when a blocked site is accessed. Requires the Telegram bot to be enabled."),
  );
  o.modalonly = true;
  o.default = "0";
  o.rmempty = false;
}

const EntryPoint = {
  createParentalContent,
};

return baseclass.extend(EntryPoint);
