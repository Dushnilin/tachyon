#!/usr/bin/env ucode
//
// Release catalog for component updates: latest-version lookups, GitHub
// release resolution per component, arch candidate detection, version
// caches and the installed-build fingerprint store.
//

let common = require("core.common");

let helpers = require("components.helpers");
let versions = require("components.versions");
let downloader = require("components.downloader");

let as_string = common.as_string;
let command_output_from_args = common.command_output_from_args;
let command_success_from_args = common.command_success_from_args;
let write_file = common.write_file;

const TACHYON_RELEASE_REPO = getenv("TACHYON_RELEASE_REPO") || "Dushnilin/tachyon";
const SYSTEM_INFO_CACHE_FILE = getenv("TACHYON_SYSTEM_INFO_CACHE_FILE") || "/var/run/tachyon/system-info.json";
// Persistent, not RUNTIME_STATE_DIR: the fingerprint describes the build that is
// on disk, so it has to survive a reboot the same way the package does.
const TACHYON_BUILD_STATE_FILE = getenv("TACHYON_BUILD_STATE_FILE") || "/etc/.tachyon/build-state";


// Forward-referenced helpers

function latest_tachyon_release_json() {
    let parts = split(TACHYON_RELEASE_REPO, "/");
    if (length(parts) != 2 || as_string(parts[0]) == "" || as_string(parts[1]) == "")
        return "";
    return downloader.fetch_github_release_json(parts[0], parts[1]);
}

function latest_tachyon_version() {
    let response = latest_tachyon_release_json();
    let version = "";
    if (response != "") {
        version = trim(helpers.helper_output_input(response, "object-get-default", [ "tag_name", "" ]));
    }
    if (version == "") {
        let parts = split(TACHYON_RELEASE_REPO, "/");
        if (length(parts) == 2 && parts[0] != "" && parts[1] != "") {
            version = downloader.fetch_github_release_tag_fallback(parts[0], parts[1]);
        }
    }
    return version;
}

function fetch_tachyon_latest_release_metadata() {
    let parts = split(TACHYON_RELEASE_REPO, "/");
    let response = latest_tachyon_release_json();
    if (response != "") {
        let metadata = trim(helpers.helper_output_input(response, "release-metadata-tsv", []));
        if (metadata != "")
            return metadata;
    }

    if (length(parts) == 2 && as_string(parts[0]) != "" && as_string(parts[1]) != "") {
        let fallback_tag = downloader.fetch_github_release_tag_fallback(parts[0], parts[1]);
        if (fallback_tag != "")
            return fallback_tag + "\thttps://github.com/" + parts[0] + "/" + parts[1] + "/releases/tag/" + fallback_tag;
    }

    return "";
}

function write_tachyon_latest_version_cache(value, timestamp) {
    if (as_string(value) == "")
        return;
    write_file("/tmp/tachyon.latest-version.cache", as_string(value) + "\n" + as_string(timestamp) + "\n");
}

function read_tachyon_build_fingerprint() {
    let fields = split(trim(helpers.read_file(TACHYON_BUILD_STATE_FILE)), "\t");
    if (length(fields) < 2 || trim(as_string(fields[0])) != trim(as_string(TACHYON_VERSION)))
        return "";
    return trim(as_string(fields[1]));
}

function write_tachyon_build_fingerprint(version, fingerprint) {
    if (as_string(version) == "" || as_string(fingerprint) == "")
        return;
    let dir = replace(TACHYON_BUILD_STATE_FILE, /\/[^\/]*$/, "");
    if (dir != "")
        helpers.ensure_dir(dir);
    write_file(TACHYON_BUILD_STATE_FILE, as_string(version) + "\t" + as_string(fingerprint) + "\n");
}

