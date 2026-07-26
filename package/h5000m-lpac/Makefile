# Thin eSIM (lpac) wrapper for the H5000M. Config/script-only: ships one shell wrapper
# that runs upstream `lpac` under the FM350 AT-port lease so eSIM APDU conversations can
# never collide with the dialer on the modem's single working AT port.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-lpac
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-lpac
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=H5000M eSIM (lpac) wrapper
  # lpac supplies the eUICC CLI; h5000m-modem-atd supplies at-lease + the AT port
  # discovery/lock this wrapper leases the port through.
  DEPENDS:=+h5000m-modem-atd +lpac
  PKGARCH:=all
endef

define Package/h5000m-lpac/description
  Ships h5000m-esim, a thin wrapper that runs lpac's AT APDU backend against the FM350-GL
  through at-lease. at-lease holds the same flock every AT consumer takes for lpac's whole
  lifetime and exports MODEM_AT_B (the leased port), so lpac never has to name a ttyUSB
  node. Whether this unit has an eUICC at all is UNCONFIRMED - `h5000m-esim chip info` is
  the command that settles it; nothing here assumes one exists.
endef

define Build/Compile
endef

define Package/h5000m-lpac/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/h5000m-esim $(1)/usr/sbin/h5000m-esim
endef

$(eval $(call BuildPackage,h5000m-lpac))
