#import "LFLiquidGlassMetalView.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

// =====================================================================
// LiquidGlass.ShaderUniforms -- Obj-C mirror of the Swift struct.
//
// MUST stay bit-for-bit identical to:
//   - `struct ShaderUniforms` in LiquidGlassKit/LiquidGlassFragment.metal
//   - `struct ShaderUniforms` in LiquidGlassKit/LiquidGlassView.swift
//
// Field order, type, and size are read directly by the GPU via the
// uniforms buffer at fragment-buffer index 0; if you re-order or
// resize anything here, the shader will read garbage. The metal-side
// struct uses `float4 rectangles[16]`; we mirror with a fixed-size
// array of simd_float4. simd alignment is 16 bytes per float4 so the
// total is naturally aligned and we don't need any pragma packing.
// =====================================================================
#define kLFGlassMaxRectangles 16

typedef struct {
    simd_float2 resolution;             // viewport pixels
    float       contentsScale;          // [UIScreen mainScreen].scale
    simd_float2 touchPoint;             // tilt-driven point (pts, UL origin)
    float       shapeMergeSmoothness;
    float       cornerRadius;           // pts
    float       cornerRoundnessExponent;// 1=diamond, 2=circle, 4=squircle
    simd_float4 materialTint;           // RGBA premultiplied weight
    float       glassThickness;         // simulated thickness (pts)
    float       refractiveIndex;        // ~1.5 borosilicate
    float       dispersionStrength;     // 0..0.02 prism intensity
    float       fresnelDistanceRange;   // edge falloff (pts)
    float       fresnelIntensity;       // 0..1 rim weight
    float       fresnelEdgeSharpness;   // pow exponent for falloff
    float       glareDistanceRange;     // glare falloff (pts)
    float       glareAngleConvergence;  // 0..pi
    float       glareOppositeSideBias;  // >1 amplifies far-side
    float       glareIntensity;         // 1..4
    float       glareEdgeSharpness;
    float       glareDirectionOffset;   // radians
    int32_t     rectangleCount;
    simd_float4 rectangles[kLFGlassMaxRectangles];
} LFGlassShaderUniforms;

// =====================================================================
// .regular preset -- ported field-for-field from LiquidGlassKit's
//
//     static let regular = Self.init(
//       shaderUniforms: .init(
//         glassThickness: 10,
//         refractiveIndex: 1.5,
//         ...
//
// in LiquidGlassKit/Sources/LiquidGlassKit/LiquidGlassView.swift.
// Any future tweak of these values should also be applied upstream
// (or pulled from upstream) so the visual signature stays the same.
// =====================================================================
static void lf_fillRegularPreset(LFGlassShaderUniforms *u) {
    u->shapeMergeSmoothness     = 0.2f;
    u->cornerRoundnessExponent  = 2.0f;
    u->glassThickness           = 10.0f;
    u->refractiveIndex          = 1.5f;
    u->dispersionStrength       = 5.0f;
    u->fresnelDistanceRange     = 70.0f;
    u->fresnelIntensity         = 0.0f;
    u->fresnelEdgeSharpness     = 0.0f;
    u->glareDistanceRange       = 30.0f;
    u->glareAngleConvergence    = 0.1f;
    u->glareOppositeSideBias    = 1.0f;
    u->glareIntensity           = 0.1f;
    u->glareEdgeSharpness       = -0.15f;
    u->glareDirectionOffset     = -((float)M_PI) / 4.0f;
    // materialTint set per-frame from intensity + tintColor below.
}

// =====================================================================
// CABackdropLayer-backed UIView. Same trick as LiquidGlassKit's
// BackdropView -- swap layerClass to a private CABackdropLayer that
// auto-composites everything beneath it (the wallpaper, other tweaks,
// etc.) into its own contents cache. We then drawHierarchy that view
// to drive a CGContext, which writes straight into a CVPixelBuffer-
// backed MTLTexture (zero-copy).
// =====================================================================
@interface LFLGBackdropView : UIView
@end
@implementation LFLGBackdropView
+ (Class)layerClass {
    Class cls = NSClassFromString(@"CABackdropLayer");
    return cls ?: [CALayer class];
}
- (instancetype)init {
    if ((self = [super init])) {
        self.userInteractionEnabled = NO;
        // Mirror LiquidGlassKit's BackdropView config.
        [self.layer setValue:@(NO)  forKey:@"layerUsesCoreImageFilters"];
        [self.layer setValue:@(YES) forKey:@"windowServerAware"];
        [self.layer setValue:[[NSUUID UUID] UUIDString] forKey:@"groupName"];
    }
    return self;
}
@end

