// Install the optional helper before lifecycle changes the running network.
let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let uci = require("core.uci");
let helpers = require("components.helpers");

const BIN = getenv("TACHYON_SMART_CONNECT_BIN") || "/usr/bin/tachyon-smart-connect";
const LIB = getenv("TACHYON_LIB") || "/usr/lib/tachyon";
const LOCK = (getenv("TACHYON_RUNTIME_STATE_DIR") || "/var/run/tachyon") + "/smart-connect-install.lock";

function architecture(host, distrib) {
    // Package architecture describes userspace, including MIPS endianness.
    // uname alone reports "mips" on little-endian MT7621 routers.
    for (let i, value in [lc(trim(common.as_string(distrib))), lc(trim(common.as_string(host)))]) {
        if (match(value, /^(mips64el|mips64le)/)) return "mips64el";
        if (match(value, /^mips64/)) return "mips64";
        if (match(value, /^(mipsel|mipsle)/)) return "mipsel";
        if (match(value, /^mips/)) return "mips";
        if (match(value, /^(aarch64|arm64)/)) return "aarch64";
        if (match(value, /^(x86_64|amd64)([_-]|$)/)) return "x86_64";
        if (match(value, /^(i[3-6]86|x86|386)([_-]|$)/)) return "i386";
        if (match(value, /^riscv64/)) return "riscv64";
        if (match(value, /^armv[78]/) || match(value, /^arm_cortex-a/)) return "armv7";
        if (match(value, /^armv6/) || match(value, /^arm_arm1176/)) return "armv6";
        if (match(value, /^arm/)) return "armv5";
        // Never substitute a kernel architecture for known unsupported userspace.
        if (i == 0 && value != "") return "";
    }
    return "";
}

function release_assets(release, repo, version, arch) {
    let tag = release?.tag_name;
    if (release?.draft || (tag != version && tag != "v" + version)) return null;
    let archive = "tachyon-smart-connect-" + arch + "-" + version + ".tar.gz";
    let sums = "SHA256SUMS-smart-connect.txt", found = {};
    for (let asset in release.assets || []) found[asset.name] = asset;
    if (!found[archive] || !found[sums]) return null;
    let size = int(found[archive].size || 0);
    if (size <= 0 || size > 20 * 1024 * 1024) return null;
    let base = "https://github.com/" + repo + "/releases/download/" + tag + "/";
    return {name:archive, archive:base + archive, sums:base + sums, size};
}

function checksum(manifest, name) {
    let result = "";
    for (let line in split(manifest || "", "\n")) {
        let m = match(line, /^([a-fA-F0-9]{64})[ \t]+\*?([^\r\n]+)\r?$/);
        if (m && trim(m[2]) == name) {
            if (result != "") return "";
            result = lc(m[1]);
        }
    }
    return result;
}

function elf(path) {
    let file = fs.open(path, "r");
    if (!file) return false;
    let header = file.read(4);
    file.close();
    return header == "\x7fELF";
}

function installed() {
    let st = fs.stat(BIN);
    return st?.type == "file" && (st.mode & 0111) != 0 && elf(BIN);
}

function failure(message) {
    warn("Smart Connect: ", message, ". The running network was not changed.\n");
    helpers.updates_log("Smart Connect: " + message, "error");
    return false;
}

