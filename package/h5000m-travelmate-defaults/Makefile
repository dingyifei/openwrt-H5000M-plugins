# Example custom "glue" package — establishes the pattern for H5000M default/policy packages.
# Config-only (no compiled code): ships an idempotent uci-defaults script. No baked SSID/PSK.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-travelmate-defaults
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-travelmate-defaults
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=H5000M Travelmate defaults
  DEPENDS:=+travelmate +luci-app-travelmate +wpad-openssl
  PKGARCH:=all
endef

define Package/h5000m-travelmate-defaults/description
  First-boot defaults for Travelmate on the H5000M: normalize exactly one disabled
  mode='sta' Wi-Fi interface bound to a trm_wwan network owned by Travelmate. Idempotent;
  preserves the base's discovered AP sections; contains no upstream SSID or PSK.
endef

define Build/Compile
endef

define Package/h5000m-travelmate-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-h5000m-travelmate \
		$(1)/etc/uci-defaults/99-h5000m-travelmate
endef

$(eval $(call BuildPackage,h5000m-travelmate-defaults))
