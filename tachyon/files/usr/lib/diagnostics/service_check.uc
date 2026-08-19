#!/usr/bin/env ucode

// Tachyon Service Check - probe engine for Tachyon.
//
// Проверяет доступность сервисов так, как это делает клиент сети: имя резолвится
// через тот же dnsmasq -> sing-box, а соединение уходит из роутера и попадает в
// цепочку mangle_output -> tproxy, то есть тем же путём, что трафик из LAN.
// В режиме netns трафик реально входит через br-lan из отдельного namespace,
// что дополнительно воспроизводит правила секций, привязанные к source IP.

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

const LIB_DIR = getenv("TACHYON_SC_LIB") || "/usr/lib/tachyon-servicecheck";
const ENGINE = LIB_DIR + "/probe.uc";
const PROFILES_OVERRIDE = "/etc/tachyon/servicecheck_profiles.json";
const PROFILES_DEFAULT = "/usr/share/tachyon/servicecheck_profiles.json";
const STATE_DIR = "/var/run/tachyon-servicecheck";
const TACHYON_BIN = "/usr/bin/tachyon";
const DEFAULT_SING_BOX_CONFIG = "/etc/sing-box/config.json";
const NETNS_NAME = "fkpsc";
const NETNS_VETH_HOST = "fkpsc0";
const NETNS_VETH_PEER = "fkpsc1";
const XHTTP_PATCH = "";
const ICMP_TPROXY_PATCH = "";
const CONFIG_DIR = "/etc/tachyon/servicecheck";
const GEMINI_API_KEY_FILE = CONFIG_DIR + "/gemini_api_key";

const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const DNS_TIMEOUT = 3;
const CONNECT_TIMEOUT = 7;
const TOTAL_TIMEOUT = 15;
const SLOW_THRESHOLD_MS = 5000;
const JOB_MAX_AGE = 1800;

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let shell_quote = common.shell_quote;
let command_from_args = common.command_from_args;

function normalize_status(status) {
    status = int(status);
    if (status < 0)
        return 1;
    return status > 255 ? int(status / 256) : status;
}

function now_ms() {
    let value = null;
    try {
        value = clock(true);
    }
    catch (e) {
        value = null;
    }
    if (type(value) != "array")
        value = clock();
    if (type(value) != "array")
        return 0;
    return value[0] * 1000 + int(value[1] / 1000000);
}

function now_seconds() {
    let value = clock();
    return type(value) == "array" ? int(value[0]) : 0;
}

function capture(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return { status: 1, output: "" };
    let data = pipe.read("all");
    let status = normalize_status(pipe.close());
    return { status, output: data == null ? "" : as_string(data) };
}

function capture_args(args, merge_stderr) {
    return capture(command_from_args(args) + (merge_stderr ? " 2>&1" : " 2>/dev/null"));
}

function run_quiet(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function command_exists(name) {
    return run_quiet([ "command", "-v", as_string(name) ]);
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function xhttp_patch() {
    if (fs.stat(XHTTP_PATCH) == null) {
        write_json({ success: false, message: "xHTTP-патч не установлен в пакет" });
        return 1;
    }
    let result = capture_args([ "sh", XHTTP_PATCH ], true);
    write_json({ success: result.status == 0, code: result.status, output: trim(as_string(result.output)) });
    return result.status;
}

function icmp_tproxy_patch() {
    if (fs.stat(ICMP_TPROXY_PATCH) == null) {
        write_json({ success: false, message: "ICMP/TProxy-патч не установлен в пакет" });
        return 1;
    }
    let result = capture_args([ "sh", ICMP_TPROXY_PATCH ], true);
    write_json({ success: result.status == 0, code: result.status, output: trim(as_string(result.output)) });
    return result.status;
}

function available_fixes() {
    if (fs.stat(TACHYON_BIN) == null)
        return [];

    return [
        {
            id: "xhttp_import",
            title: "Фикс xHTTP импорта подписок",
            description: "Исправляет импорт дополнительных полей xHTTP из подписок в parser.uc Tachyon.",
            risk: "Создаётся резервная копия parser.uc; патч проверяется через ucode до замены."
        },
        {
            id: "icmp_tproxy",
            title: "Фикс ping/ICMP для правил подсетей",
            description: "Ограничивает метку TProxy в priority_rules протоколами TCP и UDP, чтобы ICMP не уходил в локальный TProxy-сокет.",
            risk: "Создаётся резервная копия nft/apply.uc; патч проверяется через ucode. Работающий Tachyon перезапускается, live-правила проверяются, а при ошибке выполняется откат."
        }
    ];
}

function list_fixes() {
    write_json({ success: true, fixes: available_fixes() });
    return 0;
}

function run_fix(id) {
    if (fs.stat(TACHYON_BIN) == null) {
        write_json({ success: false, message: "фиксы доступны только при установленном Tachyon" });
        return 1;
    }

    if (as_string(id) == "xhttp_import")
        return xhttp_patch();
    if (as_string(id) == "icmp_tproxy")
        return icmp_tproxy_patch();
    write_json({ success: false, message: "неизвестный фикс Forkop" });
    return 1;
}

function parse_json(value) {
    try {
        return json(as_string(value));
    }
    catch (e) {
        return null;
    }
}

function read_json_file(path) {
    let data = fs.readfile(as_string(path));
    return data == null ? null : parse_json(data);
}

function trim_newlines(value) {
    return replace(as_string(value), /[\r\n]+$/g, "");
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

// curl отдаёт тайминги как "0.123". Собирать число по частям нельзя: деление двух
// целых в ucode целочисленное, и дробная часть схлопывается в ноль. Умножение же
// приводит числовую строку к double, поэтому проверяем формат и умножаем.
function number_value(value) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+(\.[0-9]+)?$/) == null)
        return 0;
    return value * 1;
}

function temp_path(suffix) {
    return sprintf("/tmp/.tachyon-sc-%d-%d.%s", now_seconds(), int(now_ms() % 1000000), as_string(suffix));
}

function ensure_state_dir() {
    run_quiet([ "mkdir", "-p", STATE_DIR ]);
}

function download_profiles_from_repo() {
    const RAW_URL = "https://raw.githubusercontent.com/Dushnilin/tachyon/main/tachyon/files/usr/share/tachyon/servicecheck_profiles.json";
    const MIRRORS = [
        RAW_URL,
        "https://gh-proxy.com/" + RAW_URL,
        "https://ghfast.top/" + RAW_URL,
        "https://ghproxy.net/" + RAW_URL
    ];

    let proxy_address = trim(as_string(common.command_output("/usr/lib/tachyon/singbox/runtime.uc service-proxy-address components 2>/dev/null") || ""));

    let content = "";
    for (let mirror in MIRRORS) {
        // 1. Попытка через локальный прокси
        if (proxy_address != "") {
            let proxy_cmd = [ "curl", "-sS", "-x", "http://" + proxy_address, "--connect-timeout", "5", "--max-time", "15", "-L", mirror ];
            if (!command_exists("curl")) {
                proxy_cmd = [ "uclient-fetch", "-q", "-O", "-", "--timeout=15", mirror ];
            }
            let res = capture_args(proxy_cmd, false);
            if (res.status == 0 && length(trim(res.output)) > 100 && index(res.output, "profiles") >= 0) {
                content = res.output;
                break;
            }
        }

        // 2. Прямое скачивание
        let direct_cmd = [ "curl", "-sS", "--connect-timeout", "5", "--max-time", "15", "-L", mirror ];
        if (!command_exists("curl")) {
            direct_cmd = [ "uclient-fetch", "-q", "-O", "-", "--timeout=15", mirror ];
        }
        let res = capture_args(direct_cmd, false);
        if (res.status == 0 && length(trim(res.output)) > 100 && index(res.output, "profiles") >= 0) {
            content = res.output;
            break;
        }
    }

    if (content == "")
        return null;

    let parsed = parse_json(content);
    if (type(parsed) != "object" || type(parsed.profiles) != "array" || length(parsed.profiles) == 0)
        return null;

    // Сохранение в /usr/share/tachyon или /etc/tachyon
    let target_file = PROFILES_DEFAULT;
    let target_dir = "/usr/share/tachyon";
    run_quiet([ "mkdir", "-p", target_dir ]);
    let tmp = target_file + ".tmp";
    if (fs.stat(target_dir) == null || fs.writefile(tmp, content) == null) {
        target_file = PROFILES_OVERRIDE;
        target_dir = "/etc/tachyon";
        run_quiet([ "mkdir", "-p", target_dir ]);
        tmp = target_file + ".tmp";
        if (fs.writefile(tmp, content) == null) {
            return null;
        }
    }

    run_quiet([ "mv", "-f", tmp, target_file ]);
    run_quiet([ "chmod", "0644", target_file ]);
    return content;
}

function load_profiles_data() {
    let override = getenv("TACHYON_SC_PROFILES") || getenv("FORKOP_SC_PROFILES");
    if (as_string(override) != "") {
        let data = fs.readfile(as_string(override));
        if (data != null && length(trim(data)) > 0) return data;
    }

    if (fs.stat(PROFILES_OVERRIDE) != null) {
        let data = fs.readfile(PROFILES_OVERRIDE);
        if (data != null && length(trim(data)) > 0) return data;
    }

    if (fs.stat(PROFILES_DEFAULT) != null) {
        let data = fs.readfile(PROFILES_DEFAULT);
        if (data != null && length(trim(data)) > 0) return data;
    }

    return download_profiles_from_repo();
}