function record_tachyon_installed_build(version, release_ctx) {
    let sha = "";
    let fingerprint = "";

    if (type(release_ctx) == "object") {
        sha = as_string(release_ctx.source_sha || "");
        fingerprint = as_string(release_ctx.fingerprint || "");
    }

    if (sha == "" && fingerprint == "") {
        let release_json = latest_tachyon_release_json();
        if (release_json != "") {
            sha = trim(helpers.helper_output_input(release_json, "release-commit-sha", []));
            if (sha != "" && match(sha, /^[0-9a-fA-F]{7,40}$/) == null)
                sha = "";
            fingerprint = trim(helpers.helper_output_input(release_json, "release-build-fingerprint", []));
        }
    }

    write_tachyon_build_fingerprint(version, fingerprint);

    if (sha == "" && fingerprint == "")
        return null;
    let extra = { current_sha: sha, latest_sha: sha };
    if (fingerprint != "") {
        extra.current_build = fingerprint;
        extra.latest_build = fingerprint;
    }
    return extra;
}

function retry_resolve(description, fn) {
    for (let attempt = 1; attempt <= 3; attempt++) {
        if (fn())
            return true;
        helpers.updates_log(as_string(description) + " failed (" + attempt + "/3)", "warn");
        command_success_from_args([ "sleep", "2" ]);
    }
    return false;
}

function clear_version_caches() {
    helpers.remove_file("/tmp/tachyon.latest-version.cache");
    helpers.remove_file(SYSTEM_INFO_CACHE_FILE);
    helpers.remove_file("/tmp/tachyon/system-info.json");
}

function opkg_arch_list() {
    return trim(helpers.helper_output_input(command_output_from_args([ "opkg", "print-architecture" ]), "updates-opkg-arch-list", []));
}

function resolve_arch_candidates() {
    let arch_list = "";
    if (helpers.is_apk()) {
        if (helpers.file_exists("/etc/apk/arch"))
            arch_list += " " + trim(helpers.helper_output("file-whitespace-list", [ "/etc/apk/arch" ]));
        arch_list += " " + trim(command_output_from_args([ "apk", "--print-arch" ]));
    }
    else {
        arch_list = opkg_arch_list();
    }

    let release_arch = helpers.read_openwrt_release_value("DISTRIB_ARCH");
    if (release_arch != "")
        arch_list += " " + release_arch;
    if (!helpers.helper_success("string-has-whitespace-field", [ arch_list ]))
        arch_list = trim(command_output_from_args([ "uname", "-m" ]));

    let resolved = trim(helpers.helper_output("updates-arch-candidates", [ arch_list ]));
    let fields = split(resolved, "\t");
    if (length(fields) < 2 || as_string(fields[0]) == "" || as_string(fields[1]) == "")
        return null;

    helpers.updates_log("Detected package architecture candidates: " + fields[1]);
    return {
        target: as_string(fields[0]),
        candidates: as_string(fields[1])
    };
}

function resolve_zapret_release(arch, tag) {
    let release_json = (tag != null && tag != "") ?
        downloader.fetch_github_release_by_tag_json("remittor", "zapret-openwrt", tag) :
        downloader.fetch_github_release_json("remittor", "zapret-openwrt");
    if (release_json != "") {
        let resolved = trim(helpers.helper_output_input(release_json, "release-select-arch-suffix-asset", [ "zip", arch.candidates ]));
        let fields = split(resolved, "\t");
        if (length(fields) >= 4) {
            let version = versions.extract_zapret_bundle_version(fields[1]);
            if (version == "")
                version = trim(helpers.helper_output("string-remove-suffix", [ fields[1], ".zip" ]));
            return {
                arch: fields[0],
                bundle_name: fields[1],
                bundle_url: fields[2],
                release_url: fields[3],
                version
            };
        }
    }
    if (tag != null && tag != "") {
        let tag_clean = replace(tag, /^v/, "");
        let tag_with_v = "v" + tag_clean;
        let bundle_name = "zapret_" + tag_with_v + "_" + arch.candidates + ".zip";
        return {
            arch: arch.candidates,
            bundle_name: bundle_name,
            bundle_url: "https://github.com/remittor/zapret-openwrt/releases/download/" + tag_with_v + "/" + bundle_name,
            release_url: "https://github.com/remittor/zapret-openwrt/releases/tag/" + tag_with_v,
            version: tag
        };
    }
    return { fetch_failed: true };
}

