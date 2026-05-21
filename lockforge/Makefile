# LockForge - iOS 16/26-style lock screen editor on iOS 15.
#
# Build:   make -C lockforge package
# Or via top-level: make lockforge / make lockforge-deploy
#
# Builds an INDEPENDENT .deb (com.vortex.lockforge) that runs alongside
# PocketPlayer's tweak. They share the SpringBoard process but don't
# share any code or hooked classes -- LockForge hooks the date / time /
# widget views, PocketPlayer hooks the cover sheet container.

THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LockForge

LockForge_FILES = \
    Tweak.x \
    LFClockSettings.m \
    LFLiquidGlassView.m \
    LFGyroscopeManager.m \
    LFClockOverlay.m \
    LFLockEditor.m \
    LFLockScreenSelector.m

LockForge_CFLAGS      = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
# CoreText is for CTFontManagerRegisterFontsForURL + variable-axis CTFont
# creation. We register the bundled SF-Pro.ttf (variable font with
# wght/wdth/opsz axes) into the SpringBoard process at %ctor time, then
# LFClockOverlay creates per-frame CTFonts with custom (wght, wdth)
# values to match Apple's iOS 26 lock-screen-clock resize behaviour.
LockForge_FRAMEWORKS  = UIKit QuartzCore Foundation CoreGraphics CoreMotion CoreText

include $(THEOS_MAKE_PATH)/tweak.mk

.PHONY: rebuild
rebuild:
	$(MAKE) clean
	$(MAKE) package
