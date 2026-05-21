# PocketPoster — companion iOS app for PocketPlayer.
#
# Built as a separate .deb so it ships independently from the tweak.
# Run from the repo root:
#
#     make -C app package           # build the .app and wrap it in a .deb
#     ./scripts/deploy-app.sh       # build + scp + dpkg -i + uicache
#
# Theos puts the resulting .deb into app/packages/.
#
# Rootless, iOS 15+, arm64/arm64e — same target triple as the tweak.

THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS  := arm64 arm64e

# Don't override THEOS_BUILD_DIR / THEOS_OBJ_DIR_NAME / THEOS_PACKAGE_DIR.
# With APPLICATION_NAME + multi-arch builds Theos picks app-bundle paths
# at several layers (obj/<scheme>/, obj/<scheme>/<arch>/, link stage,
# stage/) and the rsync that stages the .app into the .deb assumes those
# paths line up. Custom overrides quietly break stage. Defaults put the
# .deb at app/packages/com.vortex.pocketposter_*.deb -- deploy-app.sh
# looks there.
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PocketPoster

PocketPoster_FILES = \
    main.m \
    PPAppDelegate.m \
    PPRootViewController.m \
    PPBrowseViewController.m \
    PPCatalogService.m \
    PPCatalogItem.m \
    PPDetailViewController.m \
    PPWallpaperLibrary.m \
    PPApplyBridge.m \
    PPPreviewRenderer.m \
    PPWallpaperResizer.m \
    PPImportProgressViewController.m \
    PPSettingsViewController.m \
    ../CAMLParser.m

PocketPoster_FRAMEWORKS    = UIKit Foundation CoreGraphics QuartzCore UniformTypeIdentifiers
PocketPoster_PRIVATE_FRAMEWORKS =
PocketPoster_LIBRARIES     = z
# CAMLParser.h lives one directory up; pulling it in lets the app
# reuse the same parser that runs in SpringBoard, so any wallpaper
# the tweak can play, the app can also generate a preview for.
PocketPoster_CFLAGS        = -fobjc-arc \
                             -I.. \
                             -Wno-deprecated-declarations \
                             -Wno-unused-variable
# We don't sandbox-escape; standard entitlements are fine. If we later
# need to write into /var/mobile/Library/PosterPlayer, add a helper
# that runs as root or use a privileged tweak channel.
PocketPoster_CODESIGN_FLAGS = -SResources/Entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
