include $(TOPDIR)/rules.mk

PKG_NAME:=tachyon

TACHYON_SOURCE_VERSION:=$(or $(TACHYON_PACKAGE_VERSION),$(TACHYON_VERSION))
TACHYON_HAS_RELEASE_VERSION:=$(if $(filter dev,$(TACHYON_SOURCE_VERSION)),,$(TACHYON_SOURCE_VERSION))
TACHYON_COMPILED_VERSION:=$(if $(TACHYON_HAS_RELEASE_VERSION),$(TACHYON_SOURCE_VERSION),$(or $(TACHYON_SOURCE_VERSION),dev))
TACHYON_RELEASE_VERSION_VALID:=$(if $(TACHYON_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(TACHYON_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(TACHYON_RELEASE_VERSION_VALID),)
$(error TACHYON_PACKAGE_VERSION and TACHYON_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(TACHYON_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=Dushnilin <dushnilin@gmail.com>
PKG_LICENSE:=GPL-2.0-or-later Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/tachyon
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +curl +openssl-util +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-uloop +coreutils-base64 +coreutils-timeout +bind-dig +nftables +ip-full +kmod-nft-tproxy +kmod-tun +kmod-inet-diag
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Tachyon backend service
	URL:=https://github.com/Dushnilin/tachyon
	PKGARCH:=all
endef

define Package/tachyon/description
	Rule-based Tachyon backend with tachyon-core orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/tachyon/prerm
#!/usr/bin/ucode

// apk runs this as <pkg>-<version>.pre-upgrade and rolls the whole transaction
// back if the hook does not finish, which leaves the old build installed. The
// cleanup invoked below belongs to the OLD version, so it cannot be trusted to
// bound itself — the hook bounds it from the outside. 90s sits far below any
// package-manager or installer patience and far above a healthy cleanup.
// BusyBox timeout wanted `-t SECONDS` on older builds and rejects it on newer
// ones; the spelling is probed against /bin/true because probing with the real
// command would run the cleanup twice whenever the first form is unsupported.
if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "") {
	let prefix = "";
	if (system("timeout 1 /bin/true >/dev/null 2>&1") == 0)
		prefix = "timeout 90 ";
	else if (system("timeout -t 1 /bin/true >/dev/null 2>&1") == 0)
		prefix = "timeout -t 90 ";

	system(prefix + "/usr/bin/tachyon package_prerm >/dev/null 2>&1");
}

// Whatever the cleanup managed to do, the removal itself must proceed: a failing
// prerm aborts the upgrade on both package managers.
exit(0);
endef

define Package/tachyon/postupgrade
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Kill everything that could hold or wait for the procd serialization lock
# (rc.common flock -w 1000). procd re-triggers retry_start_on_wan_up between
# pre-upgrade and post-upgrade, which continuously creates new flock waiters.
ps 2>/dev/null | grep -E '99-tachyon-wan|flock 1000' | awk '{print $$1}' | while read _pid; do
    kill -9 "$$_pid" 2>/dev/null
done
ps 2>/dev/null | grep -F '/etc/init.d/tachyon' | awk '{print $$1}' | while read _pid; do
    kill -9 "$$_pid" 2>/dev/null
done

_backup_external_configs() {
	_bdir="/etc/tachyon/external-configs-backup"
	for _comp in zapret zapret2 byedpi wdtt qwdtt olcrtc sing-box; do
		_cdir="$$_bdir/$$_comp"
		case "$$_comp" in
			zapret) _srcs="/etc/config/zapret /opt/zapret/config /opt/zapret/ipset" ;;
			zapret2) _srcs="/etc/config/zapret2 /opt/zapret2/config /opt/zapret2/ipset" ;;
			byedpi) _srcs="/etc/config/byedpi /etc/byedpi" ;;
			wdtt|qwdtt) _srcs="/etc/config/wdtt /etc/wdtt /etc/qwdtt" ;;
			olcrtc) _srcs="/etc/config/olcrtc /etc/olcrtc" ;;
			sing-box) _srcs="/etc/sing-box/config.json /etc/config/sing-box" ;;
		esac
		_has_src=0
		for _s in $$_srcs; do [ -e "$$_s" ] && _has_src=1 && break; done
		[ "$$_has_src" -eq 0 ] && continue
		mkdir -p "$$_cdir" 2>/dev/null || continue
		for _s in $$_srcs; do
			[ -e "$$_s" ] || continue
			_dst="$$_cdir/$$(basename "$$_s")"
			if [ -d "$$_s" ]; then
				cp -a -n "$$_s" "$$_dst" 2>/dev/null || cp -a "$$_s" "$${_dst}.new" 2>/dev/null || true
			else
				[ -f "$$_dst" ] && cmp -s "$$_s" "$$_dst" 2>/dev/null && continue
				cp -a "$$_s" "$$_dst" 2>/dev/null || true
			fi
		done
	done
}
_is_tachyon_managed() {
	_comp="$$1"
	[ -f "/etc/init.d/$$_comp" ] && grep -q "Tachyon managed" "/etc/init.d/$$_comp" 2>/dev/null && return 0
	[ -d "/etc/tachyon/component-backups/$$_comp" ] && return 0
	[ -d "/var/run/tachyon/$$_comp" ] && return 0
	return 1
}