function profiles_file() {
    let override = getenv("TACHYON_SC_PROFILES") || getenv("FORKOP_SC_PROFILES");
    if (as_string(override) != "")
        return as_string(override);
    if (fs.stat(PROFILES_OVERRIDE) != null)
        return PROFILES_OVERRIDE;
    if (fs.stat(PROFILES_DEFAULT) != null)
        return PROFILES_DEFAULT;
    download_profiles_from_repo();
    if (fs.stat(PROFILES_OVERRIDE) != null)
        return PROFILES_OVERRIDE;
    return PROFILES_DEFAULT;
}

// ---------------------------------------------------------------------------
// Сеть: разбор адресов
// ---------------------------------------------------------------------------

function valid_ipv4(value) {
    value = trim(as_string(value));
    let matched = match(value, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
    if (matched == null)
        return false;
    for (let i = 1; i <= 4; i++)
        if (int(matched[i]) > 255)
            return false;
    return true;
}

function valid_domain(value) {
    value = trim(as_string(value));
    if (length(value) < 1 || length(value) > 253 || index(value, "..") >= 0)
        return false;

    for (let label in split(value, ".")) {
        if (length(label) < 1 || length(label) > 63 ||
            match(label, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) == null)
            return false;
    }

    return true;
}

function valid_custom_host(value) {
    value = trim(as_string(value));
    if (valid_ipv4(value))
        return true;
    // Не принимаем ошибочный IPv4 вроде 999.1.1.1 за обычное доменное имя.
    if (match(value, /^[0-9.]+$/) != null)
        return false;
    return valid_domain(value);
}

function ipv4_to_int(value) {
    let parts = split(trim(as_string(value)), ".");
    if (length(parts) != 4)
        return -1;
    return int(parts[0]) * 16777216 + int(parts[1]) * 65536 + int(parts[2]) * 256 + int(parts[3]);
}

function int_to_ipv4(value) {
    value = int(value);
    let a = int(value / 16777216) % 256;
    let b = int(value / 65536) % 256;
    let c = int(value / 256) % 256;
    let d = value % 256;
    return sprintf("%d.%d.%d.%d", a, b, c, d);
}

function prefix_mask(prefix) {
    prefix = int(prefix);
    if (prefix <= 0)
        return 0;
    if (prefix >= 32)
        return 4294967295;
    return (4294967295 << (32 - prefix)) & 4294967295;
}

function ipv4_in_cidr(ip, cidr) {
    let parts = split(as_string(cidr), "/");
    if (length(parts) != 2 || !valid_ipv4(ip) || !valid_ipv4(parts[0]))
        return false;
    let mask = prefix_mask(parts[1]);
    return (ipv4_to_int(ip) & mask) == (ipv4_to_int(parts[0]) & mask);
}


function ipv4_in_any_cidr(ip, cidrs) {
    for (let cidr in array_or_empty(cidrs))
        if (ipv4_in_cidr(ip, cidr))
            return true;
    return false;
}

// ---------------------------------------------------------------------------
// Окружение роутера
// ---------------------------------------------------------------------------

function uci_get(path) {
    let result = capture_args([ "uci", "-q", "get", as_string(path) ]);
    return result.status == 0 ? trim_newlines(result.output) : "";
}

function backend_id() {
    let override = lc(trim(as_string(getenv("TACHYON_SC_BACKEND"))));
    if (override == "tachyon")
        return override;
    if (fs.stat(TACHYON_BIN) != null)
        return "tachyon";
    return "none";
}

function backend_name(id) {
    id = as_string(id);
    if (id == "tachyon")
        return "Tachyon";
    return "Sing-box";
}

function sing_box_config_path() {
    let overridden = trim(as_string(getenv("TACHYON_SC_SING_BOX_CONFIG")));
    if (overridden != "")
        return overridden;

    if (backend_id() == "tachyon") {
        let configured = trim(uci_get("tachyon.settings.config_path"));
        if (configured != "")
            return configured;
    }

    return DEFAULT_SING_BOX_CONFIG;
}

function lan_interface() {
    let namespace = backend_id() == "podkop" ? "podkop" : "forkop";
    let configured = words(uci_get(namespace + ".settings.source_network_interfaces"));
    if (length(configured) > 0)
        return configured[0];
    return "br-lan";
}

function interface_ipv4(interface) {
    let output = capture_args([ "ip", "-4", "-o", "addr", "show", "dev", as_string(interface) ], false).output;
    for (let line in split(output, "\n")) {
        let matched = match(trim(as_string(line)), /inet[ \t]+([0-9.]+)\/([0-9]+)/);
        if (matched != null)
            return { address: matched[1], prefix: int(matched[2]) };
    }
    return null;
}

function fakeip_ranges() {
    let ranges = [];
    let config = read_json_file(sing_box_config_path());
    let dns = object_or_empty(object_or_empty(config).dns);

    for (let server in array_or_empty(dns.servers)) {
        server = object_or_empty(server);
        if (as_string(server.type) == "fakeip") {
            if (as_string(server.inet4_range) != "")
                push(ranges, as_string(server.inet4_range));
        }
    }

    let legacy = object_or_empty(dns.fakeip);
    if (as_string(legacy.inet4_range) != "")
        push(ranges, as_string(legacy.inet4_range));

    if (length(ranges) == 0)
        push(ranges, "198.18.0.0/15");

    return ranges;
}

function forkop_running() {
    let backend = backend_id();
    let result;

    if (backend == "forkop")
        result = capture_args([ FORKOP_BIN, "get_status" ], false);
    else if (backend == "podkop")
        result = capture_args([ PODKOP_BIN, "get_sing_box_status" ], false);
    else
        return false;

    if (result.status != 0) {
        if (backend == "podkop")
            return run_quiet([ "pgrep", "-f", "sing-box" ]);
        return false;
    }
    let status = object_or_empty(parse_json(result.output));
    if (status.running === true || int(status.running) == 1)
        return true;
    if (backend == "podkop" && status.running == null)
        return run_quiet([ "pgrep", "-f", "sing-box" ]);
    return false;
}

// Сборки busybox сильно разнятся: где-то nc умеет -z и -w, где-то это
// "Usage: nc [IPADDR PORT]" вообще без флагов. Пробуем от лучшего к худшему.
function nc_option_rejected(command) {
    let output = lc(as_string(capture(command).output));
    return index(output, "invalid option") >= 0 || index(output, "unrecognized option") >= 0 ||
        index(output, "usage:") >= 0 || index(output, "bad port") >= 0;
}

function detect_nc_mode() {
    if (!command_exists("nc"))
        return "none";
    if (!nc_option_rejected("nc -z -w 1 127.0.0.1 1 2>&1"))
        return "zero";
    if (!nc_option_rejected("nc -w 1 127.0.0.1 1 2>&1"))
        return "wait";
    return "plain";
}

function capabilities() {
    let backend = backend_id();
    let running = forkop_running();
    let interface = lan_interface();
    let address = interface_ipv4(interface);
    let nc_mode = detect_nc_mode();

    return {
        curl: command_exists("curl"),
        uclient_fetch: command_exists("uclient-fetch") || command_exists("wget"),
        dig: command_exists("dig"),
        nslookup: command_exists("nslookup"),
        nc: nc_mode != "none",
        nc_mode,
        timeout_cmd: command_exists("timeout"),
        netns: run_quiet([ "ip", "netns", "list" ]) && command_exists("ip"),
        lan_interface: interface,
        lan_address: address == null ? "" : address.address,
        lan_prefix: address == null ? 0 : address.prefix,
        fakeip_ranges: fakeip_ranges(),
        backend,
        backend_name: backend_name(backend),
        backend_installed: backend != "none",
        backend_running: running,
        forkop_installed: fs.stat(FORKOP_BIN) != null,
        podkop_installed: fs.stat(PODKOP_BIN) != null,
        fixes_available: backend == "forkop" && fs.stat(FORKOP_BIN) != null,
        sing_box_config: sing_box_config_path(),
        // Старое поле оставлено для совместимости со страницей предыдущих версий.
        forkop_running: running,
        profiles_version: int(object_or_empty(read_json_file(profiles_file())).version || 0)
    };
}

// ---------------------------------------------------------------------------
// Профили
// ---------------------------------------------------------------------------

function load_profiles() {
    let data = object_or_empty(read_json_file(profiles_file()));
    return array_or_empty(data.profiles);
}

function validate_profiles_config(config) {
    if (type(config) != "object" || type(config.profiles) != "array")
        return "корневой объект должен содержать массив profiles";

    let profiles = array_or_empty(config.profiles);
    if (length(profiles) == 0)
        return "список profiles не может быть пустым";
    if (length(profiles) > 100)
        return "допускается не более 100 профилей";

    let seen = {};
    let allowed_kinds = { https: true, http: true, tcp: true, udp: true, udp_dns: true };

    for (let profile in profiles) {
        profile = object_or_empty(profile);
        let id = as_string(profile.id);
        let title = trim(as_string(profile.title));
        let targets = array_or_empty(profile.targets);

        if (match(id, /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/) == null)
            return "некорректный id профиля: " + id;
        if (seen[id])
            return "id профиля повторяется: " + id;
        seen[id] = true;
        if (title == "")
            return "у профиля " + id + " не задан title";
        if (length(targets) == 0 || length(targets) > 50)
            return "у профиля " + id + " должно быть от 1 до 50 целей";

        for (let target in targets) {
            target = object_or_empty(target);
            let kind = as_string(target.kind || "https");
            let host = trim(as_string(target.host));
            let port = int(target.port || (kind == "http" ? 80 : 443));

            if (!allowed_kinds[kind])
                return "неподдерживаемый kind в профиле " + id + ": " + kind;
            if (host == "" || match(host, /[ \t\r\n\/]/) != null)
                return "некорректный host в профиле " + id;
            if (port < 1 || port > 65535)
                return "некорректный port в профиле " + id;
        }
    }

    return "";
}

function profiles_get() {
    let path = profiles_file();
    let config = read_json_file(path);
    if (type(config) != "object") {
        write_json({ success: false, message: "не удалось прочитать список проверок" });
        return 1;
    }
    write_json({ success: true, source: path == PROFILES_OVERRIDE ? "custom" : "built-in", config });
    return 0;
}

function profiles_save(payload) {
    payload = as_string(payload);
    if (length(payload) == 0 || length(payload) > 131072) {
        write_json({ success: false, message: "размер списка должен быть от 1 байта до 128 КиБ" });
        return 1;
    }

    let config = parse_json(payload);
    let error = validate_profiles_config(config);
    if (error != "") {
        write_json({ success: false, message: error });
        return 1;
    }

    if (!run_quiet([ "mkdir", "-p", "/etc/forkop-servicecheck" ])) {
        write_json({ success: false, message: "не удалось создать /etc/forkop-servicecheck" });
        return 1;
    }

    let temporary = PROFILES_OVERRIDE + ".tmp";
    if (fs.writefile(temporary, sprintf("%J", config) + "\n") == null ||
        !run_quiet([ "chmod", "0644", temporary ]) ||
        !run_quiet([ "mv", "-f", temporary, PROFILES_OVERRIDE ])) {
        fs.unlink(temporary);
        write_json({ success: false, message: "не удалось сохранить пользовательский список" });
        return 1;
    }

    write_json({ success: true, message: "пользовательский список сохранён", profiles: length(config.profiles) });
    return 0;
}

function profiles_reset() {
    if (fs.stat(PROFILES_OVERRIDE) != null && fs.unlink(PROFILES_OVERRIDE) == null) {
        write_json({ success: false, message: "не удалось удалить пользовательский список" });
        return 1;
    }
    write_json({ success: true, message: "восстановлен встроенный список" });
    return 0;
}

function target_label(target) {
    target = object_or_empty(target);
    if (as_string(target.label) != "")
        return as_string(target.label);
    if (as_string(target.kind) == "tcp" || as_string(target.kind) == "udp" || as_string(target.kind) == "udp_dns")
        return sprintf("%s:%d", as_string(target.host), int(target.port || 443));
    return as_string(target.host) + as_string(target.path || "/");
}

function target_url(target) {
    target = object_or_empty(target);
    let scheme = as_string(target.kind) == "http" ? "http" : "https";
    let port = int(target.port || 0);
    let host = as_string(target.host);
    let authority = port > 0 && port != 443 && port != 80 ? host + ":" + as_string(port) : host;
    let path = as_string(target.path || "/");
    if (substr(path, 0, 1) != "/")
        path = "/" + path;
    return scheme + "://" + authority + path;
}

// ---------------------------------------------------------------------------
// Пробы
// ---------------------------------------------------------------------------

function prefixed_args(ctx, args) {
    let full = [];
    for (let arg in array_or_empty(ctx.exec_prefix))
        push(full, arg);
    for (let arg in args)
        push(full, arg);
    return full;
}

function probe_dns(ctx, host) {
    if (valid_ipv4(host))
        return { ok: true, ip: host, fakeip: false, ms: 0, error: "", skipped: true };

    let started = now_ms();
    let addresses = [];

    if (ctx.tools.dig) {
        let result = capture_args(prefixed_args(ctx, [
            "dig", "@" + ctx.resolver, as_string(host), "A", "+short",
            "+timeout=" + as_string(DNS_TIMEOUT), "+tries=1"
        ]), false);
        for (let line in split(result.output, "\n")) {
            line = trim(as_string(line));
            if (valid_ipv4(line))
                push(addresses, line);
        }
    }
    else if (ctx.tools.nslookup) {
        let result = capture_args(prefixed_args(ctx, [ "nslookup", as_string(host), ctx.resolver ]), true);
        // busybox печатает "Address 1: 1.2.3.4 host.example", хвост после адреса игнорируем.
        for (let line in split(result.output, "\n")) {
            let matched = match(trim(as_string(line)), /^Address[ \t0-9]*:[ \t]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/);
            if (matched != null && valid_ipv4(matched[1]) && matched[1] != ctx.resolver)
                push(addresses, matched[1]);
        }
    }

    let elapsed = now_ms() - started;

    if (length(addresses) == 0)
        return { ok: false, ip: "", fakeip: false, ms: elapsed, error: "нет A-записи" };

    return {
        ok: true,
        ip: addresses[0],
        all: addresses,
        fakeip: ipv4_in_any_cidr(addresses[0], ctx.fakeip_ranges),
        ms: elapsed,
        error: ""
    };
}

function curl_failure_verdict(status, output) {
    output = lc(as_string(output));

    if (status == 6)
        return { verdict: "dns_fail", message: "имя не резолвится" };
    if (status == 7)
        return { verdict: "tcp_refused", message: "не удалось установить TCP-соединение" };
    if (status == 28)
        return { verdict: "timeout", message: "таймаут соединения" };
    // Три "ошибки TLS" у curl имеют совершенно разные причины, и валить их в одну
    // строку - значит прятать диагноз. 35 - хендшейк оборвали (типовая подпись DPI),
    // 51 - сертификат отклонён, 60 - сертификат не удалось проверить, а это почти
    // всегда сбитые часы роутера (нет RTC) или отсутствующий ca-bundle.
    if (status == 35)
        return { verdict: "tls_handshake", message: "TLS-хендшейк оборван — похоже на DPI или несовместимый TLS" };
    if (status == 51)
        return { verdict: "tls_cert_rejected", message: "сертификат сервера отклонён" };
    if (status == 60)
        return { verdict: "tls_cert_untrusted", message: "сертификат не проверен — проверьте часы роутера и наличие ca-bundle" };
    if (status == 52)
        return { verdict: "tls_reset", message: "сервер закрыл соединение без ответа" };
    if (status == 56)
        return { verdict: "tls_reset", message: "соединение сброшено при передаче данных" };
    if (status == 47)
        return { verdict: "redirect_loop", message: "сервис отвечает, но перенаправляет по кругу" };
    if (index(output, "connection reset") >= 0)
        return { verdict: "tls_reset", message: "соединение сброшено" };

    return { verdict: "failed", message: trim(as_string(output)) != "" ? trim(as_string(output)) : sprintf("curl завершился с кодом %d", status) };
}

function http_probe_curl(ctx, target) {
    let url = target_url(target);
    let format = "%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{remote_ip}";
    let args = prefixed_args(ctx, [
        "curl", "-sS", "-o", "/dev/null", "-L", "--max-redirs", "5",
        "--connect-timeout", as_string(CONNECT_TIMEOUT),
        "--max-time", as_string(TOTAL_TIMEOUT),
        "-A", USER_AGENT,
        "-w", format,
        url
    ]);
    let error_file = temp_path("curl-err");
    let result = capture(command_from_args(args) + " 2>" + shell_quote(error_file));
    let stderr = as_string(fs.readfile(error_file) || "");
    fs.unlink(error_file);

    if (result.status != 0) {
        let failure = curl_failure_verdict(result.status, stderr);
        return {
            reached: false,
            code: 0,
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: 0,
            verdict: failure.verdict,
            message: failure.message
        };
    }

    let fields = split(trim(as_string(result.output)), "|");
    if (length(fields) < 7)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: 0, verdict: "failed", message: "не удалось разобрать ответ curl" };

    let namelookup = number_value(fields[1]) * 1000;
    let connect = number_value(fields[2]) * 1000;
    let appconnect = number_value(fields[3]) * 1000;
    let total = number_value(fields[5]) * 1000;

    return {
        reached: true,
        code: int(fields[0]),
        remote_ip: as_string(fields[6]),
        dns_ms: int(namelookup),
        tcp_ms: int(connect > namelookup ? connect - namelookup : connect),
        tls_ms: int(appconnect > connect ? appconnect - connect : 0),
        total_ms: int(total),
        verdict: "",
        message: ""
    };
}

