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
    LFLiquidGlassMetalView.m \
    LFGyroscopeManager.m \
    LFClockOverlay.m \
    LFLockEditor.m \
    LFLockScreenSelector.m

LockForge_CFLAGS      = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
# CoreText: registers the bundled ADTNumeric.ttc (Apple's iOS 26 Adaptive-
# Time font collection, 13 numeric faces) into SpringBoard at %ctor time
# so LFClockOverlay can drive the HGHT axis for iOS 26-style clock resize.
#
# Metal + MetalKit + MetalPerformanceShaders: drive the LiquidGlassKit
# shader pipeline in LFLiquidGlassMetalView. The shader binary
# (LiquidGlassShaders.metallib) is compiled by .github/workflows/
# compile-metal.yml on a macOS runner from the byte-identical upstream
# LiquidGlassKit/{LiquidGlassFragment,LiquidGlassVertex}.metal sources;
# it lands in layout/Library/LockForge/ and Theos packages it into the
# .deb. MetalPerformanceShaders ships MPSImageGaussianBlur which the
# host code uses to soften the captured backdrop before refraction --
# matches LiquidGlassKit's blurTexture() path.
#
# CoreVideo: CVPixelBuffer + CVMetalTextureCache for the zero-copy
# CGContext<->MTLTexture bridge (mirrors LiquidGlassKit's ZeroCopyBridge).
LockForge_FRAMEWORKS  = UIKit QuartzCore Foundation CoreGraphics CoreMotion CoreText \
                       Metal MetalKit MetalPerformanceShaders CoreVideo

include $(THEOS_MAKE_PATH)/tweak.mk

.PHONY: rebuild
rebuild:
	$(MAKE) clean
	$(MAKE) package
