include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tachyon

TACHYON_SOURCE_VERSION:=$(or $(TACHYON_PACKAGE_VERSION),$(TACHYON_VERSION))
TACHYON_HAS_RELEASE_VERSION:=$(if $(filter dev,$(TACHYON_SOURCE_VERSION)),,$(TACHYON_SOURCE_VERSION))
TACHYON_COMPILED_VERSION:=$(if $(TACHYON_HAS_RELEASE_VERSION),$(TACHYON_SOURCE_VERSION),$(or $(TACHYON_SOURCE_VERSION),dev))
TACHYON_RELEASE_VERSION_VALID:=$(if $(TACHYON_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(TACHYON_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(TACHYON_RELEASE_VERSION_VALID),)
$(error TACHYON_PACKAGE_VERSION and TACHYON_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(TACHYON_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_TITLE:=LuCI Tachyon app
LUCI_DEPENDS:=+luci-base +tachyon
LUCI_PROVIDES:=luci-app-forkop
LUCI_REPLACES:=luci-app-forkop
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=Dushnilin <dushnilin@gmail.com>
LUCI_DESCRIPTION:=Rule-based Tachyon LuCI app with hybrid sing-box + zapret orchestration
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-or-later
LUCI_LANGUAGES:=en ru

define Build/Prepare/$(PKG_NAME)
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(TACHYON_COMPILED_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/tachyon/main.js || true
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