_backup_external_configs

# Stop and clean Tachyon internal steer subsystem
for _steer_svc in tachyon-steer-zapret steer; do
	if [ -f "/etc/init.d/$${_steer_svc}" ]; then
		"/etc/init.d/$${_steer_svc}" stop >/dev/null 2>&1 || true
		"/etc/init.d/$${_steer_svc}" disable >/dev/null 2>&1 || true
		rm -f "/etc/init.d/$${_steer_svc}" 2>/dev/null || true
	fi
done
rm -rf /etc/rc.d/*steer* /etc/steer /usr/lib/tachyon/steer /usr/sbin/steer /usr/bin/steer /var/run/tachyon/*steer* /tmp/*steer* 2>/dev/null || true
killall -9 steer >/dev/null 2>&1 || true
nft delete table inet steer >/dev/null 2>&1 || true

# Selective cleanup of external components only if Tachyon-managed
if [ -f /etc/init.d/tailscale ] && grep -q "Tachyon managed" /etc/init.d/tailscale 2>/dev/null; then
	/etc/init.d/tailscale stop >/dev/null 2>&1 || true
	/etc/init.d/tailscale disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/tailscale /etc/rc.d/*tailscale* 2>/dev/null || true
	rm -rf /var/run/tachyon/tailscale /etc/tachyon/tailscale/*/native /etc/tachyon/component-backups/tailscale 2>/dev/null || true
	nft delete table inet tachyon_tailscale >/dev/null 2>&1 || true
