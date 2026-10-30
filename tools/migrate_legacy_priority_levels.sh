#!/bin/sh
# ==============================================================================
# Tachyon: Миграция устаревших уровней каскада (priority_level) в Outbound Groups
# Репозиторий: https://github.com/lQwestl/tachyon
#
# Использование на роутере:
#   wget -qO- https://raw.githubusercontent.com/lQwestl/tachyon/main/tools/migrate_legacy_priority_levels.sh | sh
# или:
#   curl -fsSL https://raw.githubusercontent.com/lQwestl/tachyon/main/tools/migrate_legacy_priority_levels.sh | sh
# ==============================================================================

set -e

CONFIG_FILE="/etc/config/tachyon"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Ошибка: Файл конфигурации $CONFIG_FILE не найден."
    echo "Убедитесь, что Tachyon установлен на этом роутере."
    exit 1
fi

if [ ! -x "/usr/bin/ucode" ]; then
    echo "❌ Ошибка: Интерпретатор /usr/bin/ucode не найден."
    exit 1
fi

BACKUP_FILE="${CONFIG_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "📦 Создана резервная копия: $BACKUP_FILE"

/usr/bin/ucode - <<'UCODE_SCRIPT'
let uci = require("uci").cursor();
let config = "tachyon";

function as_string(v) {
    return v == null ? "" : "" + v;
}

function sanitize(id) {
    let s = replace(as_string(id || ""), /[^A-Za-z0-9_]/g, "_");
    s = replace(s, /_+/g, "_");
    s = replace(s, /^_+|_+$/g, "");
    return s || "item";
}

function get_level_slug(pl, idx) {
    let name = as_string(pl.name || "");
    let slug = sanitize(name);
    if (slug != "item" && slug != "")
        return slug;
    if (index(name, "Лучш") >= 0 || index(name, "лучш") >= 0 || index(name, "Быстр") >= 0 || index(name, "быстр") >= 0)
        return "fast";
    if (index(name, "Резерв") >= 0 || index(name, "резерв") >= 0 || index(name, "Запас") >= 0 || index(name, "запас") >= 0)
        return "reserve";
    let pl_id = sanitize(pl[".name"] || "");
    if (pl_id != "item" && pl_id != "")
        return pl_id;
    return "lvl_" + (idx + 1);
}

function get_balancer_slug(pg) {
    let name = as_string(pg.name || "");
    let slug = sanitize(name);
    if (slug != "item" && slug != "")
        return slug;
    let pg_id = sanitize(pg[".name"] || "");
    if (pg_id != "item" && pg_id != "")
        return pg_id;
    return "priority";
}

function to_arr(val) {
    if (val == null) return [];
    if (type(val) == "array") {
        let res = [];
        for (let item in val) {
            let s = trim(as_string(item || ""));
            if (s != "") push(res, s);
        }
        return res;
    }
    let str = trim(as_string(val || ""));
    if (str == "") return [];
    let parts = split(str, /[\s,]+/);
    let res = [];
    for (let p in parts) {
        let s = trim(p || "");
        if (s != "") push(res, s);
    }
    return res;
}

let priority_groups = [];
let priority_levels = [];
let sections = [];
let balancers = [];

uci.foreach(config, "section", function(s) { push(sections, s); });
uci.foreach(config, "priority_group", function(pg) { push(priority_groups, pg); });
uci.foreach(config, "priority_level", function(pl) { push(priority_levels, pl); });
uci.foreach(config, "balancer", function(b) { push(balancers, b); });

if (length(priority_groups) == 0 && length(priority_levels) == 0) {
    print("ℹ️ Устаревших уровней каскада (priority_level) не обнаружено. Миграция не требуется.\n");
    exit(0);
}

print("🔍 Найдено устаревших групп каскада: " + length(priority_groups) + ", уровней: " + length(priority_levels) + "\n");

let migrated_groups_count = 0;

