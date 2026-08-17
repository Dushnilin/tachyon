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

function createParentalContent(section) {
  // Enabled switch
  let o = section.option(form.Flag, "enabled", _("Enable"));
  o.default = "1";
  o.rmempty = false;
  o.editable = true;
  o.width = "5rem";

  // Label / Rule name (Grid column + modal)
  o = section.option(form.Value, "label", _("Rule Name"));
  o.modalonly = false;
  o.rmempty = false;
  o.validate = function (sectionId, value) {
    return value && `${value}`.trim().length > 0 ? true : _("Rule name is required");
  };
  o.placeholder = _("e.g. Kids Phone (Night YouTube)");

  // Device column in table
  o = section.option(form.DummyValue, "_device_display", _("Device / IP"));
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const rawIp = uci.get(UCI_PACKAGE, sectionId, "device_ip");
    const ips = Array.isArray(rawIp) ? rawIp : [rawIp].filter(Boolean);
    if (ips.length === 0) return `<span style="opacity:0.5;">${_("All devices")}</span>`;
    return ips.map((ip) => `<span class="badge" style="background:#2a3441;color:#63b3ed;padding:3px 8px;border-radius:6px;font-size:11px;font-family:monospace;margin-right:4px;font-weight:600;">${ip}</span>`).join(" ");
  };

  // Target column in table
  o = section.option(form.DummyValue, "_target_display", _("Target"));
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const target = uci.get(UCI_PACKAGE, sectionId, "target") || "all";
    if (target === "all") {
      return `<span style="color:#fc8181;font-weight:600;">🚫 ${_("All Internet")}</span>`;
    }
    const rawSecs = uci.get(UCI_PACKAGE, sectionId, "sections");
    const secNames = normalizeListValues(rawSecs);
    if (secNames.length === 0 && target !== "sections") {
      secNames.push(target);
    }
    if (secNames.length === 0) {
      return `<span style="opacity:0.6;">${_("No sections selected")}</span>`;
    }
    return secNames.map((name) => {
      const sec = uci.get(UCI_PACKAGE, name);
      const label = (sec && (sec.label || sec[".name"])) || name;
      return `<span class="badge" style="background:#2d3748;color:#f6ad55;padding:2px 6px;border-radius:4px;font-size:11px;margin-right:4px;border:1px solid rgba(246,173,85,0.3);">🔒 ${label}</span>`;
    }).join(" ");
  };

  // Action column in table
  o = section.option(form.DummyValue, "_action_display", _("Mode"));
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const action = uci.get(UCI_PACKAGE, sectionId, "action") || "block";
    if (action === "allow") {
      return `<span style="color:#68d391;font-weight:500;">✅ ${_("Allow in interval")}</span>`;
    }
    return `<span style="color:#fc8181;font-weight:500;">🚫 ${_("Block in interval")}</span>`;
  };

  // Schedule column in table
  o = section.option(form.DummyValue, "_schedule_display", _("Schedule"));
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const s = uci.get(UCI_PACKAGE, sectionId, "start_time") || "00:00";
    const e = uci.get(UCI_PACKAGE, sectionId, "end_time") || "23:59";
    const days = formatDaysDisplay(uci.get(UCI_PACKAGE, sectionId, "days"));
    return `<div style="line-height:1.3;"><strong style="color:var(--text-color, #fff);">${s} — ${e}</strong><br><small style="opacity:0.7;">${days}</small></div>`;
  };

  // Live status badge in table
  o = section.option(form.DummyValue, "_live_status", _("Status"));
  o.modalonly = false;
  o.rawhtml = true;
  o.cfgvalue = function (sectionId) {
    const enabled = uci.get(UCI_PACKAGE, sectionId, "enabled") !== "0";
    if (!enabled) {
      return `<span style="display:inline-flex;align-items:center;padding:2px 8px;border-radius:12px;font-size:11px;background:#4a5568;color:#e2e8f0;">⏸ ${_("Disabled")}</span>`;
    }
    const active = isScheduleCurrentlyActive(sectionId);
    const action = uci.get(UCI_PACKAGE, sectionId, "action") || "block";
    if (active) {
      const color = action === "allow" ? "#48bb78" : "#e53e3e";
      const text = action === "allow" ? _("Active (Allowed)") : _("Active (Blocking)");
      return `<span style="display:inline-flex;align-items:center;padding:2px 8px;border-radius:12px;font-size:11px;background:rgba(${action === "allow" ? "72,187,120" : "229,62,62"},0.2);color:${color};border:1px solid rgba(${action === "allow" ? "72,187,120" : "229,62,62"},0.4);"><span style="width:6px;height:6px;border-radius:50%;background:${color};margin-right:5px;box-shadow:0 0 6px ${color};"></span>${text}</span>`;
    }
    return `<span style="display:inline-flex;align-items:center;padding:2px 8px;border-radius:12px;font-size:11px;background:rgba(74,85,104,0.3);color:#a0aec0;border:1px solid rgba(74,85,104,0.3);"><span style="width:6px;height:6px;border-radius:50%;background:#718096;margin-right:5px;"></span>${_("Pending")}</span>`;
  };

  // ─── Modal only configuration options ──────────────────────────────────────

  // Device selector with LAN hostnames integration
  o = section.option(
    form.DynamicList,
    "device_ip",
    _("Target Devices (IP / Hostname)"),
    _("Select LAN devices to apply this schedule to, or enter IP addresses manually."),
  );
  o.modalonly = true;
  o.rmempty = false;
  o.placeholder = "192.168.1.150";
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
}

const EntryPoint = {
  createParentalContent,
};

return baseclass.extend(EntryPoint);
