# PocketPlayer - animated lockscreen wallpapers for iOS 15 (Dopamine, rootless)
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

# ----- Companion app (separate .deb, lives in app/) -----
# These targets shell out into app/ via scripts/deploy-app.sh, which
# builds Theos in a clean env (the parent make's THEOS_*/MAKEFLAGS
# would otherwise leak in and confuse the app's APPLICATION_NAME
# build). Use them instead of cd app && make package.

.PHONY: app app-deploy app-clean
app:
	./scripts/deploy-app.sh build-only

app-deploy:
	./scripts/deploy-app.sh

app-clean:
	rm -rf app/.theos app/packages

# ----- LockForge tweak (separate .deb, lives in lockforge/) -----
# Independent tweak that adds iOS 16/26-style lock-screen editor
# (long-press, custom clock fonts/colors/sizes, Liquid Glass).
# Loads alongside PocketPlayer in the SpringBoard process.

.PHONY: lockforge lockforge-deploy lockforge-clean
lockforge:
	./scripts/deploy-lockforge.sh build-only

lockforge-deploy:
	./scripts/deploy-lockforge.sh

lockforge-clean:
	rm -rf lockforge/.theos lockforge/packages