function resolve_zapret2_release(arch, tag) {
    let resolved_tag = (tag != null && tag != "") ? tag : "";
    if (resolved_tag == "") {
        let releases_json = downloader.fetch_github_releases_json("Dushnilin", "zapret2-openwrt", "5");
        if (releases_json != "") {
            try {
                let parsed = json(releases_json);
                if (type(parsed) == "array" && length(parsed) > 0)
                    resolved_tag = trim(as_string(parsed[0].tag_name || ""));
            } catch (e) {}
        }
    }
    if (resolved_tag == "")
        resolved_tag = downloader.fetch_github_release_tag_fallback("Dushnilin", "zapret2-openwrt");
    if (resolved_tag == "")
        return { fetch_failed: true };
    
    let asset_ext = helpers.is_apk() ? "apk" : "ipk";
    let base_dl = "https://github.com/Dushnilin/zapret2-openwrt/releases/download/" + resolved_tag + "/";
    let release_url = "https://github.com/Dushnilin/zapret2-openwrt/releases/tag/" + resolved_tag;
    let version = replace(resolved_tag, /^v/, "");

    let candidate_list = split(arch.candidates, " ");
    for (let candidate in candidate_list) {
        if (candidate == "") continue;
        let pkg_name = "zapret2_" + candidate + "." + asset_ext;
        let url = base_dl + pkg_name;
        if (downloader.url_exists(url)) {
            return {
                arch: candidate,
                package_name: pkg_name,
                package_url: url,
                release_url: release_url,
                version: version
            };
        }
    }
    return null;
}

