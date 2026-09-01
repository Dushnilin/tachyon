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
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/tachyon
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +curl +ucode +ucode-mod-fs +ucode-mod-uci +coreutils-base64 +bind-dig +nftables +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	PROVIDES:=forkop
	REPLACES:=forkop
	TITLE:=Tachyon backend service
	URL:=https://github.com/Dushnilin/tachyon
	PKGARCH:=all
endef

define Package/tachyon/description
	Rule-based Tachyon backend with hybrid sing-box + zapret orchestration
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

# Start via tachyon binary (lifecycle.uc) which registers with procd directly,
# bypassing rc.common and its flock entirely.
/usr/bin/tachyon start >/dev/null 2>&1 || true
rm -f /var/run/tachyon/upgrade_state 2>/dev/null || true
chmod 600 /etc/config/tachyon 2>/dev/null || true
chown root:root /etc/config/tachyon 2>/dev/null || true
exit 0
endef

define Package/tachyon/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Clean up legacy forkop package files
rm -rf /usr/lib/lua/luci/i18n/forkop.* /www/luci-static/resources/i18n/forkop.* \
       /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json \
       /etc/uci-defaults/50_luci-forkop 2>/dev/null || true

# Migration from Forkop or Podkop
if [ -f /etc/config/forkop ]; then
	mv /etc/config/forkop /etc/config/tachyon
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate-podkop
elif [ -f /etc/config/forkop_plus ]; then
	mv /etc/config/forkop_plus /etc/config/tachyon
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate-podkop
elif [ -f /etc/config/podkop ]; then
	mv /etc/config/podkop /etc/config/tachyon
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate-podkop
elif [ -f /etc/config/podkop_plus ]; then
	mv /etc/config/podkop_plus /etc/config/tachyon
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate-podkop
else
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate
fi

/usr/bin/tachyon package_postinst

# Harden config: telegram bot_token must not be world-readable
chmod 600 /etc/config/tachyon
chown root:root /etc/config/tachyon

# Install AI Agent API CGI handler into uhttpd's cgi-bin
if [ -d /www/cgi-bin ]; then
	cp /usr/lib/cgi-bin/tachyon-agent /www/cgi-bin/tachyon-agent 2>/dev/null || true
	chmod 755 /www/cgi-bin/tachyon-agent 2>/dev/null || true
fi
endef

define Package/tachyon/conffiles
/etc/config/tachyon
endef

define Package/tachyon/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/tachyon $(1)/etc/init.d/tachyon

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/tachyon $(1)/etc/config/tachyon

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/tachyon $(1)/usr/bin/tachyon

	$(INSTALL_DIR) $(1)/usr/lib/tachyon
	$(CP) ./files/usr/lib/. $(1)/usr/lib/tachyon/

	$(INSTALL_DIR) $(1)/usr/lib/tachyon/defaults
	$(INSTALL_CONF) ./files/etc/config/tachyon $(1)/usr/lib/tachyon/defaults/config

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/99-tachyon-wan-monitor $(1)/etc/hotplug.d/iface/99-tachyon-wan-monitor

	# AI Agent API CGI handler (executable shell wrapper for uhttpd)
	$(INSTALL_DIR) $(1)/usr/lib/cgi-bin
	$(INSTALL_BIN) ./files/usr/lib/cgi-bin/tachyon-agent $(1)/usr/lib/cgi-bin/tachyon-agent

	# Service Check profiles (community-defined service probe targets)
	$(INSTALL_DIR) $(1)/usr/share/tachyon
	$(INSTALL_DATA) ./files/usr/share/tachyon/servicecheck_profiles.json $(1)/usr/share/tachyon/servicecheck_profiles.json

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(TACHYON_COMPILED_VERSION)/g' \
		-e 's/__COMPILED_COMMIT_SHA__/$(shell git -C $(TOPDIR)/../ rev-parse --short HEAD 2>/dev/null || echo unknown)/g' \
		$(1)/usr/lib/tachyon/core/constants.uc
endef

$(eval $(call BuildPackage,tachyon))