function install_binary() {
    let version = replace(common.as_string(constants.TACHYON_VERSION), /^v/, "");
    version = replace(version, /-r[0-9]+$/, "");
    let repo = getenv("TACHYON_RELEASE_REPO") || constants.TACHYON_RELEASE_REPO;
    if (!match(version, /^[0-9]+\.[0-9]+\.[0-9]+$/) ||
        !match(repo || "", /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/))
        return failure("cannot determine this backend's release; install a released Tachyon build");
    let distrib = helpers.read_openwrt_release_value("DISTRIB_ARCH") || trim(fs.readfile("/etc/apk/arch") || "");
    let host = trim(common.command_output_from_args(["uname", "-m"]));
    let arch = architecture(host, distrib);
    if (arch == "") return failure("unsupported router architecture: " + (distrib || host));

    let downloader = require("components.downloader");
    let parts = split(repo, "/"), asset = null;
    for (let tag in ["v" + version, version]) {
        let response = downloader.fetch_github_release_by_tag_json(parts[0], parts[1], tag);
        try { asset = release_assets(json(response), repo, version, arch); } catch (e) {}
        if (asset) break;
    }
    if (!asset) return failure("helper for " + arch + " is unavailable in Tachyon " + version + "; retry after the release download is available");
    if (!helpers.preflight_storage_check("smart-connect", asset.size * 4, false))
        return failure("insufficient temporary space to install the helper");

    let work = trim(common.command_output_from_args(["mktemp", "-d", "/tmp/tachyon-smart-connect-install.XXXXXX"]));
    if (work == "") return failure("cannot create an installation directory");
    fs.chmod(work, 0700);
    let staged = "";
    let operation = function() {
        helpers.updates_log("Installing Smart Connect helper for " + arch + " from Tachyon " + version);
        let archive = work + "/helper.tar.gz", sums = work + "/SHA256SUMS";
        if (!downloader.download_with_retry(asset.sums, sums, "Smart Connect checksums") ||
            !downloader.download_with_retry(asset.archive, archive, "Smart Connect helper"))
            return failure("helper download failed; check Internet access and retry");
        let expected = checksum(fs.readfile(sums), asset.name);
        let actual = split(trim(common.command_output_from_args(["sha256sum", archive])), /[ \t]+/)[0];
        if (expected == "" || actual != expected) return failure("helper checksum verification failed");
        // Extract only our one regular member. Reject links, paths and extra files.
        let member = trim(common.command_output_from_args(["tar", "-tzf", archive]));
        let listing = trim(common.command_output_from_args(["tar", "-tvzf", archive]));
        if ((member != "tachyon-smart-connect" && member != "./tachyon-smart-connect") ||
            substr(listing, 0, 1) != "-" || index(listing, "\n") >= 0)
            return failure("unexpected helper archive contents");
        if (!common.command_success_from_args(["tar", "-xzf", archive, "-C", work, member]))
            return failure("cannot unpack the helper");
        let candidate = work + "/tachyon-smart-connect", st = fs.stat(candidate);
        if (st?.type != "file" || st.size <= 4 || st.size > 32 * 1024 * 1024 || !elf(candidate))
            return failure("downloaded helper is not a supported executable");
        fs.chmod(candidate, 0700);
        let check = {listen_auto:"127.0.0.1:14700", listen_zapret:"127.0.0.1:14701",
            direct_proxy:"127.0.0.1:14710", zapret_proxy:"127.0.0.1:14711", vpn_proxy:"127.0.0.1:14712",
            direct_dns:"127.0.0.1:14720", zapret_dns:"127.0.0.1:14721"};
        if (!common.write_json_file(work + "/check.json", check) ||
            !common.command_success(common.bounded_command(common.command_from_args([candidate, "-check", "-config", work + "/check.json"]), 5)))
            return failure("helper cannot run on this router");
        let parent = replace(BIN, /\/[^\/]+$/, "");
        if (!helpers.check_free_disk_space(parent, st.size)) return failure("insufficient storage for the helper");
        // Stage on the destination filesystem so activation is an atomic rename.
        staged = trim(common.command_output_from_args(["mktemp", BIN + ".XXXXXX"]));
        if (staged == "" || !common.command_success_from_args(["cp", candidate, staged]) ||
            !fs.chmod(staged, 0755) || !fs.rename(staged, BIN))
            return failure("cannot install the helper; free storage and retry");
        staged = "";
        helpers.updates_log("Smart Connect helper installed successfully");
        return true;
    };
    let result = false;
    try { result = operation(); }
    catch (e) { failure("helper installation failed: " + e); }
    if (staged != "") fs.unlink(staged);
    common.command_success_from_args(["rm", "-rf", work]);
    return result;
}

function ensure() {
    let cfg = uci.get_all(getenv("TACHYON_CONFIG_NAME") || "tachyon", "settings") || {};
    if (cfg.smart_detect != "1" || cfg.smart_detect_chain != "1") return true;
    if (installed()) return true;
    if (index(["tachyon-core", "sing-box"], cfg.engine || "tachyon-core") < 0)
        return failure("this routing engine does not support the automatic chain");
    if (!helpers.ensure_dir(replace(LOCK, /\/[^\/]+$/, "")))
        return failure("cannot create the runtime installation directory");
    let owner = split(fs.readfile("/proc/self/stat") || "", " ")[0];
    if (!match(owner, /^[0-9]+$/)) return failure("cannot identify the installer process");
    // Lifecycle and a second UI request may meet during first installation.
    if (!common.command_success_from_args(["ucode", "-L", LIB, LIB + "/service/state.uc",
            "acquire-runtime-dir-lock-wait", LOCK, owner, "120"]))
        return failure("another helper installation is in progress; retry shortly");
    let result = false;
    try { result = installed() || install_binary(); }
    catch (e) { failure("helper installation failed: " + e); }
    helpers.cleanup_tmp_dir();
    common.command_success_from_args(["ucode", "-L", LIB, LIB + "/service/state.uc", "release-runtime-dir-lock", LOCK]);
    return result;
}

if ((sourcepath(1) == null || sourcepath(1) == "") && ARGV[0] == "ensure") exit(ensure() ? 0 : 1);
return {architecture, release_assets, checksum, ensure};