function uclient_failure_verdict(output) {
    output = lc(as_string(output));

    if (index(output, "download completed") >= 0)
        return null;
    if (index(output, "failed to resolve") >= 0 || index(output, "name or service not known") >= 0)
        return { verdict: "dns_fail", message: "имя не резолвится" };
    if (index(output, "connection refused") >= 0)
        return { verdict: "tcp_refused", message: "соединение отклонено" };
    if (index(output, "timed out") >= 0 || index(output, "timeout") >= 0)
        return { verdict: "timeout", message: "таймаут соединения" };
    if (index(output, "connection reset") >= 0)
        return { verdict: "tls_reset", message: "соединение сброшено" };
    if (index(output, "ssl") >= 0 || index(output, "tls") >= 0)
        return { verdict: "tls_error", message: "ошибка TLS" };
    if (index(output, "failed to establish connection") >= 0)
        return { verdict: "timeout", message: "не удалось установить соединение" };

    return { verdict: "failed", message: trim(as_string(output)) };
}

function http_probe_uclient(ctx, target) {
    let url = target_url(target);
    let binary = command_exists("uclient-fetch") ? "uclient-fetch" : "wget";
    let started = now_ms();
    // Без -q: именно в stderr uclient-fetch и busybox wget пишут причину отказа,
    // а -T понимают обе реализации, в отличие от --timeout=.
    let result = capture_args(prefixed_args(ctx, [
        binary, "-T", as_string(CONNECT_TIMEOUT), "-O", "/dev/null", url
    ]), true);
    let elapsed = now_ms() - started;
    let output = as_string(result.output);

    let code_match = match(output, /HTTP error ([0-9]{3})/);
    if (code_match != null)
        return {
            reached: true,
            code: int(code_match[1]),
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: elapsed,
            verdict: "",
            message: ""
        };

    if (result.status == 0)
        return {
            reached: true,
            code: 200,
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: elapsed,
            verdict: "",
            message: "код ответа определён приблизительно (нет curl)"
        };

    let failure = uclient_failure_verdict(output);
    if (failure == null)
        return { reached: true, code: 200, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "", message: "" };

    return {
        reached: false,
        code: 0,
        remote_ip: "",
        tcp_ms: 0,
        tls_ms: 0,
        total_ms: elapsed,
        verdict: failure.verdict,
        message: failure.message
    };
}