// =====================================================================
// ZeroCopyBridge -- Obj-C port of LiquidGlassKit's ZeroCopyBridge.swift.
//
// One CVPixelBuffer (BGRA8, IOSurface-backed) wraps a CGContext on the
// CPU side and an MTLTexture on the GPU side; both views share memory.
// We lock to draw, unlock + flush to publish to the GPU. The metal
// texture is cached in a CVMetalTextureCache so we don't re-allocate
// on every frame -- only on view resize.
// =====================================================================
@interface LFLGZeroCopyBridge : NSObject {
@public
    CVMetalTextureCacheRef _cache;
    CVPixelBufferRef       _pixelBuffer;
    CVMetalTextureRef      _cvTexture;
    int                    _width;
    int                    _height;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)setupBufferWidth:(int)w height:(int)h;
- (id<MTLTexture>)renderActions:(void(^)(CGContextRef ctx))actions;
@end

@implementation LFLGZeroCopyBridge {
    id<MTLDevice> _device;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        CVReturn rc = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL,
                                                device, NULL, &_cache);
        if (rc != kCVReturnSuccess) {
            NSLog(@"[LockForge] ZeroCopyBridge: failed to create texture cache: %d", rc);
        }
    }
    return self;
}
- (void)dealloc {
    if (_cvTexture)   CFRelease(_cvTexture);
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
    if (_cache)       CFRelease(_cache);
}
- (void)setupBufferWidth:(int)w height:(int)h {
    if (w == _width && h == _height && _pixelBuffer && _cvTexture) return;
    if (_cvTexture)   { CFRelease(_cvTexture);   _cvTexture   = NULL; }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    _width  = w;
    _height = h;

    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferMetalCompatibilityKey:    @YES,
        (NSString *)kCVPixelBufferCGImageCompatibilityKey:  @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey:   @{},
    };
    CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs,
                                      &_pixelBuffer);
    if (rc != kCVReturnSuccess) {
        NSLog(@"[LockForge] ZeroCopyBridge: pixel buffer create failed: %d", rc);
        return;
    }
    rc = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
        _cache, _pixelBuffer, NULL, MTLPixelFormatBGRA8Unorm, w, h, 0,
        &_cvTexture);
    if (rc != kCVReturnSuccess) {
        NSLog(@"[LockForge] ZeroCopyBridge: cv-metal texture create failed: %d", rc);
    }
}
- (id<MTLTexture>)renderActions:(void(^)(CGContextRef))actions {
    if (!_pixelBuffer || !_cache) return nil;
    size_t w  = CVPixelBufferGetWidth(_pixelBuffer);
    size_t h  = CVPixelBufferGetHeight(_pixelBuffer);
    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void  *data        = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(_pixelBuffer);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(data, w, h, 8, bytesPerRow, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
        return nil;
    }
    if (actions) actions(ctx);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_cache, 0);
    return _cvTexture ? CVMetalTextureGetTexture(_cvTexture) : nil;
}
@end

// =====================================================================
// LFLiquidGlassMetalView -- public entry point for the Metal-driven
// glass renderer. Owns the MTKView, the pipeline state, the uniforms
// buffer, the backdrop view, and the zero-copy bridge.
// =====================================================================
@interface LFLiquidGlassMetalView () <MTKViewDelegate>
@property (nonatomic, strong) MTKView                 *mtkView;
@property (nonatomic, strong) LFLGBackdropView        *backdropView;
@property (nonatomic, strong) LFLGZeroCopyBridge      *zeroCopy;

@property (nonatomic, strong) id<MTLDevice>            device;
@property (nonatomic, strong) id<MTLCommandQueue>      commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLBuffer>            uniformsBuffer;
@property (nonatomic, strong) MPSImageGaussianBlur    *blur;

@property (nonatomic, strong) id<MTLTexture>           backgroundTexture;
@property (nonatomic, assign) CGPoint                  shimmerOffset;
@end

@implementation LFLiquidGlassMetalView

#pragma mark - Availability