for (let pg in priority_groups) {
    let pg_id = pg[".name"];
    let pg_name = pg.name || pg_id;
    let sname = pg.section;
    if (!sname || sname == "") {
        // Fallback: search which section references this priority group or has same name
        for (let s in sections) {
            let s_id = s[".name"];
            let bal_refs = to_arr(s.balancer_refs);
            for (let br in bal_refs) {
                if (br == pg_id || index(br, pg_id) >= 0) {
                    sname = s_id;
                    break;
                }
            }
            if (sname) break;
        }
        if (!sname && length(sections) > 0) sname = sections[0][".name"];
    }

    let safe_sname = sanitize(sname);
    let safe_pgname = get_balancer_slug(pg);
    let target_bal_id = "bal_" + safe_sname + "_" + safe_pgname;

    // Check if priority balancer exists or create it
    let bal_id = null;
    for (let b in balancers) {
        let b_type = lc(as_string(b.balancer_type || "urltest"));
        if (b_type == "priority") {
            if (b[".name"] == target_bal_id || b.name == pg_name) {
                bal_id = b[".name"];
                break;
            }
        }
    }
    if (!bal_id) {
        bal_id = target_bal_id;
        uci.set(config, bal_id, "balancer");
        uci.set(config, bal_id, "enabled", "1");
        uci.set(config, bal_id, "balancer_type", "priority");
        uci.set(config, bal_id, "name", pg_name);
        for (let k in [
            "health_url", "active_check_interval", "check_timeout",
            "recovery_check_interval", "pick_fastest",
            "switch_to_faster_same_priority", "fastest_check_interval",
            "interrupt_exist_connections", "pin_dashboard"
        ]) {
            if (pg[k] != null && pg[k] != "") uci.set(config, bal_id, k, pg[k]);
        }
    }

    // Attach balancer to section
    let cur_bal_refs = to_arr(uci.get(config, sname, "balancer_refs"));
    if (index(cur_bal_refs, bal_id) < 0) {
        push(cur_bal_refs, bal_id);
        uci.set(config, sname, "balancer_refs", cur_bal_refs);
    }

    // Find and sort matched priority levels
    let matched_levels = [];
    for (let pl in priority_levels) {
        let pl_grp = pl.group || "";
        let pl_sec = pl.section || "";
        if (pl_grp == pg_id || (pl_grp == "" && pl_sec == sname)) {
            push(matched_levels, pl);
        }
    }

    sort(matched_levels, function(left, right) {
        let lo = int(as_string(left.order || "0"), 10);
        let ro = int(as_string(right.order || "0"), 10);
        return lo < ro ? -1 : (lo > ro ? 1 : 0);
    });

    let sec_sources = to_arr(uci.get(config, sname, "outbound_source_refs"));
    let bal_levels = to_arr(uci.get(config, bal_id, "outbound_group_levels"));
    let sec_groups = to_arr(uci.get(config, sname, "outbound_group_refs"));

    for (let i = 0; i < length(matched_levels); i++) {
        let pl = matched_levels[i];
        let is_direct = (as_string(pl.direct || "0") == "1");
        if (is_direct) {
            if (index(bal_levels, "direct") < 0) push(bal_levels, "direct");
            print("  ➡️ " + (pl.name || "Direct") + " -> direct fallback\n");
            continue;
        }

        let pl_name = pl.name || ("Level " + (i + 1));
        let slug = get_level_slug(pl, i);
        let grp_id = "grp_" + safe_sname + "_" + slug;

        // Ensure unique group ID if not already this level
        let base_grp_id = grp_id;
        let suffix = 1;
        while (true) {
            let existing_name = uci.get(config, grp_id, "name");
            if (existing_name == null || existing_name == pl_name) {
                break;
            }
            grp_id = base_grp_id + "_" + suffix;
            suffix++;
        }

        uci.set(config, grp_id, "outbound_group");
        uci.set(config, grp_id, "enabled", "1");
        uci.set(config, grp_id, "name", pl_name);
        uci.set(config, grp_id, "filter_mode", pl.filter_mode || "include");
        uci.set(config, grp_id, "detect_server_country", pl.detect_server_country || "flag_emoji");

        if (length(sec_sources) > 0) {
            uci.set(config, grp_id, "source_refs", sec_sources);
        }

        for (let lk in [
            "include_prefixes", "exclude_prefixes",
            "include_countries", "exclude_countries",
            "include_outbounds", "exclude_outbounds",
            "include_regex", "exclude_regex",
            "include_protocols", "exclude_protocols",
            "include_transports", "exclude_transports",
            "include_securities", "exclude_securities",
            "include_ports", "exclude_ports"
        ]) {
            let vals = to_arr(pl[lk]);
            if (length(vals) > 0) uci.set(config, grp_id, lk, vals);
        }

        // Aliases from legacy schema
        let leg_countries = to_arr(pl.country);
        if (length(leg_countries) > 0 && length(to_arr(uci.get(config, grp_id, "include_countries"))) == 0) {
            uci.set(config, grp_id, "include_countries", leg_countries);
        }
        let leg_servers = to_arr(pl.server_name);
        if (length(leg_servers) > 0 && length(to_arr(uci.get(config, grp_id, "include_outbounds"))) == 0) {
            uci.set(config, grp_id, "include_outbounds", leg_servers);
        }
        let leg_regex = to_arr(pl.regex);
        if (length(leg_regex) > 0 && length(to_arr(uci.get(config, grp_id, "include_regex"))) == 0) {
            uci.set(config, grp_id, "include_regex", leg_regex);
        }

        for (let pk in [ "include_proxy_parameters", "exclude_proxy_parameters" ]) {
            if (pl[pk] != null && pl[pk] != "") uci.set(config, grp_id, pk, pl[pk]);
        }

        if (index(bal_levels, grp_id) < 0) push(bal_levels, grp_id);
        if (index(sec_groups, grp_id) < 0) push(sec_groups, grp_id);

        migrated_groups_count++;
        print("  ✅ Создана группа [" + grp_id + "]: " + pl_name + "\n");
    }

    if (length(bal_levels) > 0) {
        uci.set(config, bal_id, "outbound_group_levels", bal_levels);
    }
    if (length(sec_groups) > 0) {
        uci.set(config, sname, "outbound_group_refs", sec_groups);
    }
}

uci.save(config);
uci.commit(config);
print("\n🎉 Миграция успешно завершена! Создано групп: " + migrated_groups_count + "\n");
UCODE_SCRIPT

echo "🔄 Перезапуск службы Tachyon для применения новых настроек..."
if [ -x "/etc/init.d/tachyon" ]; then
    /etc/init.d/tachyon reload
elif command -v tachyon >/dev/null 2>&1; then
    tachyon reload
fi

echo ""
echo "===================================================================="
echo "✅ Готово! Конфигурация успешно обновлена."
echo "👉 Откройте веб-интерфейс LuCI и обновите страницу (Ctrl+F5 / Cmd+R)."
echo "   Вкладка: Маршруты -> Узлы и подписки (блок Outbound Groups)"
echo "===================================================================="
