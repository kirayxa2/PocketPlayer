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
PocketPlayer_FRAMEWORKS   = UIKit QuartzCore Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

# Convenience target: clean + build
.PHONY: rebuild app app-clean app-deploy
rebuild:
	$(MAKE) clean
	$(MAKE) package

# Build the PocketPoster companion app (separate .deb).
# IMPORTANT: when this Makefile runs, Theos has already exported
# THEOS_PROJECT_DIR pointing at the tweak's directory. If we just do
# 'make -C app', the child make inherits that and Theos thinks the app
# project is rooted here -- the .app bundle ends up in .theos/obj/debug/
# of THIS directory while bundle.mk's rsync stage rule looks for it in
# app/.theos/, or vice versa, and stage fails with ENOENT.
#
# We unexport every Theos-internal variable that locks the child build
# to our directory, then run a brand-new make in app/. Same trick the
# script uses; mirroring it here so 'make app' works without the
# wrapper script.
app:
	env -u THEOS_PROJECT_DIR -u THEOS_BUILD_DIR -u THEOS_OBJ_DIR \
	    -u THEOS_OBJ_DIR_NAME -u THEOS_PACKAGE_DIR -u THEOS_STAGING_DIR \
	    -u _THEOS_CURRENT_PACKAGE -u _THEOS_CURRENT_TYPE \
	    -u _THEOS_RULES_LOADED -u _THEOS_COMMON_LOADED \
	    $(MAKE) -C app package

app-clean:
	rm -rf app/.theos app/packages

# End-to-end: build + scp + install + uicache.
app-deploy:
	./scripts/deploy-app.sh