+ (NSString *)metallibPath {
    NSArray *candidates = @[
        @"/var/jb/Library/LockForge/LiquidGlassShaders.metallib",
        @"/Library/LockForge/LiquidGlassShaders.metallib",
    ];
    for (NSString *p in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

+ (BOOL)isAvailable {
    static BOOL ok = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            NSLog(@"[LockForge] No Metal device -- falling back to UIVisualEffectView.");
            ok = NO;
            return;
        }
        NSString *p = [self metallibPath];
        if (!p) {
            NSLog(@"[LockForge] LiquidGlassShaders.metallib not bundled (CI not run yet?) "
                  @"-- falling back to UIVisualEffectView.");
            ok = NO;
            return;
        }
        ok = YES;
    });
    return ok;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor        = [UIColor clearColor];

    _intensity         = 0;
    _tintColor         = [UIColor whiteColor];
    _glassCornerRadius = 18.0;
    _shimmerOffset     = CGPointZero;

    if (![[self class] isAvailable] || ![self setupMetal]) {
        NSLog(@"[LockForge] Metal pipeline build failed -- LFLiquidGlassMetalView is a no-op.");
        return self;
    }

    [self buildSubviews];
    [self updateUniformsCPUSide];
    return self;
}

- (BOOL)setupMetal {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return NO;

    NSString *path = [[self class] metallibPath];
    NSError *err = nil;
    id<MTLLibrary> lib = [_device newLibraryWithFile:path error:&err];
    if (!lib) {
        NSLog(@"[LockForge] Failed to load metallib at %@: %@", path, err);
        return NO;
    }
    id<MTLFunction> vfn = [lib newFunctionWithName:@"fullscreenQuad"];
    id<MTLFunction> ffn = [lib newFunctionWithName:@"liquidGlassEffect"];
    if (!vfn || !ffn) {
        NSLog(@"[LockForge] Required shader functions missing in metallib.");
        return NO;
    }

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction   = vfn;
    desc.fragmentFunction = ffn;
    desc.colorAttachments[0].pixelFormat                 = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled             = YES;
    desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorOne;
    desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pipeline) {
        NSLog(@"[LockForge] Pipeline state failed: %@", err);
        return NO;
    }

    _commandQueue   = [_device newCommandQueue];
    _uniformsBuffer = [_device newBufferWithLength:sizeof(LFGlassShaderUniforms)
                                            options:MTLResourceStorageModeShared];
    _zeroCopy       = [[LFLGZeroCopyBridge alloc] initWithDevice:_device];

    // Pre-build the Gaussian blur (sigma later, per layoutSubviews).
    // .regular preset uses backgroundTextureBlurRadius = 0.3, scaled by
    // contentsScale at use site -> very small sigma but nonzero, which
    // softens the prism dispersion artefacts visibly.
    _blur = [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:1.0f];
    _blur.edgeMode = MPSImageEdgeModeClamp;
    return YES;
}

- (void)buildSubviews {
    _backdropView = [[LFLGBackdropView alloc] init];
    [self addSubview:_backdropView];

    _mtkView = [[MTKView alloc] initWithFrame:CGRectZero device:_device];
    _mtkView.delegate                 = self;
    _mtkView.userInteractionEnabled   = NO;
    _mtkView.framebufferOnly          = YES;
    _mtkView.opaque                   = NO;
    _mtkView.layer.opaque             = NO;
    _mtkView.backgroundColor          = [UIColor clearColor];
    _mtkView.colorPixelFormat         = MTLPixelFormatBGRA8Unorm;
    _mtkView.clearColor               = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    _mtkView.preferredFramesPerSecond = 30;       // gentle on iPhone 6s A9
    _mtkView.enableSetNeedsDisplay    = NO;
    _mtkView.paused                   = NO;
    [self addSubview:_mtkView];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _backdropView.frame = self.bounds;
    _mtkView.frame      = self.bounds;
    [self updateUniformsCPUSide];

    // Resize the zero-copy texture to match the current bounds. We
    // capture at HALF resolution (matches LiquidGlassKit's default
    // backgroundTextureScaleCoefficient * contentsScale layout) and
    // let the fragment shader sample it bilinearly -- gives a 4x
    // upload-bandwidth savings, invisible after the dispersion
    // offsets and gaussian blur.
    CGFloat scale = ([UIScreen mainScreen].scale) * 0.5;
    int w = (int)(self.bounds.size.width  * scale);
    int h = (int)(self.bounds.size.height * scale);
    if (w > 4 && h > 4) [_zeroCopy setupBufferWidth:w height:h];
}

#pragma mark - Setters

- (void)setIntensity:(NSInteger)v {
    _intensity = MAX(0, MIN(3, v));
    self.hidden = (_intensity == 0);
    [self updateUniformsCPUSide];
}

- (void)setTintColor:(UIColor *)t {
    _tintColor = t ?: [UIColor whiteColor];
    [self updateUniformsCPUSide];
}

- (void)setGlassCornerRadius:(CGFloat)r {
    _glassCornerRadius = MAX(0, r);
    [self updateUniformsCPUSide];
}