function resolve_byedpi_release(arch, tag) {
    let asset_ext = helpers.is_apk() ? "apk" : "ipk";
    let release_series = trim(helpers.helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let releases_json = (tag != null && tag != "") ?
        downloader.fetch_github_release_by_tag_json("DPITrickster", "ByeDPI-OpenWrt", tag) :
        downloader.fetch_github_releases_json("DPITrickster", "ByeDPI-OpenWrt", "30");
    if (releases_json != "") {
        let resolved = trim(helpers.helper_output_input(releases_json, "byedpi-select-asset", [ release_series, asset_ext, arch.candidates ]));
        let fields = split(resolved, "\t");
        if (length(fields) >= 4) {
            return {
                arch: fields[0],
                package_name: fields[1],
                package_url: fields[2],
                release_url: fields[3],
                version: versions.extract_arch_package_version(fields[1], fields[0])
            };
        }
    }
    if (tag != null && tag != "") {
        let distrib_arch = helpers.read_openwrt_release_value("DISTRIB_ARCH");
        let tag_clean = replace(tag, /^v/, "");
        let pkg_name = "byedpi_" + tag_clean + "_openwrt_" + distrib_arch + "." + asset_ext;
        return {
            arch: distrib_arch,
            package_name: pkg_name,
            package_url: "https://github.com/DPITrickster/ByeDPI-OpenWrt/releases/download/" + tag + "/" + pkg_name,
            release_url: "https://github.com/DPITrickster/ByeDPI-OpenWrt/releases/tag/" + tag,
            version: tag
        };
    }
    return null;
}

function resolve_wdtt_release(arch, tag) {
    let asset_ext = helpers.is_apk() ? "apk" : "ipk";
    let release_series = trim(helpers.helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let owner = "Dushnilin";
    let repo = "qwdtt-openwrt";
    let releases_json = (tag != null && tag != "") ?
        downloader.fetch_github_release_by_tag_json(owner, repo, tag) :
        downloader.fetch_github_releases_json(owner, repo, "30");
    if (releases_json == "" || releases_json == "[]") {
        owner = "SpaceNeuroX";
        releases_json = (tag != null && tag != "") ?
            downloader.fetch_github_release_by_tag_json(owner, repo, tag) :
            downloader.fetch_github_releases_json(owner, repo, "30");
    }
    if (releases_json != "" && releases_json != "[]") {
        let resolved = trim(helpers.helper_output_input(releases_json, "wdtt-select-asset", [ release_series, asset_ext, arch.candidates ]));
        let fields = split(resolved, "\t");
        if (length(fields) >= 4) {
            return {
                arch: fields[0],
                package_name: fields[1],
                package_url: fields[2],
                release_url: fields[3],
                version: versions.extract_arch_package_version(fields[1], fields[0])
            };
        }
    }
    if (tag != null && tag != "") {
        let distrib_arch = helpers.read_openwrt_release_value("DISTRIB_ARCH");
        let tag_clean = replace(tag, /^v/, "");
        let pkg_name = "wdtt_" + tag_clean + "_openwrt_" + distrib_arch + "." + asset_ext;
        let dushnilin_url = "https://github.com/Dushnilin/qwdtt-openwrt/releases/download/" + tag + "/" + pkg_name;
        let target_owner = downloader.url_exists(dushnilin_url) ? "Dushnilin" : "SpaceNeuroX";
        return {
            arch: distrib_arch,
            package_name: pkg_name,
            package_url: "https://github.com/" + target_owner + "/qwdtt-openwrt/releases/download/" + tag + "/" + pkg_name,
            release_url: "https://github.com/" + target_owner + "/qwdtt-openwrt/releases/tag/" + tag,
            version: tag
        };
    }
    return null;
}

function resolve_olcrtc_release(arch, tag) {
    let asset_ext = helpers.is_apk() ? "apk" : "ipk";
    let release_series = trim(helpers.helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let owner = "Dushnilin";
    let repo = "openwrt-olcrtc";
    let releases_json = (tag != null && tag != "") ?
        downloader.fetch_github_release_by_tag_json(owner, repo, tag) :
        downloader.fetch_github_releases_json(owner, repo, "30");
    if (releases_json == "" || releases_json == "[]") {
        owner = "alekvol";
        releases_json = (tag != null && tag != "") ?
            downloader.fetch_github_release_by_tag_json(owner, repo, tag) :
            downloader.fetch_github_releases_json(owner, repo, "30");
    }
    if (releases_json != "" && releases_json != "[]") {
        let resolved = trim(helpers.helper_output_input(releases_json, "olcrtc-select-asset", [ release_series, asset_ext, arch.candidates ]));
        let fields = split(resolved, "\t");
        if (length(fields) >= 4) {
            return {
                arch: fields[0],
                package_name: fields[1],
                package_url: fields[2],
                release_url: fields[3],
                version: versions.extract_arch_package_version(fields[1], fields[0])
            };
        }
    }
    if (tag != null && tag != "") {
        let distrib_arch = helpers.read_openwrt_release_value("DISTRIB_ARCH");
        let tag_clean = replace(tag, /^v/, "");
        let pkg_name = "olcrtc_" + tag_clean + "_openwrt_" + distrib_arch + "." + asset_ext;
        let dushnilin_url = "https://github.com/Dushnilin/openwrt-olcrtc/releases/download/" + tag + "/" + pkg_name;
        let target_owner = downloader.url_exists(dushnilin_url) ? "Dushnilin" : "alekvol";
        return {
            arch: distrib_arch,
            package_name: pkg_name,
            package_url: "https://github.com/" + target_owner + "/openwrt-olcrtc/releases/download/" + tag + "/" + pkg_name,
            release_url: "https://github.com/" + target_owner + "/openwrt-olcrtc/releases/tag/" + tag,
            version: tag
        };
    }
    return null;
}

function resolve_fptn_release(arch, tag) {
    let asset_ext = helpers.is_apk() ? "apk" : "ipk";
    let release_series = trim(helpers.helper_output("openwrt-release-series", [ "/etc/openwrt_release" ]));
    let owner = "Dushnilin";
    let repo = "fptn";
    let releases_json = (tag != null && tag != "") ?
        downloader.fetch_github_release_by_tag_json(owner, repo, tag) :
        downloader.fetch_github_releases_json(owner, repo, "30");
    if (releases_json == "" || releases_json == "[]") {
        owner = "fptn-project";
        releases_json = (tag != null && tag != "") ?
            downloader.fetch_github_release_by_tag_json(owner, repo, tag) :
            downloader.fetch_github_releases_json(owner, repo, "30");
    }
    if (releases_json != "" && releases_json != "[]") {
        let resolved = trim(helpers.helper_output_input(releases_json, "fptn-select-asset", [ release_series, asset_ext, arch.candidates ]));
        let fields = split(resolved, "\t");
        if (length(fields) >= 4) {
            let ver = versions.extract_arch_package_version(fields[1], fields[0]);
            let m = match(ver, /^([0-9]+\.[0-9]+\.[0-9]+)/);
            if (m) ver = m[1];
            return {
                arch: fields[0],
                package_name: fields[1],
                package_url: fields[2],
                release_url: fields[3],
                version: ver
            };
        }
    }
    if (tag != null && tag != "") {
        let distrib_arch = helpers.read_openwrt_release_value("DISTRIB_ARCH");
        let tag_clean = replace(tag, /^v/, "");
        let pkg_name = "fptn-client-" + tag_clean + "-openwrt-" + (release_series != "" ? release_series + ".x" : "24.10.x") + "-" + distrib_arch + "." + asset_ext;
        let dushnilin_url = "https://github.com/Dushnilin/fptn/releases/download/" + tag + "/" + pkg_name;
        let target_owner = downloader.url_exists(dushnilin_url) ? "Dushnilin" : "fptn-project";
        return {
            arch: distrib_arch,
            package_name: pkg_name,
            package_url: "https://github.com/" + target_owner + "/fptn/releases/download/" + tag + "/" + pkg_name,
            release_url: "https://github.com/" + target_owner + "/fptn/releases/tag/" + tag,
            version: tag_clean
        };
    }
    return null;
}

function resolve_tachyon_release(latest_version) {
    let asset_ext = helpers.is_apk() ? "apk" : "ipk";
    let i18n_required = helpers.pkg_is_installed("luci-i18n-tachyon-ru") ? "1" : "0";
    let release_json = latest_tachyon_release_json();
    let source_sha = "";
    let fingerprint = "";

    if (release_json != "") {
        source_sha = trim(helpers.helper_output_input(release_json, "release-commit-sha", []));
        if (source_sha != "" && match(source_sha, /^[0-9a-fA-F]{7,40}$/) == null)
            source_sha = "";
        fingerprint = trim(helpers.helper_output_input(release_json, "release-build-fingerprint", []));

        let plan = trim(helpers.helper_output_input(release_json, "tachyon-release-plan", [ latest_version, asset_ext, i18n_required ]));
        let fields = split(plan, "\t");
        if (length(fields) >= 7 && as_string(fields[1]) != "" && as_string(fields[2]) != "" && as_string(fields[3]) != "" && as_string(fields[4]) != "") {
            return {
                release_url: fields[0],
                backend_name: fields[1],
                backend_url: fields[2],
                app_name: fields[3],
                app_url: fields[4],
                i18n_name: fields[5],
                i18n_url: fields[6],
                source_sha: source_sha,
                fingerprint: fingerprint
            };
        }
    }

    let ver_clean = replace(as_string(latest_version), /^v/, "");
    let backend_name = "tachyon_" + ver_clean + "." + asset_ext;
    let app_name = "luci-app-tachyon_" + ver_clean + "." + asset_ext;
    let i18n_name = "luci-i18n-tachyon-ru_" + ver_clean + "." + asset_ext;
    let base_dl = "https://github.com/" + TACHYON_RELEASE_REPO + "/releases/download/" + latest_version + "/";

    return {
        release_url: "https://github.com/" + TACHYON_RELEASE_REPO + "/releases/tag/" + latest_version,
        backend_name: backend_name,
        backend_url: base_dl + backend_name,
        app_name: app_name,
        app_url: base_dl + app_name,
        i18n_name: i18n_required == "1" ? i18n_name : "",
        i18n_url: i18n_required == "1" ? (base_dl + i18n_name) : "",
        source_sha: source_sha,
        fingerprint: fingerprint
    };
}

function module_exports() {
    return {
        latest_tachyon_release_json,
        latest_tachyon_version,
        fetch_tachyon_latest_release_metadata,
        write_tachyon_latest_version_cache,
        read_tachyon_build_fingerprint,
        write_tachyon_build_fingerprint,
        record_tachyon_installed_build,
        retry_resolve,
        clear_version_caches,
        opkg_arch_list,
        resolve_arch_candidates,
        resolve_zapret_release,
        resolve_zapret2_release,
        resolve_byedpi_release,
        resolve_wdtt_release,
        resolve_olcrtc_release,
        resolve_fptn_release,
        resolve_tachyon_release
    };
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return module_exports();

print("Usage: components/catalog.uc (library module, no CLI)
");
exit(1);
