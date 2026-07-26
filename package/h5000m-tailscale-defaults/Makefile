# Config-only "glue" package for the H5000M — ships an idempotent uci-defaults script.
# Wires the tailscale0 firewall zone and lan<->tailscale forwarding. No auth key baked in.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-tailscale-defaults
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-tailscale-defaults
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=H5000M Tailscale defaults
  DEPENDS:=+tailscale +kmod-tun +luci-app-tailscale-community
  PKGARCH:=all
endef

define Package/h5000m-tailscale-defaults/description
  First-boot defaults for Tailscale on the H5000M: create a firewall zone for the
  tailscale0 interface and forwarding both ways between it and lan. Idempotent; ships
  logged out (no auth key baked in, never runs `tailscale up`).
endef

define Build/Compile
endef

define Package/h5000m-tailscale-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-h5000m-tailscale \
		$(1)/etc/uci-defaults/99-h5000m-tailscale
endef

$(eval $(call BuildPackage,h5000m-tailscale-defaults))
