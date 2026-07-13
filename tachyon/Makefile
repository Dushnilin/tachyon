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
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +coreutils-base64 +coreutils-sort +bind-dig +nftables +kmod-nft-nat +ip-full
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

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/tachyon package_prerm >/dev/null 2>&1");

exit(0);
endef

define Package/tachyon/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Clean up legacy forkop package files
rm -rf /usr/lib/lua/luci/i18n/forkop.* /www/luci-static/resources/i18n/forkop.* \
       /usr/share/luci/menu.d/luci-app-forkop.json /usr/share/rpcd/acl.d/luci-app-forkop.json \
       /etc/uci-defaults/50_luci-forkop 2>/dev/null || true

# Migration from Forkop
if [ -f /etc/config/forkop ]; then
	mv /etc/config/forkop /etc/config/tachyon
elif [ -f /etc/config/forkop_plus ]; then
	mv /etc/config/forkop_plus /etc/config/tachyon
# Migration from Podkop
elif [ -f /etc/config/podkop ]; then
	mv /etc/config/podkop /etc/config/tachyon
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate-podkop
	exit 0
elif [ -f /etc/config/podkop_plus ]; then
	mv /etc/config/podkop_plus /etc/config/tachyon
	TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate-podkop
	exit 0
fi

TACHYON_LIB=/usr/lib/tachyon ucode -L /usr/lib/tachyon /usr/lib/tachyon/config/migration.uc migrate
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

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(TACHYON_COMPILED_VERSION)/g' $(1)/usr/lib/tachyon/core/constants.uc
endef

$(eval $(call BuildPackage,tachyon))
