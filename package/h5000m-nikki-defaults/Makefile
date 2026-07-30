# H5000M nikki default profile — config-only "glue" package (no compiled code).
# Ships a credential-free JMS/mihomo profile template + an idempotent uci-defaults installer.
# No baked subscription URL.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-nikki-defaults
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-nikki-defaults
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=H5000M nikki (mihomo) default profile
  EXTRA_DEPENDS:=nikki (>=0), luci-app-nikki (>=0)
  PKGARCH:=all
endef

define Package/h5000m-nikki-defaults/description
  First-boot default for nikki on the H5000M: if no nikki profile exists yet, install a
  credential-free JMS/mihomo profile (a mihomo proxy-provider with a PLACEHOLDER subscription
  URL, a url-test failover group, and LAN-direct rules) and point nikki at it. Idempotent;
  never overwrites an existing profile, never enables nikki, and contains no subscription URL.
endef

define Build/Compile
endef

define Package/h5000m-nikki-defaults/install
	$(INSTALL_DIR) $(1)/usr/share/h5000m
	$(INSTALL_DATA) ./files/usr/share/h5000m/nikki-jms-profile.yaml \
		$(1)/usr/share/h5000m/nikki-jms-profile.yaml
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-h5000m-nikki \
		$(1)/etc/uci-defaults/99-h5000m-nikki
endef

$(eval $(call BuildPackage,h5000m-nikki-defaults))