fi
for _comp in zapret zapret2 byedpi wdtt-client qwdtt olcrtc; do
	_comp_marker="$$_comp"
	case "$$_comp" in wdtt-client) _comp_marker="wdtt" ;; esac
	if _is_tachyon_managed "$$_comp_marker"; then
		if [ -f "/etc/init.d/$${_comp}" ]; then
			"/etc/init.d/$${_comp}" stop >/dev/null 2>&1 || true
			"/etc/init.d/$${_comp}" disable >/dev/null 2>&1 || true
			rm -f "/etc/init.d/$${_comp}" "/etc/rc.d/*$${_comp}*" 2>/dev/null || true
		fi
		case "$$_comp_marker" in
			zapret)
				killall -9 nfqws >/dev/null 2>&1 || true
				rm -f /usr/bin/nfqws 2>/dev/null || true
				rm -rf /opt/zapret /etc/config/zapret /var/run/tachyon/zapret* /etc/tachyon/component-backups/zapret /var/run/tachyon/component-update-checks/zapret.json 2>/dev/null || true
				for _tbl in zapret; do nft delete table inet "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip6 "$$_tbl" >/dev/null 2>&1 || true; done
				;;
			zapret2)
				killall -9 nfqws2 >/dev/null 2>&1 || true
				rm -f /usr/bin/nfqws2 2>/dev/null || true
				rm -rf /opt/zapret2 /etc/config/zapret2 /etc/tachyon/component-backups/zapret2 /var/run/tachyon/component-update-checks/zapret2.json 2>/dev/null || true
				for _tbl in zapret2; do nft delete table inet "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip6 "$$_tbl" >/dev/null 2>&1 || true; done
				;;
			byedpi)
				killall -9 ciadpi >/dev/null 2>&1 || true
				rm -f /usr/bin/ciadpi 2>/dev/null || true
				rm -rf /etc/config/byedpi /var/run/tachyon/byedpi /etc/tachyon/component-backups/byedpi /var/run/tachyon/component-update-checks/byedpi.json 2>/dev/null || true
				;;
			wdtt)
				killall -9 wdtt qwdtt-client >/dev/null 2>&1 || true
				rm -f /usr/bin/wdtt /usr/bin/qwdtt-client /usr/sbin/wdtt-genlists /usr/sbin/wdtt-resolve 2>/dev/null || true
				rm -rf /etc/qwdtt /etc/wdtt /etc/config/wdtt /var/run/tachyon/wdtt /var/run/qwdtt /etc/tachyon/component-backups/wdtt /var/run/tachyon/component-update-checks/wdtt.json 2>/dev/null || true
				;;
			olcrtc)
				killall -9 olcrtc >/dev/null 2>&1 || true
				rm -f /usr/bin/olcrtc 2>/dev/null || true
				rm -rf /etc/olcrtc /etc/config/olcrtc /var/run/tachyon/olcrtc /etc/tachyon/component-backups/olcrtc /var/run/tachyon/component-update-checks/olcrtc.json 2>/dev/null || true
				;;
		esac
	fi
done