// Проверка чистого TCP через curl. Протокол на порту нам безразличен: важно лишь,
// дошло ли дело до установленного соединения. curl это и говорит кодом выхода -
// 7 и 28 означают, что соединиться не удалось, а ошибки TLS уровнем выше (35, 52,
// 56) означают, что TCP как раз поднялся. Так обходимся без nc, флаги которого
// в busybox-сборках непредсказуемы.
function tcp_probe_curl(ctx, target) {
    let host = as_string(target.host);
    let port = int(target.port || 443);
    let url = "https://" + host + ":" + as_string(port) + "/";
    let args = prefixed_args(ctx, [
        "curl", "-sS", "-o", "/dev/null",
        "--connect-timeout", as_string(CONNECT_TIMEOUT),
        "--max-time", as_string(CONNECT_TIMEOUT + 2),
        "-w", "%{time_connect}|%{remote_ip}",
        url
    ]);
    let started = now_ms();
    let result = capture(command_from_args(args) + " 2>/dev/null");
    let elapsed = now_ms() - started;
    let status = result.status;

    let fields = split(trim(as_string(result.output)), "|");
    let connect_ms = length(fields) > 0 ? int(number_value(fields[0]) * 1000) : 0;
    let remote_ip = length(fields) > 1 ? as_string(fields[1]) : "";

    if (status == 6)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "dns_fail", message: "имя не резолвится" };

    if (status == 7)
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "tcp_refused", message: "не удалось установить TCP-соединение" };

    // curl can time out after the TCP handshake while it waits for an HTTPS
    // response. Raw TCP services can accept connections on port 443 without
    // speaking TLS/HTTP. In that case time_connect/remote_ip
    // prove that the TCP target is reachable, which is all this probe tests.
    if (status == 28 && connect_ms <= 0 && remote_ip == "")
        return { reached: false, code: 0, remote_ip: "", tcp_ms: 0, tls_ms: 0, total_ms: elapsed, verdict: "timeout", message: "таймаут TCP-соединения" };

    let measured = connect_ms > 0 ? connect_ms : elapsed;
    return { reached: true, code: 0, remote_ip, tcp_ms: measured, tls_ms: 0, total_ms: measured, verdict: "", message: "" };
}

function tcp_probe_nc(ctx, target) {
    let host = as_string(target.host);
    let port = as_string(int(target.port || 443));
    let mode = as_string(ctx.tools.nc_mode);
    let args = [];

    if (mode == "zero")
        args = [ "nc", "-z", "-w", as_string(CONNECT_TIMEOUT), host, port ];
    else if (mode == "wait")
        args = [ "nc", "-w", as_string(CONNECT_TIMEOUT), host, port ];
    else if (ctx.tools.timeout_cmd)
        args = [ "timeout", as_string(CONNECT_TIMEOUT), "nc", host, port ];
    else
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "nc без поддержки таймаута, а curl не установлен" };

    let started = now_ms();
    let status = normalize_status(system(command_from_args(prefixed_args(ctx, args)) + " </dev/null >/dev/null 2>&1"));
    let elapsed = now_ms() - started;

    if (status == 0)
        return { reached: true, code: 0, remote_ip: "", tcp_ms: elapsed, tls_ms: 0, total_ms: elapsed, verdict: "", message: "" };

    let timed_out = elapsed >= CONNECT_TIMEOUT * 1000 - 500;
    return {
        reached: false,
        code: 0,
        remote_ip: "",
        tcp_ms: 0,
        tls_ms: 0,
        total_ms: elapsed,
        verdict: timed_out ? "timeout" : "tcp_refused",
        message: timed_out ? "таймаут TCP-соединения" : "TCP-соединение отклонено"
    };
}

function tcp_probe(ctx, target) {
    if (ctx.tools.curl)
        return tcp_probe_curl(ctx, target);
    return tcp_probe_nc(ctx, target);
}

// Google возвращает отдельный FAILED_PRECONDITION для регионов, в которых
// Gemini API недоступен. Обычная HTTPS-проверка этого не отличает от рабочего
// API с ошибкой авторизации, поэтому для профиля Gemini разбираем JSON-ответ.
function read_gemini_api_key() {
    return trim(as_string(fs.readfile(GEMINI_API_KEY_FILE) || ""));
}

function probe_gemini_geo(ctx, target) {
    let api_key = read_gemini_api_key();
    if (api_key == "")
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "укажите API-ключ Gemini в настройках карточки" };

    let url = "https://" + as_string(target.host) + as_string(target.path);
    let body_file = temp_path("gemini-body");
    let error_file = temp_path("gemini-err");
    let config_file = temp_path("gemini-curl");

    // Ключ не передаётся в argv curl и не виден в списке процессов. Временный
    // config доступен только root и удаляется сразу после завершения запроса.
    if (fs.writefile(config_file, "header = \"x-goog-api-key: " + api_key + "\"\n") == null)
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "gemini_geo_error", message: "не удалось подготовить запрос Gemini API" };
    run_quiet([ "chmod", "600", config_file ]);

    let started = now_ms();
    let format = "%{http_code}|%{remote_ip}|%{time_total}";
    let args = prefixed_args(ctx, [
        "curl", "--config", config_file, "-sS",
        "-o", body_file,
        "--connect-timeout", as_string(CONNECT_TIMEOUT),
        "--max-time", as_string(TOTAL_TIMEOUT),
        "-A", USER_AGENT,
        "-w", format,
        url
    ]);
    let result = capture(command_from_args(args) + " 2>" + shell_quote(error_file));
    let stderr = as_string(fs.readfile(error_file) || "");
    let body_raw = as_string(fs.readfile(body_file) || "");
    fs.unlink(config_file);
    fs.unlink(error_file);
    fs.unlink(body_file);

    let elapsed = now_ms() - started;
    if (result.status != 0) {
        let failure = curl_failure_verdict(result.status, stderr);
        return {
            reached: false,
            code: 0,
            remote_ip: "",
            tcp_ms: 0,
            tls_ms: 0,
            total_ms: int(elapsed),
            verdict: failure.verdict,
            message: failure.message
        };
    }

    let fields = split(trim(as_string(result.output)), "|");
    let http_code = int(fields[0]);
    let remote_ip = as_string(fields[1]);
    let total_ms = int(number_value(fields[2]) * 1000);
    let body = parse_json(body_raw);
    body = type(body) == "object" ? body : {};
    let error_obj = object_or_empty(body.error);
    let error_status = as_string(error_obj.status);
    let error_message = as_string(error_obj.message);
    let error_lc = lc(error_message);
    let verdict = "gemini_geo_error";
    let message = "";

    if (http_code == 200) {
        verdict = "gemini_geo_ok";
        message = "Gemini API доступен в этом регионе";
    }
    else if (error_status == "FAILED_PRECONDITION" || index(error_lc, "user location is not supported") >= 0) {
        verdict = "gemini_geo_blocked";
        message = "регион VPN-сервера недоступен для Gemini — смените сервер на другой регион";
    }
    else if (error_status == "INVALID_ARGUMENT" || index(error_lc, "api key not valid") >= 0) {
        verdict = "gemini_api_key_invalid";
        message = "API-ключ Gemini невалиден — обновите его в настройках карточки";
    }
    else if (http_code == 401 || http_code == 403) {
        if (index(error_lc, "location") >= 0 || index(error_lc, "supported") >= 0) {
            verdict = "gemini_geo_blocked";
            message = "регион недоступен для Gemini API — смените VPN-сервер";
        }
        else {
            verdict = "gemini_api_key_invalid";
            message = error_message != "" ? error_message : "Google отклонил API-ключ Gemini";
        }
    }
    else {
        message = error_message != ""
            ? sprintf("неожиданный ответ Gemini API: HTTP %d — %s", http_code, error_message)
            : sprintf("неожиданный ответ Gemini API: HTTP %d", http_code);
    }

    return {
        reached: true,
        code: http_code,
        remote_ip,
        tcp_ms: 0,
        tls_ms: 0,
        total_ms: total_ms > 0 ? total_ms : int(elapsed),
        verdict,
        message
    };
}

