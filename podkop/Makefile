include $(TOPDIR)/rules.mk

PKG_NAME:=podkop-plus

PODKOP_SOURCE_VERSION:=$(or $(PODKOP_PACKAGE_VERSION),$(PODKOP_VERSION))
PODKOP_HAS_RELEASE_VERSION:=$(if $(filter dev,$(PODKOP_SOURCE_VERSION)),,$(PODKOP_SOURCE_VERSION))
PODKOP_IS_APK:=$(or $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(CONFIG_USE_APK))
PODKOP_RELEASE_VERSION:=$(or $(PODKOP_HAS_RELEASE_VERSION),0.0.0)
PODKOP_LEGACY_RELEASE:=$(findstring -,$(PODKOP_RELEASE_VERSION))
PODKOP_BASE_VERSION:=$(or $(PODKOP_BASE_VERSION),$(if $(PODKOP_LEGACY_RELEASE),$(word 1,$(subst -, ,$(PODKOP_RELEASE_VERSION))),$(PODKOP_RELEASE_VERSION)))
PODKOP_FORK_RELEASE:=$(or $(PODKOP_FORK_RELEASE),$(if $(PODKOP_LEGACY_RELEASE),$(word 2,$(subst -, ,$(PODKOP_RELEASE_VERSION))),))
PODKOP_COMPILED_VERSION:=$(if $(PODKOP_HAS_RELEASE_VERSION),$(if $(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)-$(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)),$(or $(PODKOP_SOURCE_VERSION),dev))
PODKOP_SDK_VERSION:=$(if $(PODKOP_HAS_RELEASE_VERSION),$(if $(PODKOP_IS_APK),$(PODKOP_BASE_VERSION),$(PODKOP_COMPILED_VERSION)),$(PODKOP_BASE_VERSION))
PODKOP_SDK_RELEASE:=$(if $(PODKOP_IS_APK),$(PODKOP_FORK_RELEASE),)

PKG_VERSION:=$(PODKOP_SDK_VERSION)
PKG_RELEASE:=$(PODKOP_SDK_RELEASE)

PKG_MAINTAINER:=ushan0v <ushan0v@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/podkop-plus
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun +curl +ucode +ucode-mod-fs +ucode-mod-uci +kmod-nft-tproxy +coreutils-base64 +coreutils-sort +bind-dig +nftables +kmod-nft-nat +ip-full
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=Podkop Plus backend service
	URL:=https://github.com/ushan0v/podkop-plus
	PKGARCH:=all
endef

define Package/podkop-plus/description
	Rule-based Podkop Plus backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/podkop-plus/preinst
#!/usr/bin/ucode

let fs = require("fs");

if (getenv("IPKG_INSTROOT") != null && getenv("IPKG_INSTROOT") != "")
	exit(0);

if (fs.stat("/etc/config/podkop-plus") == null && fs.stat("/etc/config/podkop_plus") != null) {
	let data = fs.readfile("/etc/config/podkop_plus");
	if (data == null || fs.writefile("/etc/config/podkop-plus", data) == null)
		exit(1);
	system("chmod 0644 /etc/config/podkop-plus >/dev/null 2>&1");
}

exit(0);
endef

define Package/podkop-plus/prerm
#!/usr/bin/ucode

if (getenv("IPKG_INSTROOT") == null || getenv("IPKG_INSTROOT") == "")
	system("/usr/bin/podkop-plus package_prerm >/dev/null 2>&1");

exit(0);
endef

define Package/podkop-plus/conffiles
/etc/config/podkop-plus
endef

define Package/podkop-plus/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/podkop $(1)/etc/init.d/podkop-plus

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/podkop $(1)/etc/config/podkop-plus

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/podkop $(1)/usr/bin/podkop-plus

	$(INSTALL_DIR) $(1)/usr/lib/podkop-plus
	$(CP) ./files/usr/lib/. $(1)/usr/lib/podkop-plus/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PODKOP_COMPILED_VERSION)/g' $(1)/usr/lib/podkop-plus/core/constants.uc
endef

$(eval $(call BuildPackage,podkop-plus))
