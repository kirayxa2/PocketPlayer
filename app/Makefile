# PocketPoster — companion iOS app for PocketPlayer.
#
# Built as a separate .deb so it ships independently from the tweak.
# Run from the repo root:
#
#     make -C app package           # build the .app and wrap it in a .deb
#     ./scripts/deploy-app.sh       # build + scp + dpkg -i + uicache
#
# Theos puts the resulting .deb into ../packages/.
#
# Rootless, iOS 15+, arm64/arm64e — same target triple as the tweak.

THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

# Where the resulting .deb / build intermediates land. Keep them next to
# the tweak's so deploy-app.sh can find them with the same logic.
THEOS_BUILD_DIR     ?= ..
THEOS_OBJ_DIR_NAME  ?= obj/app
THEOS_PACKAGE_DIR   ?= ../packages

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PocketPoster

PocketPoster_FILES = \
    main.m \
    PPAppDelegate.m \
    PPRootViewController.m \
    PPDetailViewController.m \
    PPWallpaperLibrary.m \
    PPApplyBridge.m

PocketPoster_FRAMEWORKS    = UIKit Foundation CoreGraphics QuartzCore UniformTypeIdentifiers
PocketPoster_PRIVATE_FRAMEWORKS =
PocketPoster_LIBRARIES     = z
PocketPoster_CFLAGS        = -fobjc-arc \
                             -Wno-deprecated-declarations \
                             -Wno-unused-variable
# We don't sandbox-escape; standard entitlements are fine. If we later
# need to write into /var/mobile/Library/PosterPlayer, add a helper
# that runs as root or use a privileged tweak channel.
PocketPoster_CODESIGN_FLAGS = -SResources/Entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