function udp_probe(ctx, target) {
    if (!ctx.tools.nc)
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет nc для UDP-проверки" };

    let started = now_ms();
    let args = [ "nc", "-u" ];
    if (ctx.tools.nc_mode == "zero")
        push(args, "-z");
    if (ctx.tools.nc_mode != "plain")
        push(args, "-w", "2");
    push(args, as_string(target.host), as_string(int(target.port || 0)));
    let status = normalize_status(system(command_from_args(prefixed_args(ctx, args)) + " </dev/null >/dev/null 2>&1"));
    let elapsed = now_ms() - started;

    // UDP не подтверждает доставку без ответа приложения. Это best-effort:
    // успешная отправка означает, что маршрут и локальный сокет доступны.
    if (status == 0)
        return { reached: true, code: 0, remote_ip: "", tcp_ms: elapsed, tls_ms: 0, total_ms: elapsed, verdict: "udp_unconfirmed", message: "UDP-пакет отправлен, но протокол не подтвердил доставку" };
    return { reached: true, code: 0, remote_ip: "", tcp_ms: elapsed, tls_ms: 0, total_ms: elapsed, verdict: "udp_unconfirmed", message: "UDP-ответ не получен; это не доказывает блокировку трафика" };
}

function udp_dns_probe(ctx, target) {
    if (!ctx.tools.nslookup)
        return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет nslookup для двусторонней UDP-проверки" };

    let query = as_string(target.query || "example.com");
    let started = now_ms();
    let result = capture_args(prefixed_args(ctx, [ "nslookup", query, as_string(target.host) ]), true);
    let elapsed = now_ms() - started;
    let output = lc(as_string(result.output));
    let ok = result.status == 0 && index(output, "address") >= 0;
    return {
        reached: ok,
        code: 0,
        remote_ip: as_string(target.host),
        tcp_ms: elapsed,
        tls_ms: 0,
        total_ms: elapsed,
        verdict: ok ? "" : "timeout",
        message: ok ? "получен ответ DNS по UDP" : "нет ответа DNS по UDP"
    };
}

function connection_probe(ctx, target) {
    if (as_string(target.kind) == "gemini_geo") {
        if (!ctx.tools.curl)
            return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "для геопроверки Gemini нужен curl" };
        return probe_gemini_geo(ctx, target);
    }
    if (as_string(target.kind) == "udp_dns")
        return udp_dns_probe(ctx, target);
    if (as_string(target.kind) == "udp")
        return udp_probe(ctx, target);
    if (as_string(target.kind) == "tcp") {
        if (!ctx.tools.curl && !ctx.tools.nc)
            return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет ни curl, ни nc" };
        return tcp_probe(ctx, target);
    }

    if (ctx.tools.curl)
        return http_probe_curl(ctx, target);
    if (ctx.tools.uclient_fetch)
        return http_probe_uclient(ctx, target);

    return { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "skipped", message: "нет ни curl, ни uclient-fetch" };
}

// ---------------------------------------------------------------------------
// Определение маршрута через Clash API
// ---------------------------------------------------------------------------

function clash_connections() {
    let backend = backend_id();
    let result;

    if (backend == "forkop") {
        result = capture_args([ FORKOP_BIN, "clash_api", "get_connections" ], false);
    }
    else if (backend == "podkop") {
        let config = object_or_empty(read_json_file(sing_box_config_path()));
        let clash = object_or_empty(object_or_empty(config.experimental).clash_api);
        let controller = trim(as_string(clash.external_controller));
        let secret = as_string(clash.secret);

        if (controller == "")
            controller = "127.0.0.1:9090";
        if (match(controller, /^0\.0\.0\.0:/) != null)
            controller = replace(controller, /^0\.0\.0\.0:/, "127.0.0.1:");
        if (index(controller, "http://") != 0 && index(controller, "https://") != 0)
            controller = "http://" + controller;

        let args = [ "curl", "-sS", "--connect-timeout", "2", "--max-time", "4" ];
        if (secret == "")
            secret = uci_get("podkop.settings.yacd_secret_key");
        if (secret != "") {
            push(args, "-H");
            push(args, "Authorization: Bearer " + secret);
        }
        push(args, controller + "/connections");
        result = capture_args(args, false);
    }
    else {
        return [];
    }

    if (result.status != 0)
        return [];

    let parsed = parse_json(result.output);
    if (type(parsed) == "array")
        return parsed;

    return array_or_empty(object_or_empty(parsed).connections);
}

function route_for(connections, host, remote_ip, port) {
    host = lc(as_string(host));
    remote_ip = as_string(remote_ip);
    port = int(port || 0);

    for (let connection in connections) {
        connection = object_or_empty(connection);
        let metadata = object_or_empty(connection.metadata);
        let connection_host = lc(as_string(metadata.host));
        let destination = as_string(metadata.destinationIP);
        let destination_port = int(metadata.destinationPort || 0);

        if ((connection_host != "" && connection_host == host) ||
            (remote_ip != "" && destination == remote_ip)) {
            if (port > 0 && destination_port > 0 && destination_port != port)
                continue;
            let chains = array_or_empty(connection.chains);
            return {
                seen: true,
                outbound: length(chains) > 0 ? join(" ← ", chains) : ""
            };
        }
    }

    return { seen: false, outbound: "" };
}

function outbound_for(connections, host, remote_ip) {
    return route_for(connections, host, remote_ip, 0).outbound;
}

// Держим отдельное TCP-соединение открытым несколько секунд и в это время
// опрашиваем Clash API. Так маршрут определяется заметно надёжнее, чем после
// короткого HTTP-запроса, который часто успевает закрыться до get_connections.
function detect_live_route(ctx, host, port, remote_ip) {
    let unknown = { attempted: false, seen: false, outbound: "" };
    if (!ctx.backend_running)
        return unknown;

    let command = "";
    let nc_mode = as_string(ctx.tools.nc_mode);
    if (ctx.tools.nc && (nc_mode == "zero" || nc_mode == "wait")) {
        let args = prefixed_args(ctx, [ "nc", "-w", "6", as_string(host), as_string(port) ]);
        command = "( sleep 5 ) | " + command_from_args(args);
    }
    else if (ctx.tools.curl) {
        let url = "https://" + as_string(host) + ":" + as_string(port) + "/";
        let args = prefixed_args(ctx, [
            "curl", "-k", "-sS", "-L", "--connect-timeout", "4", "--max-time", "6",
            "--limit-rate", "1", "-o", "/dev/null", url
        ]);
        command = command_from_args(args);
    }
    else {
        return unknown;
    }

    let launched = normalize_status(system(common.background_command(command))) == 0;
    if (!launched)
        return unknown;

    for (let attempt = 0; attempt < 6; attempt++) {
        run_quiet([ "sleep", "1" ]);
        let route = route_for(clash_connections(), host, remote_ip, port);
        if (route.seen)
            return { attempted: true, seen: true, outbound: route.outbound };
    }

    return { attempted: true, seen: false, outbound: "" };
}

// ---------------------------------------------------------------------------
// Вердикты
// ---------------------------------------------------------------------------

function expected_codes(target) {
    let expect = array_or_empty(object_or_empty(target).expect);
    return length(expect) > 0 ? expect : [ 200 ];
}

function code_expected(code, target) {
    code = int(code);
    for (let value in expected_codes(target))
        if (int(value) == code)
            return true;
    return false;
}

function target_verdict(target, dns, connection) {
    if (as_string(connection.verdict) == "skipped")
        return { state: "skipped", verdict: "skipped", message: as_string(connection.message) };

    if (as_string(connection.verdict) == "udp_unconfirmed")
        return { state: "warning", verdict: "udp_unconfirmed", message: as_string(connection.message) };

    if (!dns.ok && !valid_ipv4(as_string(target.host)))
        return { state: "error", verdict: "dns_fail", message: "DNS не отдал адрес: " + as_string(dns.error) };

    if (!connection.reached) {
        let verdict = as_string(connection.verdict);
        // Круг редиректов означает, что сервис отвечает: сеть до него рабочая,
        // поэтому это замечание, а не отказ.
        if (verdict == "redirect_loop")
            return { state: "warning", verdict, message: as_string(connection.message) };
        return { state: "error", verdict: verdict != "" ? verdict : "failed", message: as_string(connection.message) };
    }

    if (as_string(target.kind) == "gemini_geo") {
        if (connection.verdict == "gemini_geo_ok")
            return { state: "success", verdict: "ok", message: as_string(connection.message) };
        if (connection.verdict == "gemini_geo_blocked")
            return { state: "warning", verdict: "geo_blocked", message: as_string(connection.message) };
        if (connection.verdict == "gemini_api_key_invalid")
            return { state: "warning", verdict: "gemini_api_key_invalid", message: as_string(connection.message) };
        return { state: "error", verdict: as_string(connection.verdict) != "" ? as_string(connection.verdict) : "failed", message: as_string(connection.message) };
    }

    if (as_string(target.kind) == "tcp" || as_string(target.kind) == "udp" || as_string(target.kind) == "udp_dns")
        return int(connection.total_ms) > SLOW_THRESHOLD_MS
            ? { state: "warning", verdict: "slow", message: "соединение установлено, но медленно" }
            : { state: "success", verdict: "ok", message: "" };

    let code = int(connection.code);
    let expected = code_expected(code, target);

    // Мы проверяем достижимость, а не семантику API: раз пришёл любой HTTP-ответ,
    // значит DNS, TCP, TLS и HTTP отработали и путь до сервиса живой. Коды вроде
    // 404 на голом корне CDN - это норма, а не проблема сети. Особые случаи ниже.
    if (code >= 500)
        return { state: "warning", verdict: "http_server_error", message: sprintf("сервис отвечает ошибкой %d", code) };

    if (!expected && (code == 403 || code == 451))
        return { state: "warning", verdict: "geo_blocked", message: sprintf("ответ %d — похоже на блокировку по IP или региону", code) };

    if (int(connection.total_ms) > SLOW_THRESHOLD_MS)
        return { state: "warning", verdict: "slow", message: sprintf("работает, но медленно: %d мс", int(connection.total_ms)) };

    if (!expected)
        return { state: "success", verdict: "ok", message: sprintf("ответ %d — нетипичный, но соединение проходит", code) };

    return { state: "success", verdict: "ok", message: "" };
}

