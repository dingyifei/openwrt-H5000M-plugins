# Thin SMS wrapper for the H5000M. Config/script-only: ships one shell wrapper that runs
# upstream sms_tool under the FM350 AT-port lease, so SMS traffic can never collide with
# the dialer on the modem's single working AT port.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-sms
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-sms
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=H5000M SMS (sms_tool) wrapper
  # h5000m-modem-atd supplies at-lease plus the AT port discovery/lock this wrapper leases
  # the port through. sms-tool is EXTRA_DEPENDS rather than DEPENDS so it is injected at
  # pack time instead of becoming a kconfig 'select' that forces a source build.
  #
  # NOTE the naming: the OpenWrt package is 'sms-tool' (hyphen), the binary it installs is
  # /usr/bin/sms_tool (underscore). `apk add sms_tool` fails, and grepping a feed index for
  # 'sms_tool' finds only the upstream URL inside the description - which reads as absent.
  DEPENDS:=+h5000m-modem-atd
  EXTRA_DEPENDS:=sms-tool (>=0)
  PKGARCH:=all
endef

define Package/h5000m-sms/description
  Ships h5000m-sms, a thin wrapper that runs sms_tool against the FM350-GL through
  at-lease. at-lease holds the same flock every AT consumer takes and exports MODEM_AT_B
  (the leased port), so no ttyUSB node is ever named - they renumber across
  re-enumeration. sms_tool itself handles PDU mode, UCS2 and multipart reassembly, so
  nothing here parses PDUs.
endef

define Build/Compile
endef

define Package/h5000m-sms/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/h5000m-sms $(1)/usr/sbin/h5000m-sms
endef

$(eval $(call BuildPackage,h5000m-sms))
