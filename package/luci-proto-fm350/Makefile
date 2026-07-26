# LuCI protocol handler for the custom 'fm350' netifd protocol.
#
# Without this LuCI cannot render the cellular interface at all - it shows
# "unsupported protocol type / install extension protocol", because LuCI only draws a form
# for protocols it has a JS handler for. This ships that handler; it changes no behaviour,
# the proto and dialer in h5000m-fm350 do the actual work.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-fm350
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-fm350
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for the H5000M FM350 cellular protocol
  DEPENDS:=+h5000m-fm350 +luci-base
  PKGARCH:=all
endef

define Package/luci-proto-fm350/description
  Registers the 'fm350' protocol with LuCI so the cellular interface is editable from the
  web UI (APN, PDP type, context id, metric, MTU). Purely presentational: netifd and the
  dialer are unaffected by whether this is installed.
endef

define Build/Compile
endef

define Package/luci-proto-fm350/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./files/www/luci-static/resources/protocol/fm350.js \
		$(1)/www/luci-static/resources/protocol/fm350.js
endef

$(eval $(call BuildPackage,luci-proto-fm350))
