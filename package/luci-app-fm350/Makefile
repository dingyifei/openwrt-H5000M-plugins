# LuCI application for the FM350-GL: status, SMS and recovery actions.
#
# Plain package.mk rather than luci.mk: luci.mk lives at the root of the luci feed, so the
# in-tree `include ../../luci.mk` cannot resolve from an out-of-tree feed, and
# $(TOPDIR)/feeds/luci/luci.mk would add a dependency on the luci checkout plus lua/host
# and luci-base/host build deps. Hand-rolling the install recipe is ~20 lines and keeps
# this structurally identical to luci-proto-fm350.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fm350
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fm350
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI status, SMS and recovery for the FM350-GL modem
  # rpcd-mod-ucode is what loads the backend; without it the ubus object never appears and
  # every page shows "Access denied". h5000m-modem-atd supplies atq and the AT lock.
  DEPENDS:=+luci-base +rpcd-mod-ucode +h5000m-modem-atd
  # Both soft: the whole SMS area is optional. Present -> the inbox lists live messages and the
  # archiver's saved ones; absent -> the SMS page simply shows whatever the modem still holds.
  EXTRA_DEPENDS:=h5000m-sms (>=0), h5000m-sms-archive (>=0)
  PKGARCH:=all
endef

define Package/luci-app-fm350/description
  Web UI for the Fibocom FM350-GL: signal and bearer status, an SMS inbox and composer,
  and the two recovery actions (reconnect, and the USB-level modem reset that restores a
  half-dead AT endpoint). All modem access goes through atq and h5000m-sms at the lowest
  AT priority tier, so the page can never delay the dialer that keeps the link up.
endef

define Build/Compile
endef

define Package/luci-app-fm350/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/fm350
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/fm350/*.js \
		$(1)/www/luci-static/resources/view/fm350/
	# Shared, non-view modules (the cell-lock/apply-progress controller the three views require).
	$(INSTALL_DIR) $(1)/www/luci-static/resources/fm350
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fm350/*.js \
		$(1)/www/luci-static/resources/fm350/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-fm350.json \
		$(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-fm350.json \
		$(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_BIN) ./root/usr/share/rpcd/ucode/luci.fm350 \
		$(1)/usr/share/rpcd/ucode/
endef

# MANDATORY, and the single most common out-of-tree LuCI mistake. luci.mk generates this;
# we do not get it for free. Without the rpcd reload, rpcd never loads the new ucode
# backend OR learns the new ACL group, so the menu entry silently vanishes or every page
# reports "Access denied" until the next reboot.
define Package/luci-app-fm350/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-fm350))