- (void)setShimmerOffset:(CGPoint)offset {
    _shimmerOffset = offset;
    [self updateUniformsCPUSide];
}

#pragma mark - Uniforms

- (void)updateUniformsCPUSide {
    if (!_uniformsBuffer) return;

    LFGlassShaderUniforms u;
    memset(&u, 0, sizeof(u));
    lf_fillRegularPreset(&u);

    CGFloat scale = self.window.screen.scale ?: [UIScreen mainScreen].scale;
    u.resolution    = simd_make_float2((float)(self.bounds.size.width  * scale),
                                       (float)(self.bounds.size.height * scale));
    u.contentsScale = (float)scale;
    u.cornerRadius  = (float)_glassCornerRadius;

    // Single rectangle covering the whole MTKView bounds in points.
    u.rectangleCount = 1;
    u.rectangles[0]  = simd_make_float4(0.0f, 0.0f,
                                        (float)self.bounds.size.width,
                                        (float)self.bounds.size.height);

    // touchPoint -- in LiquidGlassKit's demo widgets this is where the
    // user is touching the glass; we feed gyro-tilt instead so the
    // glare/Fresnel terms drift with device tilt. Same shader path.
    u.touchPoint = simd_make_float2(
        (float)(self.bounds.size.width  * 0.5 + _shimmerOffset.x * 12.0),
        (float)(self.bounds.size.height * 0.5 + _shimmerOffset.y * 8.0));

    // Map intensity -> materialTint. The .regular preset has tintColor
    // pre-baked but we override here so the user-visible Glass strength
    // slider/segment still does something. Higher intensity = darker
    // tint with more weight, which the shader mixes into the refracted
    // backdrop and the Fresnel rim.
    CGFloat r = 1, g = 1, b = 1, a = 1;
    [_tintColor getRed:&r green:&g blue:&b alpha:&a];
    float tintWeight = 0.0f;
    switch (_intensity) {
        case 1: tintWeight = 0.25f; u.fresnelIntensity = 0.30f; break;
        case 2: tintWeight = 0.50f; u.fresnelIntensity = 0.55f; break;
        case 3:
        default:tintWeight = 0.80f; u.fresnelIntensity = 0.85f; break;
    }
    u.materialTint = simd_make_float4((float)r, (float)g, (float)b, tintWeight);

    memcpy(_uniformsBuffer.contents, &u, sizeof(u));
}

#pragma mark - Capture

// Drop the LiquidGlassKit captureBackdrop() path almost verbatim:
// drawHierarchy of the backdrop view into a CGContext owned by the
// zero-copy bridge. drawHierarchy includes hardware-composited layers
// (the wallpaper) which renderInContext: doesn't see.
- (id<MTLTexture>)captureBackdropTexture {
    if (!self.window) return nil;
    if (self.bounds.size.width < 4 || self.bounds.size.height < 4) return nil;

    CGFloat scale = ([UIScreen mainScreen].scale) * 0.5;
    LFLGBackdropView *bd = _backdropView;
    return [_zeroCopy renderActions:^(CGContextRef ctx) {
        CGContextScaleCTM(ctx, scale, scale);
        UIGraphicsPushContext(ctx);
        [bd drawViewHierarchyInRect:bd.bounds afterScreenUpdates:NO];
        UIGraphicsPopContext();
    }];
}

- (void)blurInPlace:(id<MTLTexture> _Nonnull __strong *)tex {
    if (!*tex || !_blur) return;
    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    if (!cmd) return;
    // Sigma is a function of contentsScale and the .regular preset's
    // backgroundTextureBlurRadius (0.3). On 6s with @2x scale that's
    // sigma = 0.6 -- subtle softening of the dispersion fringes.
    [_blur encodeToCommandBuffer:cmd inPlaceTexture:tex fallbackCopyAllocator:nil];
    [cmd commit];
    [cmd waitUntilCompleted];
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self updateUniformsCPUSide];
}

- (void)drawInMTKView:(MTKView *)view {
    if (_intensity == 0) return;

    id<MTLTexture> bg = [self captureBackdropTexture];
    if (bg) {
        [self blurInPlace:&bg];
        _backgroundTexture = bg;
    }
    if (!_backgroundTexture) return;

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) return;
    id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
    if (!cmd) return;
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:_pipeline];
    [enc setFragmentBuffer:_uniformsBuffer offset:0 atIndex:0];
    [enc setFragmentTexture:_backgroundTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4];
    [enc endEncoding];
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (drawable) [cmd presentDrawable:drawable];
    [cmd commit];
}

@end
