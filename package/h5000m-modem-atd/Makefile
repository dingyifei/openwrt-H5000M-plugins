# AT broker for the Fibocom FM350-GL (USB 0e8d:7127) on the clean official mt76 base.
# Config/script-only. Split out from h5000m-fm350 because it has >=4 consumers:
# the dialer, status polling, lpac (eSIM) and humans at the shell.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-modem-atd
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-modem-atd
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=H5000M FM350 AT port broker
  # No kmod-usb-acm: verified on hardware that this modem exposes no CDC-ACM class
  # interface. If#0 is 02/02/ff (RNDIS control), If#1 is 0a/00/00 (RNDIS data) and the
  # seven AT/diag ports are all ff/00/00, which upstream option.c claims explicitly
  # (option.c: USB_DEVICE_AND_INTERFACE_INFO(0x0e8d, 0x7127, 0xff, 0x00, 0x00)).
  # busybox has no stty, so coreutils-stty is required to put the port in raw mode.
  EXTRA_DEPENDS:=kmod-usb-serial-option (>=0), kmod-usb-net-rndis (>=0), coreutils-stty (>=0)
  PKGARCH:=all
endef

define Package/h5000m-modem-atd/description
  Discovers the FM350-GL's AT ports by walking sysfs for USB 0e8d:7127 and probing
  candidates, then publishes stable /dev/modem-at0 (exclusive, dialer-owned) and
  /dev/modem-at1 (flock-leased) symlinks. Never hard-codes a ttyUSB name: locks are
  keyed on the stable USB topology path so they survive renumbering. Ships atq for
  one-shot commands and at-lease for handing the leased port to a foreign tool.
endef

define Build/Compile
endef

define Package/h5000m-modem-atd/install
	$(INSTALL_DIR) $(1)/usr/lib/h5000m
	$(INSTALL_DATA) ./files/usr/lib/h5000m/log.sh $(1)/usr/lib/h5000m/log.sh
	$(INSTALL_DATA) ./files/usr/lib/h5000m/atio.sh $(1)/usr/lib/h5000m/atio.sh
	$(INSTALL_DATA) ./files/usr/lib/h5000m/modem-discover.sh \
		$(1)/usr/lib/h5000m/modem-discover.sh
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/atq $(1)/usr/sbin/atq
	$(INSTALL_BIN) ./files/usr/sbin/at-lease $(1)/usr/sbin/at-lease
	$(INSTALL_BIN) ./files/usr/sbin/modem-ports $(1)/usr/sbin/modem-ports
	$(INSTALL_BIN) ./files/usr/sbin/h5000m-log-capture $(1)/usr/sbin/h5000m-log-capture
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/h5000m $(1)/etc/config/h5000m
	$(INSTALL_DIR) $(1)/etc/hotplug.d/tty
	$(INSTALL_DATA) ./files/etc/hotplug.d/tty/20-h5000m-modem \
		$(1)/etc/hotplug.d/tty/20-h5000m-modem
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_DATA) ./files/etc/hotplug.d/usb/20-h5000m-modem \
		$(1)/etc/hotplug.d/usb/20-h5000m-modem
endef

$(eval $(call BuildPackage,h5000m-modem-atd))