# LuCI cache touch invalidation
for _f in /www/luci-static/resources/view/tachyon/*.js; do [ -f "$$_f" ] && touch "$$_f" 2>/dev/null || true; done
touch /www/luci-static/resources/luci.js /www/luci-static/resources/view/tachyon /www/luci-static/resources 2>/dev/null || true

# Start via tachyon binary (lifecycle.uc) which registers with procd directly,
# bypassing rc.common and its flock entirely.
/usr/bin/tachyon start >/dev/null 2>&1 || true
rm -f /var/run/tachyon/upgrade_state 2>/dev/null || true
chmod 600 /etc/config/tachyon 2>/dev/null || true
chown root:root /etc/config/tachyon 2>/dev/null || true

# AI Agent API CGI handler: publish it in uhttpd's cgi-bin only when the user
# configured agent_api_token. Otherwise the read endpoints are open to the
# whole LAN and /config answers with the raw UCI config (issue #76).
if [ -d /www/cgi-bin ]; then
	if [ -n "$(uci -q get tachyon.settings.agent_api_token)" ]; then
		ln -sf /usr/lib/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-agent 2>/dev/null || true
	else
		rm -f /www/cgi-bin/tachyon-agent 2>/dev/null || true
	fi
fi
exit 0
endef

define Package/tachyon/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

_backup_external_configs() {
	_bdir="/etc/tachyon/external-configs-backup"
	for _comp in zapret zapret2 byedpi wdtt qwdtt olcrtc sing-box; do
		_cdir="$$_bdir/$$_comp"
		case "$$_comp" in
			zapret) _srcs="/etc/config/zapret /opt/zapret/config /opt/zapret/ipset" ;;
			zapret2) _srcs="/etc/config/zapret2 /opt/zapret2/config /opt/zapret2/ipset" ;;
			byedpi) _srcs="/etc/config/byedpi /etc/byedpi" ;;
			wdtt|qwdtt) _srcs="/etc/config/wdtt /etc/wdtt /etc/qwdtt" ;;
			olcrtc) _srcs="/etc/config/olcrtc /etc/olcrtc" ;;
			sing-box) _srcs="/etc/sing-box/config.json /etc/config/sing-box" ;;
		esac
		_has_src=0
		for _s in $$_srcs; do [ -e "$$_s" ] && _has_src=1 && break; done
		[ "$$_has_src" -eq 0 ] && continue
		mkdir -p "$$_cdir" 2>/dev/null || continue
		for _s in $$_srcs; do
			[ -e "$$_s" ] || continue
			_dst="$$_cdir/$$(basename "$$_s")"
			if [ -d "$$_s" ]; then
				cp -a -n "$$_s" "$$_dst" 2>/dev/null || cp -a "$$_s" "$${_dst}.new" 2>/dev/null || true
			else
				[ -f "$$_dst" ] && cmp -s "$$_s" "$$_dst" 2>/dev/null && continue
				cp -a "$$_s" "$$_dst" 2>/dev/null || true
			fi
		done
	done
}
_is_tachyon_managed() {
	_comp="$$1"
	[ -f "/etc/init.d/$$_comp" ] && grep -q "Tachyon managed" "/etc/init.d/$$_comp" 2>/dev/null && return 0
	[ -d "/etc/tachyon/component-backups/$$_comp" ] && return 0
	[ -d "/var/run/tachyon/$$_comp" ] && return 0
	return 1
}

_backup_external_configs

# Stop and clean Tachyon internal steer subsystem
for _steer_svc in tachyon-steer-zapret steer; do
	if [ -f "/etc/init.d/$${_steer_svc}" ]; then
		"/etc/init.d/$${_steer_svc}" stop >/dev/null 2>&1 || true
		"/etc/init.d/$${_steer_svc}" disable >/dev/null 2>&1 || true
		rm -f "/etc/init.d/$${_steer_svc}" 2>/dev/null || true
	fi
done
rm -rf /etc/rc.d/*steer* /etc/steer /usr/lib/tachyon/steer /usr/sbin/steer /usr/bin/steer /var/run/tachyon/*steer* /tmp/*steer* 2>/dev/null || true
killall -9 steer >/dev/null 2>&1 || true
nft delete table inet steer >/dev/null 2>&1 || true

# Selective cleanup of external components only if Tachyon-managed
if [ -f /etc/init.d/tailscale ] && grep -q "Tachyon managed" /etc/init.d/tailscale 2>/dev/null; then
	/etc/init.d/tailscale stop >/dev/null 2>&1 || true
	/etc/init.d/tailscale disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/tailscale /etc/rc.d/*tailscale* 2>/dev/null || true
	rm -rf /var/run/tachyon/tailscale /etc/tachyon/tailscale/*/native /etc/tachyon/component-backups/tailscale 2>/dev/null || true
	nft delete table inet tachyon_tailscale >/dev/null 2>&1 || true
fi
for _comp in zapret zapret2 byedpi wdtt-client qwdtt olcrtc; do
	_comp_marker="$$_comp"
	case "$$_comp" in wdtt-client) _comp_marker="wdtt" ;; esac
	if _is_tachyon_managed "$$_comp_marker"; then
		if [ -f "/etc/init.d/$${_comp}" ]; then
			"/etc/init.d/$${_comp}" stop >/dev/null 2>&1 || true
			"/etc/init.d/$${_comp}" disable >/dev/null 2>&1 || true
			rm -f "/etc/init.d/$${_comp}" "/etc/rc.d/*$${_comp}*" 2>/dev/null || true
		fi
		case "$$_comp_marker" in
			zapret)
				killall -9 nfqws >/dev/null 2>&1 || true
				rm -f /usr/bin/nfqws 2>/dev/null || true
				rm -rf /opt/zapret /etc/config/zapret /var/run/tachyon/zapret* /etc/tachyon/component-backups/zapret /var/run/tachyon/component-update-checks/zapret.json 2>/dev/null || true
				for _tbl in zapret; do nft delete table inet "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip6 "$$_tbl" >/dev/null 2>&1 || true; done
				;;
			zapret2)
				killall -9 nfqws2 >/dev/null 2>&1 || true
				rm -f /usr/bin/nfqws2 2>/dev/null || true
				rm -rf /opt/zapret2 /etc/config/zapret2 /etc/tachyon/component-backups/zapret2 /var/run/tachyon/component-update-checks/zapret2.json 2>/dev/null || true
				for _tbl in zapret2; do nft delete table inet "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip "$$_tbl" >/dev/null 2>&1 || true; nft delete table ip6 "$$_tbl" >/dev/null 2>&1 || true; done
				;;
			byedpi)
				killall -9 ciadpi >/dev/null 2>&1 || true
				rm -f /usr/bin/ciadpi 2>/dev/null || true
				rm -rf /etc/config/byedpi /var/run/tachyon/byedpi /etc/tachyon/component-backups/byedpi /var/run/tachyon/component-update-checks/byedpi.json 2>/dev/null || true
				;;
			wdtt)
				killall -9 wdtt qwdtt-client >/dev/null 2>&1 || true
				rm -f /usr/bin/wdtt /usr/bin/qwdtt-client /usr/sbin/wdtt-genlists /usr/sbin/wdtt-resolve 2>/dev/null || true
				rm -rf /etc/qwdtt /etc/wdtt /etc/config/wdtt /var/run/tachyon/wdtt /var/run/qwdtt /etc/tachyon/component-backups/wdtt /var/run/tachyon/component-update-checks/wdtt.json 2>/dev/null || true
				;;
			olcrtc)
				killall -9 olcrtc >/dev/null 2>&1 || true
				rm -f /usr/bin/olcrtc 2>/dev/null || true
				rm -rf /etc/olcrtc /etc/config/olcrtc /var/run/tachyon/olcrtc /etc/tachyon/component-backups/olcrtc /var/run/tachyon/component-update-checks/olcrtc.json 2>/dev/null || true
				;;
		esac
	fi
