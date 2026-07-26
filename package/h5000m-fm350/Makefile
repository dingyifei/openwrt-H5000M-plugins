# FM350-GL cellular uplink: netifd protocol handler + dialer.
# Config/script-only. The AT layer lives in h5000m-modem-atd.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-fm350
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-fm350
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=H5000M FM350 cellular uplink (netifd proto)
  # 464xlat + kmod-nat46 are NOT optional: the FM350's Intel XMM does not run CLAT
  # itself, so on an IPv6-only grant (T-Mobile US and friends) IPv4 is simply absent
  # unless the router provides it, which looks exactly like a wrong APN.
  DEPENDS:=+h5000m-modem-atd
  EXTRA_DEPENDS:=464xlat (>=0), kmod-nat46 (>=0)
  PKGARCH:=all
endef

define Package/h5000m-fm350/description
  Brings up the FM350-GL's RNDIS data path over an AT control channel. Registers a
  custom netifd protocol 'fm350' so the uplink has a stable UCI interface name
  (cellular) decoupled from the volatile RNDIS netdev - which is what mwan3 and any
  later egress selector need. APN selection is blank-first (the subscription default,
  which 3GPP guarantees exists) with an IMSI table only as an optimisation.
endef

define Build/Compile
endef

define Package/h5000m-fm350/install
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/lib/netifd/proto/fm350.sh $(1)/lib/netifd/proto/fm350.sh
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/fm350-dialer $(1)/usr/sbin/fm350-dialer
	$(INSTALL_DIR) $(1)/usr/lib/h5000m
	$(INSTALL_DATA) ./files/usr/lib/h5000m/apn-table $(1)/usr/lib/h5000m/apn-table
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/98-h5000m-fm350 \
		$(1)/etc/uci-defaults/98-h5000m-fm350
endef

$(eval $(call BuildPackage,h5000m-fm350))
