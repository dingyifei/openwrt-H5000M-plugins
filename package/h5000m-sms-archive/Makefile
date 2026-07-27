# Router-side SMS FIFO archiver for the FM350-GL.
# Config/script-only. The grouping logic and AT layer live in h5000m-modem-atd; message I/O
# goes through h5000m-sms.
include $(TOPDIR)/rules.mk

PKG_NAME:=h5000m-sms-archive
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_MAINTAINER:=H5000M
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/h5000m-sms-archive
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=H5000M SMS FIFO archiver
  # All hard: the archiver is meaningless without the SMS wrapper, the shared grouping module
  # (in h5000m-modem-atd) and the ucode runtime it and the worker are written in. ucode-mod-fs
  # supplies the atomic writefile/rename the worker uses for the archive file.
  DEPENDS:=+h5000m-sms +h5000m-modem-atd +ucode +ucode-mod-fs
  PKGARCH:=all
endef

define Package/h5000m-sms-archive/description
  Watches the FM350-GL's tiny SMS store and, once usage crosses a threshold, copies the oldest
  messages to persistent router storage (/etc/h5000m/sms-archive.json) and deletes them from the
  modem, so the store never silently fills. Archive-before-delete with a resume/reconcile pass
  makes a crash duplicate-safe rather than data-losing; deletion matches on
  (index, sender, timestamp) so a recycled storage slot is never mistaken for the archived
  message. Ships DISABLED; enable via h5000m.sms_archive.enabled=1. The archive is included in
  sysupgrade backups via /lib/upgrade/keep.d.
endef

define Build/Compile
endef

define Package/h5000m-sms-archive/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/h5000m-sms-archive $(1)/usr/sbin/h5000m-sms-archive
	$(INSTALL_BIN) ./files/usr/sbin/h5000m-sms-archive-worker \
		$(1)/usr/sbin/h5000m-sms-archive-worker
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/h5000m-sms-archive $(1)/etc/init.d/h5000m-sms-archive
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/95-h5000m-sms-archive \
		$(1)/etc/uci-defaults/95-h5000m-sms-archive
	# The archive lives here; create the directory so the worker's first atomic write has
	# somewhere to rename into. The file itself is mutable runtime state, created lazily.
	$(INSTALL_DIR) $(1)/etc/h5000m
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/h5000m-sms-archive \
		$(1)/lib/upgrade/keep.d/h5000m-sms-archive
endef

# Enable the service at install so it is supervised from the next boot. Guarded by IPKG_INSTROOT
# so an offline rootfs image build never touches a live init system - the same pattern
# luci-app-fm350's postinst uses. The service ships DISABLED in UCI, so enabling it here only
# starts the supervisor loop; it does no archiving until h5000m.sms_archive.enabled=1.
define Package/h5000m-sms-archive/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/h5000m-sms-archive enable 2>/dev/null
	/etc/init.d/h5000m-sms-archive start 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,h5000m-sms-archive))