done

TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate

# Ensure autostart is enabled
/etc/init.d/tachyon enable >/dev/null 2>&1 || true

/usr/bin/tachyon package_postinst

# LuCI cache touch invalidation
for _f in /www/luci-static/resources/view/tachyon/*.js; do [ -f "$$_f" ] && touch "$$_f" 2>/dev/null || true; done
touch /www/luci-static/resources/luci.js /www/luci-static/resources/view/tachyon /www/luci-static/resources 2>/dev/null || true

# The rpcd ACL for this binary ships here rather than in luci-app-tachyon, so
# the policy and the executable it governs are installed in the same package and
# cannot be updated apart. rpcd caches ACLs, so without this reload the new
# policy stays inert until rpcd restarts -- and if the new policy is stricter
# than the running one, the UI is broken until then.
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true

# Harden config: telegram bot_token must not be world-readable
chmod 600 /etc/config/tachyon
chown root:root /etc/config/tachyon

# AI Agent API CGI handler: publish it in uhttpd's cgi-bin only when the user
# configured agent_api_token. Otherwise the read endpoints are open to the
# whole LAN and /config answers with the raw UCI config (issue #76).
if [ -d /www/cgi-bin ]; then
	if [ -n "$(uci -q get tachyon.settings.agent_api_token)" ]; then
		ln -sf /usr/lib/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-agent 2>/dev/null || true
	else
		rm -f /www/cgi-bin/tachyon-agent 2>/dev/null || true
	fi
fi
exit 0
endef

define Package/tachyon/postrm
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$$1" = "upgrade" ] && exit 0
[ -x /usr/bin/tachyon ] && exit 0
if [ "$$1" != "remove" ] && [ "$$1" != "purge" ]; then
	exit 0
fi

if [ -e /var/run/tachyon/component-action.lock ] || [ -e /tmp/run/tachyon/component-action.lock ] || [ -e /var/run/tachyon/component-actions/action.lock ] || [ -e /tmp/run/tachyon/component-actions/action.lock ]; then
	exit 0
fi

rm -f /www/cgi-bin/tachyon-agent /etc/hotplug.d/iface/99-tachyon-wan-monitor 2>/dev/null || true
rm -f /usr/share/nftables.d/chain-pre/input/10-tachyon.nft 2>/dev/null || true
rm -f /usr/share/nftables.d/chain-pre/forward/10-tachyon-offload.nft 2>/dev/null || true
rm -f /usr/share/nftables.d/ruleset-post/10-tachyon-offload.nft 2>/dev/null || true
rm -f /usr/share/nftables.d/ruleset-post/90-tachyon-kill-switch.nft 2>/dev/null || true
nft delete table inet TachyonKillSwitch >/dev/null 2>&1 || true
for pref in 9499 9500 9501; do for fam in -4 -6; do while ip $$fam rule del pref $$pref >/dev/null 2>&1; do :; done; done; done
rm -rf /tmp/ai_doctor* /tmp/tg_* /tmp/warp_* 2>/dev/null || true
rm -rf /var/run/tachyon/section-cache /var/run/tachyon/ui-state 2>/dev/null || true
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall restart >/dev/null 2>&1 || true
[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

exit 0
endef

define Package/tachyon/conffiles
/etc/config/tachyon
endef

define Package/tachyon/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/tachyon $(1)/etc/init.d/tachyon
	$(INSTALL_BIN) ./files/etc/init.d/tachyon-torrserver-direct $(1)/etc/init.d/tachyon-torrserver-direct

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/tachyon $(1)/etc/config/tachyon

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/tachyon $(1)/lib/upgrade/keep.d/tachyon

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/tachyon $(1)/usr/bin/tachyon
	# Read-only entry point for the LuCI read role; see tests/tachyon_acl_role_split.sh.
	$(INSTALL_BIN) ./files/usr/bin/tachyon-read $(1)/usr/bin/tachyon-read

	$(INSTALL_DIR) $(1)/usr/lib/tachyon
	$(CP) ./files/usr/lib/. $(1)/usr/lib/tachyon/
	$(INSTALL_DIR) $(1)/usr/lib/tachyon/bin
	$(INSTALL_BIN) ./files/usr/lib/bin/wget $(1)/usr/lib/tachyon/bin/wget

	$(INSTALL_DIR) $(1)/usr/lib/tachyon/defaults
	$(INSTALL_CONF) ./files/etc/config/tachyon $(1)/usr/lib/tachyon/defaults/config

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/99-tachyon-wan-monitor $(1)/etc/hotplug.d/iface/99-tachyon-wan-monitor

	# AI Agent API CGI handler (executable shell wrapper for uhttpd)
	$(INSTALL_DIR) $(1)/usr/lib/cgi-bin
	$(INSTALL_BIN) ./files/usr/lib/cgi-bin/tachyon-agent $(1)/usr/lib/cgi-bin/tachyon-agent
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) ./files/www/cgi-bin/tachyon-sub $(1)/www/cgi-bin/tachyon-sub
	# The /www/cgi-bin symlink is NOT created here: it is published at service
	# start only when agent_api_token is set (issue #76). The handler itself
	# is always installed, so enabling the gateway needs no reinstall.

	# Service Check profiles (community-defined service probe targets)
	$(INSTALL_DIR) $(1)/usr/share/tachyon
	$(INSTALL_DATA) ./files/usr/share/tachyon/servicecheck_profiles.json $(1)/usr/share/tachyon/servicecheck_profiles.json
	# Registrable-domain boundaries for Smart Detect Plus (ICANN + PRIVATE, MPL-2.0).
	$(INSTALL_DATA) ./files/usr/share/tachyon/public-suffix-list.dat $(1)/usr/share/tachyon/public-suffix-list.dat

	# Curated strategy presets (Tachyon)
	$(INSTALL_DATA) ./files/usr/share/tachyon/dpi-presets.json $(1)/usr/share/tachyon/dpi-presets.json
	# rpcd ACL for /usr/bin/tachyon and /usr/bin/tachyon-read. Owned by this
	# package, not by luci-app-tachyon: the read role must reach only the
	# read-only entry point, and the two files have to arrive together.
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-tachyon.json $(1)/usr/share/rpcd/acl.d/luci-app-tachyon.json

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(TACHYON_COMPILED_VERSION)/g' \
		-e 's/__COMPILED_COMMIT_SHA__/$(shell git -C $(TOPDIR)/../ rev-parse --short HEAD 2>/dev/null || echo unknown)/g' \
		$(1)/usr/lib/tachyon/core/constants.uc
endef

$(eval $(call BuildPackage,tachyon))