function service_state(items) {
    let required_total = 0;
    let required_ok = 0;
    let has_warning = false;

    for (let item in items) {
        if (item.optional || item.state == "skipped")
            continue;

        required_total++;
        if (item.state == "success")
            required_ok++;
        else if (item.state == "warning") {
            required_ok++;
            has_warning = true;
        }
    }

    if (required_total == 0)
        return { state: "warning", description: "проверить не удалось" };
    if (required_ok == 0)
        return { state: "error", description: "не работает" };
    if (required_ok < required_total)
        return { state: "warning", description: sprintf("работает частично (%d из %d)", required_ok, required_total) };
    if (has_warning)
        return { state: "warning", description: "работает с замечаниями" };

    return { state: "success", description: "работает" };
}

// ---------------------------------------------------------------------------
// Запуск проверки
// ---------------------------------------------------------------------------

// ВАЖНО: в ucode нет подъёма объявлений - функция, объявленная ниже по файлу,
// не видна объявленной выше (вызов компилируется как обращение к глобали и падает
// в рантайме). Поэтому порядок объявлений здесь значим: сначала зависимости.

function netns_teardown() {
    run_quiet([ "ip", "netns", "del", NETNS_NAME ]);
    run_quiet([ "ip", "link", "del", NETNS_VETH_HOST ]);
    run_quiet([ "rm", "-rf", "/etc/netns/" + NETNS_NAME ]);
}

function leased_addresses() {
    let leases = {};
    let data = fs.readfile("/tmp/dhcp.leases");
    if (data == null)
        return leases;

    for (let line in split(as_string(data), "\n")) {
        let fields = words(line);
        if (length(fields) >= 3 && valid_ipv4(fields[2]))
            leases[fields[2]] = true;
    }

    return leases;
}

function address_free(candidate, leases) {
    if (leases[candidate])
        return false;
    // Не используем ICMP: некоторые провайдеры и сетевые фильтры реагируют на
    // массовые echo-запросы. Проверяем только ARP/маршрут через HTTPS.
    if (command_exists("curl")) {
        let result = capture_args([ "curl", "-k", "-sS", "-o", "/dev/null",
            "--connect-timeout", "1", "--max-time", "2", "https://" + candidate + "/" ], false);
        // Любой ответ HTTPS означает занятый адрес; ошибки маршрута/таймаута
        // оставляют возможность использовать кандидат.
        return result.status == 6 || result.status == 7 || result.status == 28;
    }
    return true;
}

function pick_client_ip(caps, requested) {
    requested = as_string(requested);
    if (valid_ipv4(requested))
        return requested;

    let prefix = int(caps.lan_prefix);
    if (!valid_ipv4(caps.lan_address) || prefix < 16 || prefix > 30)
        return "";

    let mask = prefix_mask(prefix);
    let router_value = ipv4_to_int(caps.lan_address);
    let network = router_value & mask;
    let size = 1 << (32 - prefix);
    let broadcast = network + size - 1;
    let leases = leased_addresses();

    // Берём адреса с верхнего края подсети - там DHCP-пул OpenWrt заканчивается раньше.
    for (let offset = 1; offset <= 8; offset++) {
        let candidate_value = broadcast - offset;
        if (candidate_value <= network || candidate_value == router_value)
            continue;
        let candidate = int_to_ipv4(candidate_value);
        if (address_free(candidate, leases))
            return candidate;
    }

    return "";
}

function netns_setup(caps, requested_ip) {
    if (!caps.netns)
        return { ok: false, error: "режим клиента недоступен: нет поддержки ip netns" };

    netns_teardown();

    let client_ip = pick_client_ip(caps, requested_ip);
    if (client_ip == "")
        return { ok: false, error: "не удалось подобрать свободный IP в LAN" };

    let prefix = as_string(int(caps.lan_prefix));
    let steps = [
        [ "ip", "netns", "add", NETNS_NAME ],
        [ "ip", "link", "add", NETNS_VETH_HOST, "type", "veth", "peer", "name", NETNS_VETH_PEER ],
        [ "ip", "link", "set", NETNS_VETH_PEER, "netns", NETNS_NAME ],
        [ "ip", "link", "set", NETNS_VETH_HOST, "master", caps.lan_interface ],
        [ "ip", "link", "set", NETNS_VETH_HOST, "up" ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "link", "set", "lo", "up" ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "addr", "add", client_ip + "/" + prefix, "dev", NETNS_VETH_PEER ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "link", "set", NETNS_VETH_PEER, "up" ],
        [ "ip", "netns", "exec", NETNS_NAME, "ip", "route", "add", "default", "via", caps.lan_address ]
    ];

    for (let step in steps) {
        if (!run_quiet(step)) {
            netns_teardown();
            return { ok: false, error: "не удалось выполнить: " + join(" ", step) };
        }
    }

    run_quiet([ "mkdir", "-p", "/etc/netns/" + NETNS_NAME ]);
    if (fs.writefile("/etc/netns/" + NETNS_NAME + "/resolv.conf", "nameserver " + caps.lan_address + "\n") == null) {
        netns_teardown();
        return { ok: false, error: "не удалось записать resolv.conf для namespace" };
    }

    return { ok: true, client_ip, error: "" };
}

function build_context(mode, client_ip) {
    let caps = capabilities();
    let ctx = {
        tools: {
            curl: caps.curl,
            uclient_fetch: caps.uclient_fetch,
            dig: caps.dig,
            nslookup: caps.nslookup,
            nc: caps.nc,
            nc_mode: caps.nc_mode,
            timeout_cmd: caps.timeout_cmd
        },
        fakeip_ranges: caps.fakeip_ranges,
        resolver: "127.0.0.1",
        exec_prefix: [],
        mode: as_string(mode) == "netns" ? "netns" : "router",
        lan_interface: caps.lan_interface,
        lan_address: caps.lan_address,
        backend: caps.backend,
        backend_name: caps.backend_name,
        backend_running: caps.backend_running,
        forkop_running: caps.forkop_running,
        client_ip: "",
        netns_error: ""
    };

    if (ctx.mode != "netns")
        return ctx;

    let netns = netns_setup(caps, client_ip);
    if (!netns.ok) {
        ctx.mode = "router";
        ctx.netns_error = netns.error;
        return ctx;
    }

    ctx.exec_prefix = [ "ip", "netns", "exec", NETNS_NAME ];
    ctx.resolver = caps.lan_address != "" ? caps.lan_address : "127.0.0.1";
    ctx.client_ip = netns.client_ip;
    ctx.netns_active = true;
    return ctx;
}

function probe_target(ctx, target) {
    target = object_or_empty(target);
    let host = as_string(target.host);
    let dns = probe_dns(ctx, host);
    let connection = { reached: false, code: 0, tcp_ms: 0, tls_ms: 0, total_ms: 0, remote_ip: "", verdict: "", message: "" };

    if (dns.ok)
        connection = connection_probe(ctx, target);
    else
        connection.verdict = "dns_fail";

    let verdict = target_verdict(target, dns, connection);

    return {
        label: target_label(target),
        kind: as_string(target.kind || "https"),
        host,
        port: int(target.port || (as_string(target.kind) == "http" ? 80 : 443)),
        url: as_string(target.kind) == "tcp" ? "" : target_url(target),
        optional: target.optional === true,
        dns_ok: dns.ok,
        dns_ip: as_string(dns.ip),
        dns_fakeip: dns.fakeip === true,
        dns_ms: int(dns.ms),
        remote_ip: as_string(connection.remote_ip),
        http_code: int(connection.code),
        tcp_ms: int(connection.tcp_ms),
        tls_ms: int(connection.tls_ms),
        total_ms: int(connection.total_ms),
        outbound: "",
        state: verdict.state,
        verdict: verdict.verdict,
        message: verdict.message
    };
}

function probe_service(ctx, profile) {
    profile = object_or_empty(profile);
    let items = [];

    for (let target in array_or_empty(profile.targets))
        push(items, probe_target(ctx, target));

    // Атрибуция маршрута - best effort: Clash API отдаёт только живые соединения,
    // а короткие HTTP-запросы к моменту опроса часто уже закрыты. Поэтому один
    // запрос на сервис, а не на каждую цель, и пустой результат не считается ошибкой.
    if (ctx.backend_running) {
        let connections = clash_connections();
        if (length(connections) > 0) {
            for (let item in items) {
                if (!item.state || item.state == "skipped")
                    continue;
                item.outbound = outbound_for(connections, item.host, item.remote_ip);
            }
        }
    }

    let summary = service_state(items);

    return {
        id: as_string(profile.id),
        title: as_string(profile.title),
        group: as_string(profile.group),
        description: as_string(profile.description),
        state: summary.state,
        description_result: summary.description,
        items
    };
}

