# mwan3 failover policy for the H5000M. Config/script-only: ships an idempotent
# uci-defaults script that wires three uplinks (wired wan > Travelmate Wi-Fi > FM350
# cellular) into a metric-ordered failover policy, plus a mwan3 hook that keeps Tailscale
# out of mwan3's policy routing.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-mwan3-policy
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-mwan3-policy
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=H5000M mwan3 failover policy
  DEPENDS:=+mwan3 +luci-app-mwan3
  PKGARCH:=all
endef

define Package/h5000m-mwan3-policy/description
  First-boot mwan3 defaults for the H5000M: three members in strict failover priority -
  wan (wired, metric 1), trm_wwan (Travelmate Wi-Fi, metric 2), cellular (FM350, metric
  3) - a balanced_or_failover policy chaining them by metric, and a catch-all rule.
  Tracks public IPs (1.1.1.1/8.8.8.8/9.9.9.9), not gateways, because the cellular link's
  gateway is a point-to-point pseudo-gateway that never answers ICMP. Idempotent (named
  sections only) and hard-codes no netdev name. Also ships an iface hotplug hook that
  excludes tailscale0 from mwan3 marking, ordered after mwan3's own 16-mwan3-user:
  upstream owns /etc/mwan3.user as a conffile, and /etc/mwan3.user.d/ is not a real
  extension point (upstream mwan3.user sources nothing).
endef

define Build/Compile
endef

define Package/h5000m-mwan3-policy/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-h5000m-mwan3 \
		$(1)/etc/uci-defaults/99-h5000m-mwan3
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/17-h5000m-mwan3-tailscale \
		$(1)/etc/hotplug.d/iface/17-h5000m-mwan3-tailscale
endef

$(eval $(call BuildPackage,h5000m-mwan3-policy))
