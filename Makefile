# PocketPlayer - PosterBoard-style animated lockscreen for iOS 15 (Dopamine, rootless)
#
# Build:   make package
# Deploy:  make do        (requires THEOS_DEVICE_IP / THEOS_DEVICE_USER env vars)
# Or use: ./scripts/deploy.sh

TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# Rootless (Dopamine, palera1n)
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PocketPlayer

PocketPlayer_FILES        = Tweak.x CAMLParser.m
PocketPlayer_CFLAGS       = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
PocketPlayer_FRAMEWORKS   = UIKit QuartzCore Foundation CoreGraphics ImageIO MobileCoreServices

include $(THEOS_MAKE_PATH)/tweak.mk

# Convenience target: clean + build
.PHONY: rebuild
rebuild:
	$(MAKE) clean
	$(MAKE) package