function custom_check(host, port, mode, client_ip) {
    host = lc(trim(as_string(host)));
    if (length(host) > 0 && substr(host, length(host) - 1, 1) == ".")
        host = substr(host, 0, length(host) - 1);

    port = int(port || 443);
    if (!valid_custom_host(host))
        return { success: false, message: "Введите корректный IPv4-адрес или домен без протокола и пути" };
    if (port < 1 || port > 65535)
        return { success: false, message: "TCP-порт должен быть от 1 до 65535" };

    let ctx = build_context(mode, client_ip);
    let dns = probe_dns(ctx, host);
    let remote_ip = dns.ok ? as_string(dns.ip) : (valid_ipv4(host) ? host : "");
    let live_route = detect_live_route(ctx, host, port, remote_ip);
    let item = probe_target(ctx, {
        kind: "tcp",
        host,
        port,
        label: host + ":" + as_string(port)
    });

    let through_sing_box = null;
    let route_status = "unknown";
    let route_message = "Маршрут не удалось подтвердить через Clash API.";
    let evidence = "";

    if (!ctx.backend_running) {
        through_sing_box = false;
        route_status = "direct";
        evidence = "backend_stopped";
        route_message = ctx.backend_name + " остановлен: соединение не проходит через sing-box.";
    }
    else if (live_route.seen) {
        through_sing_box = true;
        route_status = "sing-box";
        evidence = "clash_api";
        item.outbound = live_route.outbound;
        route_message = live_route.outbound != ""
            ? "Соединение найдено в sing-box; outbound: " + live_route.outbound
            : "Соединение найдено среди активных соединений sing-box.";
    }
    else if (item.dns_fakeip) {
        through_sing_box = true;
        route_status = "sing-box";
        evidence = "fakeip";
        route_message = "Домен получил FakeIP, который обслуживается sing-box.";
    }
    else if (live_route.attempted && item.state != "error" && item.state != "skipped") {
        through_sing_box = false;
        route_status = "direct";
        evidence = "clash_api_absent";
        route_message = "Соединение доступно, но за время теста не появилось в Clash API: маршрут идёт мимо sing-box.";
    }
    else if (item.state == "error") {
        route_message = "Соединение не установлено, поэтому определить маршрут нельзя.";
    }

    if (ctx.netns_active)
        netns_teardown();

    return {
        success: true,
        target: host,
        port,
        mode: ctx.mode,
        requested_mode: as_string(mode) == "netns" ? "netns" : "router",
        client_ip: as_string(ctx.client_ip),
        netns_error: as_string(ctx.netns_error),
        backend: ctx.backend,
        backend_name: ctx.backend_name,
        backend_running: ctx.backend_running,
        forkop_running: ctx.forkop_running,
        route: {
            status: route_status,
            through_sing_box,
            outbound: as_string(item.outbound),
            evidence,
            message: route_message
        },
        item
    };
}

function selected_profiles(ids) {
    ids = trim(as_string(ids));
    let all = load_profiles();

    if (ids == "" || ids == "all")
        return all;

    let wanted = {};
    for (let id in split(ids, ","))
        wanted[trim(as_string(id))] = true;

    let result = [];
    for (let profile in all)
        if (wanted[as_string(object_or_empty(profile).id)])
            push(result, profile);

    return result;
}

// Состояние фоновых заданий. Объявлено до run_check, потому что тот пишет в него
// прогресс по ходу проверки, а forward-ссылок ucode не прощает.

function job_id_valid(value) {
    value = as_string(value);
    return value != "" && match(value, /^[A-Za-z0-9_-]+$/) != null;
}

function job_path(job_id) {
    return job_id_valid(job_id) ? STATE_DIR + "/" + as_string(job_id) + ".json" : "";
}

function write_state(path, value) {
    ensure_state_dir();
    return fs.writefile(as_string(path), sprintf("%J", value) + "\n") != null;
}

function update_progress(path, done, total, services) {
    let state = object_or_empty(read_json_file(path));
    if (!state.running)
        return;
    state.progress = { done: int(done), total: int(total) };
    state.services = services;
    write_state(path, state);
}

function run_check(ids, mode, client_ip, progress_path) {
    let profiles = selected_profiles(ids);
    let ctx = build_context(mode, client_ip);
    let services = [];
    let total = 0;

    for (let profile in profiles)
        total += length(array_or_empty(object_or_empty(profile).targets));

    let done = 0;

    for (let profile in profiles) {
        let result = probe_service(ctx, profile);
        push(services, result);
        done += length(result.items);
        if (as_string(progress_path) != "")
            update_progress(progress_path, done, total, services);
    }

    if (ctx.netns_active)
        netns_teardown();

    return {
        generated_at: now_seconds(),
        mode: ctx.mode,
        requested_mode: as_string(mode) == "netns" ? "netns" : "router",
        netns_error: as_string(ctx.netns_error),
        client_ip: as_string(ctx.client_ip),
        resolver: ctx.resolver,
        backend: ctx.backend,
        backend_name: ctx.backend_name,
        backend_running: ctx.backend_running,
        forkop_running: ctx.forkop_running,
        tools: ctx.tools,
        fakeip_ranges: ctx.fakeip_ranges,
        progress: { done, total },
        services
    };
}

// ---------------------------------------------------------------------------
// Фоновые задания
// ---------------------------------------------------------------------------

function cleanup_jobs() {
    ensure_state_dir();
    let now = now_seconds();
    for (let path in fs.glob(STATE_DIR + "/*.json")) {
        let state = object_or_empty(read_json_file(path));
        let started = int(state.started_at || 0);
        if (started > 0 && now - started > JOB_MAX_AGE)
            fs.unlink(path);
    }
}

function start_job(ids, mode, client_ip) {
    ensure_state_dir();
    cleanup_jobs();

    let job_id = sprintf("sc-%d-%d", now_seconds(), int(now_ms() % 100000));
    let path = job_path(job_id);
    if (path == "") {
        write_json({ success: false, message: "не удалось создать задание" });
        return 1;
    }

    let profiles = selected_profiles(ids);
    let total = 0;
    for (let profile in profiles)
        total += length(array_or_empty(object_or_empty(profile).targets));

    if (length(profiles) == 0) {
        write_json({ success: false, message: "не выбран ни один сервис" });
        return 1;
    }

    let state = {
        kind: "service_check",
        job_id,
        running: true,
        success: false,
        started_at: now_seconds(),
        finished_at: 0,
        mode: as_string(mode) == "netns" ? "netns" : "router",
        ids: as_string(ids),
        progress: { done: 0, total },
        services: []
    };

    if (!write_state(path, state)) {
        write_json({ success: false, message: "не удалось записать состояние задания" });
        return 1;
    }

    let worker = command_from_args([
        "ucode", "-L", LIB_DIR, ENGINE, "worker", path, as_string(ids), as_string(mode), as_string(client_ip)
    ]);
    system("(" + worker + " >/dev/null 2>&1 &)");

    write_json({ success: true, job_id, progress: state.progress });
    return 0;
}

function worker(path, ids, mode, client_ip) {
    let result = run_check(ids, mode, client_ip, path);
    let state = object_or_empty(read_json_file(path));

    state.running = false;
    state.success = true;
    state.finished_at = now_seconds();
    state.services = result.services;
    state.resolver = result.resolver;
    state.tools = result.tools;
    state.fakeip_ranges = result.fakeip_ranges;
    state.progress = result.progress;
    state.mode = result.mode;
    state.netns_error = result.netns_error;
    state.client_ip = result.client_ip;
    state.backend = result.backend;
    state.backend_name = result.backend_name;
    state.backend_running = result.backend_running;
    state.forkop_running = result.forkop_running;

    write_state(path, state);
    return 0;
}

function job_status(job_id) {
    let path = job_path(job_id);
    if (path == "" || fs.stat(path) == null) {
        write_json({ success: false, running: false, message: "задание не найдено" });
        return 1;
    }

    let state = object_or_empty(read_json_file(path));
    if (length(keys(state)) == 0) {
        write_json({ success: false, running: false, message: "не удалось прочитать состояние задания" });
        return 1;
    }

    write_json(state);
    return 0;
}

function list_profiles() {
    let data = object_or_empty(read_json_file(profiles_file()));
    let profiles = [];

    for (let profile in array_or_empty(data.profiles)) {
        profile = object_or_empty(profile);
        push(profiles, {
            id: as_string(profile.id),
            title: as_string(profile.title),
            group: as_string(profile.group),
            description: as_string(profile.description),
            targets: length(array_or_empty(profile.targets))
        });
    }

    write_json({ version: int(data.version || 0), updated: as_string(data.updated), profiles });
    return 0;
}

function gemini_key_set(value) {
    let key = trim(as_string(value));
    if (match(key, /^[A-Za-z0-9_-]{20,200}$/) == null) {
        write_json({ success: false, message: "ключ имеет недопустимый формат" });
        return 1;
    }

    run_quiet([ "mkdir", "-p", CONFIG_DIR ]);
    if (fs.writefile(GEMINI_API_KEY_FILE, key + "\n") == null) {
        write_json({ success: false, message: "не удалось сохранить ключ" });
        return 1;
    }

    run_quiet([ "chmod", "600", GEMINI_API_KEY_FILE ]);
    write_json({ success: true, configured: true, message: "ключ сохранён" });
    return 0;
}

function gemini_key_reset() {
    fs.unlink(GEMINI_API_KEY_FILE);
    write_json({ success: true, configured: false, message: "ключ удалён" });
    return 0;
}

function gemini_key_status() {
    let configured = read_gemini_api_key() != "";
    write_json({ success: true, configured, message: configured ? "используется пользовательский ключ" : "ключ не задан" });
    return 0;
}

// ---------------------------------------------------------------------------

