# TTL / hop-limit normalizer for the H5000M cellular uplink. Config/script-only (no
# compiled code): ships a UCI config, an apply helper that generates an fw4 nftables
# include from that config, an iface hotplug hook that reapplies it across device
# re-enumeration, and a uci-defaults backfill. The FM350 has no TTL AT command, so this
# is done router-side with nftables, mirroring the stock luci-app-qmodem-ttlfw4.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-ttl
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-ttl
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=H5000M cellular TTL/hop-limit normalizer
  # firewall4 supplies both `fw4` (the reload we invoke) and the /usr/share/nftables.d include
  # mechanism the generated rule relies on. Runtime-only official-feed dep => EXTRA_DEPENDS.
  EXTRA_DEPENDS:=firewall4 (>=0)
  PKGARCH:=all
endef

define Package/h5000m-ttl/description
  Pins the IPv4 TTL and IPv6 hop-limit of packets egressing the cellular uplink to a
  fixed value (default 64) so a carrier cannot fingerprint tethering by the modem's TTL.
  Off by default. Generates a /usr/share/nftables.d/chain-post include from UCI, resolving the
  interface's live L3 device from ubus (never a hard-coded netdev name), reapplying it on iface
  hotplug. Because fw4 flow offloading bypasses the postrouting hook the rule uses, the
  apply helper disables flow_offloading/flow_offloading_hw while enabled (opt-out via the
  manage_offload option); otherwise only a flow's first packets would be rewritten.
endef

# Mark the UCI config as a conffile so user edits survive sysupgrade/opkg upgrade.
define Package/h5000m-ttl/conffiles
/etc/config/h5000m-ttl
endef

define Build/Compile
endef

define Package/h5000m-ttl/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/h5000m-ttl \
		$(1)/etc/config/h5000m-ttl
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/h5000m-ttl-apply \
		$(1)/usr/libexec/h5000m-ttl-apply
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/30-h5000m-ttl \
		$(1)/etc/hotplug.d/iface/30-h5000m-ttl
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-h5000m-ttl \
		$(1)/etc/uci-defaults/99-h5000m-ttl
endef

$(eval $(call BuildPackage,h5000m-ttl))