function tachyon_get_targets(all_mode) {
    let all_profiles_json = load_profiles_data();
    let all_profiles = object_or_empty(parse_json(all_profiles_json));
    if (type(all_profiles.profiles) != "array") all_profiles.profiles = [];
    let profiles_map = {};
    for (let i = 0; i < length(all_profiles.profiles); i++) {
        let p = all_profiles.profiles[i];
        profiles_map[p.id] = p;
    }

    let targets = [];
    let seen_domains = {};

    let sections = uci_core.section_objects("tachyon", "section");

    if (all_mode == "all") {
        // 1. Include ALL Community Profiles
        for (let i = 0; i < length(all_profiles.profiles); i++) {
            let profile = all_profiles.profiles[i];
            let profile_title = profile.title || profile.name || profile.id;
            for (let j = 0; j < length(profile.targets); j++) {
                let t = profile.targets[j];
                let host = t.host || t.query || "";
                if (!host || seen_domains[host]) continue;
                seen_domains[host] = true;

                push(targets, {
                    section: profile_title,
                    route_type: "auto",
                    domain: host,
                    port: t.port || (t.kind == "https" ? 443 : 80),
                    kind: t.kind,
                    path: t.path || "/",
                    expect: t.expect || [200, 301, 302],
                    target_label: t.label || host
                });
            }
        }

        // 2. Include custom user domains from all UCI sections
        for (let s in sections) {
            let raw_name = as_string(s['.name']);
            let custom_label = as_string(s.label);
            let has_custom_label = custom_label != "" && custom_label != raw_name && match(custom_label, /^section_\d+$/) == null && match(custom_label, /^cfg[0-9a-fA-F]+$/) == null;
            let label = has_custom_label ? custom_label : "Свои домены";
            let route_type = s.action || "direct";
            if (s.action == "zapret" && s.zapret_strategy) route_type = "zapret (" + s.zapret_strategy + ")";
            else if (s.action == "zapret2" && s.zapret2_strategy) route_type = "zapret2 (" + s.zapret2_strategy + ")";
            else if (s.action == "byedpi" && s.byedpi_strategy) route_type = "byedpi (" + s.byedpi_strategy + ")";

            let custom_domains = [];
            let lists = type(s.user_domains) == "array" ? s.user_domains : [ s.user_domains ];
            for (let d in lists) {
                if (!d) continue;
                for (let line in split(as_string(d), /[\n\r,]+/)) {
                    let domain_str = trim(replace(line, /^\*?\./, ""));
                    if (domain_str != "" && substr(domain_str, 0, 1) != "#")
                        push(custom_domains, domain_str);
                }
            }

            if (s.user_domains_text) {
                for (let line in split(as_string(s.user_domains_text), /[\n\r,]+/)) {
                    let domain_str = trim(replace(line, /^\*?\./, ""));
                    if (domain_str != "" && substr(domain_str, 0, 1) != "#")
                        push(custom_domains, domain_str);
                }
            }

            for (let cd in custom_domains) {
                if (seen_domains[cd]) continue;
                seen_domains[cd] = true;
                push(targets, {
                    section: label,
                    route_type: route_type,
                    domain: cd,
                    port: 443,
                    kind: "https",
                    path: "/",
                    expect: [200, 301, 302, 307, 400, 403, 404, 405, 426],
                    target_label: cd
                });
            }
        }

        write_json(targets);
        return;
    }

    // Active mode (default): Check targets in active enabled UCI sections
    seen_domains = {};
    const profile_aliases = {
        "meta": "instagram",
        "twitter": "x",
        "cloudflare": "baseline",
        "google_ai": "gemini",
        "geoblock": "blocked_ru",
        "russia_inside": "blocked_ru",
        "russia_outside": "blocked_ru",
        "hodca": "hdrezka"
    };

    for (let s in sections) {
        if (s.enabled == "0" || s.enabled == "false") continue;
        
        let profiles_to_check = [];
        let raw_community = s.community_lists;
        
        const resolve_profile = function(id) {
            let real_id = profile_aliases[id] || id;
            if (profiles_map[real_id]) return profiles_map[real_id];
            return null;
        };

        if (type(raw_community) == "array") {
            for (let item in raw_community) {
                if (!item) continue;
                for (let part in split(as_string(item), /[\s,]+/)) {
                    let id = trim(part);
                    let p = resolve_profile(id);
                    if (p) push(profiles_to_check, p);
                }
            }
        } else if (type(raw_community) == "string") {
            for (let part in split(as_string(raw_community), /[\s,]+/)) {
                let id = trim(part);
                let p = resolve_profile(id);
                if (p) push(profiles_to_check, p);
            }
        }
        
        let raw_name = as_string(s['.name']);
        let custom_label = as_string(s.label);
        let has_custom_label = custom_label != "" && custom_label != raw_name && match(custom_label, /^section_\d+$/) == null && match(custom_label, /^cfg[0-9a-fA-F]+$/) == null;
        let route_type = s.action || "direct";
        
        if (s.action == "zapret" && s.zapret_strategy) route_type = "zapret (" + s.zapret_strategy + ")";
        else if (s.action == "zapret2" && s.zapret2_strategy) route_type = "zapret2 (" + s.zapret2_strategy + ")";
        else if (s.action == "byedpi" && s.byedpi_strategy) route_type = "byedpi (" + s.byedpi_strategy + ")";

        for (let i = 0; i < length(profiles_to_check); i++) {
            let profile = profiles_to_check[i];
            let profile_title = profile.title || profile.name || profile.id;
            let display_section = has_custom_label ? custom_label : profile_title;

            for (let j = 0; j < length(profile.targets); j++) {
                let t = profile.targets[j];
                let host = t.host || t.query || "";
                if (!host || seen_domains[host]) continue;
                seen_domains[host] = true;

                push(targets, {
                    section: display_section,
                    route_type: route_type,
                    domain: host,
                    port: t.port || (t.kind == "https" ? 443 : 80),
                    kind: t.kind,
                    path: t.path || "/",
                    expect: t.expect || [200, 301, 302],
                    target_label: t.label || host
                });
            }
        }

        let custom_domains = [];
        let lists = type(s.user_domains) == "array" ? s.user_domains : [ s.user_domains ];
        for (let d in lists) {
            if (!d) continue;
            for (let line in split(as_string(d), /[\n\r,]+/)) {
                let domain_str = trim(replace(line, /^\*?\./, ""));
                if (domain_str != "" && substr(domain_str, 0, 1) != "#" && substr(domain_str, 0, 2) != "//")
                    push(custom_domains, domain_str);
            }
        }

        if (s.user_domains_text) {
            for (let line in split(as_string(s.user_domains_text), /[\n\r,]+/)) {
                let domain_str = trim(replace(line, /^\*?\./, ""));
                if (domain_str != "" && substr(domain_str, 0, 1) != "#" && substr(domain_str, 0, 2) != "//")
                    push(custom_domains, domain_str);
            }
        }

        let custom_section = has_custom_label ? custom_label : "Свои домены";
        for (let cd in custom_domains) {
            if (!cd || seen_domains[cd]) continue;
            seen_domains[cd] = true;

            push(targets, {
                section: custom_section,
                route_type: route_type,
                domain: cd,
                port: 443,
                kind: "https",
                path: "/",
                expect: [200, 301, 302, 307, 400, 403, 404, 405, 426],
                target_label: cd
            });
        }
    }
    
    write_json(targets);
}

function tachyon_check_target(target_json_str) {
    let t = parse_json(target_json_str);
    if (!t) {
        write_json([{ success: false, status_class: "Error parsing target" }]);
        return;
    }
    
    if (!t.host && t.domain) t.host = t.domain;
    
    let ctx = build_context("router", "");
    let item = probe_target(ctx, t);
    
    let http_time = item.total_ms - item.tcp_ms - item.tls_ms;
    if (http_time < 0) http_time = 0;
    
    let result = [{
        section: t.section || "Custom",
        route_type: t.route_type || "auto",
        domain: t.target_label || t.host,
        ip: item.remote_ip || item.dns_ip || "",
        dns_ms: item.dns_ms || 0,
        tcp_ms: item.tcp_ms || 0,
        tls_ms: item.tls_ms || 0,
        http_ms: http_time || 0,
        status_class: item.state == "success" ? "OK" : (item.message || item.verdict || "Error"),
        success: item.state == "success"
    }];
    write_json(result);
}

let mode = as_string(ARGV[0]);

if (mode == "get-targets") {
    tachyon_get_targets(ARGV[1]);
} else if (mode == "check-domain" && ARGV[1]) {
    tachyon_check_target(ARGV[1]);
} else if (mode == "check-custom" && ARGV[1]) {
    let custom_target = {
        kind: "https",
        host: ARGV[1],
        port: 443,
        path: "/",
        expect: [200, 301, 302, 307, 400, 403, 404, 405, 426]
    };
    tachyon_check_target(sprintf("%J", custom_target));
} else if (mode == "update-profiles" || mode == "download-profiles") {
    let data = download_profiles_from_repo();
    let parsed = object_or_empty(parse_json(data));
    let count = length(array_or_empty(parsed.profiles));
    write_json({ success: data != null, count: count, message: data != null ? "Профили успешно загружены и обновлены" : "Не удалось загрузить профили" });
} else if (mode == "get-profiles") {
    profiles_get();
} else if (mode == "save-profiles" && ARGV[1]) {
    profiles_save(ARGV[1]);
} else if (mode == "reset-profiles") {
    profiles_reset();
} else {
    warn("Unknown mode: ", mode, "\n");
    exit(1);
}
