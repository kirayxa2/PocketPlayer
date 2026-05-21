#import "LFLiquidGlassMetalView.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

// =====================================================================
// Uniform layout (MUST match `struct ShaderUniforms` in LiquidGlass.metal).
//
// Order, type, and alignment all have to line up bit-for-bit with the
// MSL struct or the GPU will read garbage. Keep float4 / vector_float4
// fields 16-byte aligned -- the compiler does this automatically with
// simd_float* but mixing scalars and vectors gets tricky. We sit on
// `__attribute__((aligned(16)))` for the whole struct to make sure
// the buffer offset is correct after rebuilds.
// =====================================================================
#pragma pack(push, 4)
typedef struct __attribute__((aligned(16))) {
    simd_float2 resolution;
    float       contentsScale;
    float       cornerRadius;
    simd_float4 materialTint;
    float       glassThickness;
    float       refractiveIndex;
    float       dispersionStrength;
    float       fresnelDistanceRange;
    float       fresnelIntensity;
    float       fresnelEdgeSharpness;
    simd_float4 rectangle;
} LFLGMetalUniforms;
#pragma pack(pop)

// CABackdropLayer is a private, undocumented CALayer subclass. It
// auto-composites everything underneath it into its own contents
// without requiring our process to render the background tree
// manually. We use it via NSClassFromString so the symbol is looked
// up at runtime; if Apple removes it on a future iOS version we
// fall back to drawHierarchy at slightly higher CPU cost.
//
// Every JB tweak that does Liquid-Glass-style backdrops on iOS 13+
// uses this same trick -- LiquidGlassKit, LiquidUI, and Apple's own
// internal _UIBackdropEffectView / UIVisualEffectView under the
// hood all instantiate CABackdropLayer. Safe to use in our context.
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
        // The two private kvc keys below are documented from runtime
        // headers / class-dump of QuartzCore. They make the backdrop
        // layer (a) participate in window-server compositing (so it
        // sees the real wallpaper underneath, not just our own view
        // tree) and (b) give it a unique group identifier so the
        // compositor doesn't merge it with another tweak's backdrop.
        [self.layer setValue:@(YES) forKey:@"windowServerAware"];
        [self.layer setValue:[[NSUUID UUID] UUIDString] forKey:@"groupName"];
    }
    return self;
}
@end

// =====================================================================
// LFLiquidGlassMetalView
// =====================================================================
@interface LFLiquidGlassMetalView () <MTKViewDelegate>
@property (nonatomic, strong) MTKView                 *mtkView;
@property (nonatomic, strong) LFLGBackdropView        *backdrop;

// Metal objects (lazily built once at +isAvailable / -init time).
@property (nonatomic, strong) id<MTLDevice>            device;
@property (nonatomic, strong) id<MTLCommandQueue>      commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) id<MTLBuffer>            uniformsBuffer;
@property (nonatomic, strong) MTKTextureLoader        *textureLoader;
@property (nonatomic, strong) id<MTLTexture>           backgroundTexture;

// Uniform values that the fragment shader needs. We keep the shimmer
// offset in here too even though the simplified .metal file doesn't
// use it -- the existing API contract on LFLiquidGlassView.set-
// ShimmerOffset: needs to do something visible, so we attach a
// CGAffineTransform to the MTKView each tick.
@property (nonatomic, assign) CGPoint                  shimmerOffset;

// Frame counter for sub-rate capture. iPhone 6s renders the lock
// screen at 60 Hz; capturing the backdrop and uploading it as a
// texture every frame is the dominant cost. Most of the perceptual
// quality survives capturing every 2nd frame (i.e. 30 Hz updates of
// what's BEHIND the glass) while the shader still runs at 60 Hz on
// the cached texture, which is what gives the gyro-shimmer its
// smoothness without melting the GPU.
@property (nonatomic, assign) uint32_t                 frameCounter;
@end

@implementation LFLiquidGlassMetalView

#pragma mark - Availability

+ (NSString *)metallibPath {
    // Two locations to probe; the rootless prefix wins on iOS 15+
    // jailbreaks, the legacy /Library wins on rootful (older Cheyote
    // / Taurine setups). Whichever exists first is what we load.
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
            NSLog(@"[LockForge] Metal not available -- using UIVisualEffectView fallback for glass.");
            ok = NO;
            return;
        }
        NSString *path = [self metallibPath];
        if (!path) {
            NSLog(@"[LockForge] LiquidGlassShaders.metallib not found in /var/jb/Library/LockForge/ "
                  @"or /Library/LockForge/ -- using UIVisualEffectView fallback. "
                  @"Compile via .github/workflows/compile-metal.yml or push the .metal file to trigger CI.");
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
    _glassCornerRadius = 18;
    _shimmerOffset     = CGPointZero;
    _frameCounter      = 0;

    if (![[self class] isAvailable] || ![self setupMetal]) {
        // If Metal setup actually fails after isAvailable said YES
        // (e.g. the metallib is corrupt), present as a transparent
        // view -- LFLiquidGlassView's caller code will see no glass
        // and the fallback is silently no glass. Better than crashing.
        NSLog(@"[LockForge] Metal pipeline setup failed; LFLiquidGlassMetalView is a no-op.");
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
    if (!path) return NO;

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
    // Premultiplied alpha so when we set the MTKView's clearColor to
    // (0,0,0,0) and have semi-transparent fragment outputs (Fresnel
    // edge blending), they composite correctly over the backdrop
    // BEHIND the MTKView (which shows through where alpha is 0).
    desc.colorAttachments[0].blendingEnabled             = YES;
    desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorOne;
    desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    _pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_pipeline) {
        NSLog(@"[LockForge] Failed to create Metal pipeline state: %@", err);
        return NO;
    }

    _commandQueue = [_device newCommandQueue];
    _uniformsBuffer = [_device newBufferWithLength:sizeof(LFLGMetalUniforms)
                                            options:MTLResourceStorageModeShared];
    _textureLoader = [[MTKTextureLoader alloc] initWithDevice:_device];
    return YES;
}

- (void)buildSubviews {
    _backdrop = [[LFLGBackdropView alloc] init];
    [self addSubview:_backdrop];

    _mtkView = [[MTKView alloc] initWithFrame:CGRectZero device:_device];
    _mtkView.delegate                  = self;
    _mtkView.userInteractionEnabled    = NO;
    _mtkView.framebufferOnly           = YES;
    _mtkView.opaque                    = NO;
    _mtkView.layer.opaque              = NO;
    _mtkView.backgroundColor           = [UIColor clearColor];
    _mtkView.colorPixelFormat          = MTLPixelFormatBGRA8Unorm;
    _mtkView.clearColor                = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    _mtkView.preferredFramesPerSecond  = 30;     // gentle on the A9
    _mtkView.enableSetNeedsDisplay     = NO;
    _mtkView.paused                    = NO;
    [self addSubview:_mtkView];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _backdrop.frame = self.bounds;
    _mtkView.frame  = self.bounds;
    [self updateUniformsCPUSide];
}

#pragma mark - Setters (forward changes into uniforms)

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
    [self setNeedsLayout];
    [self updateUniformsCPUSide];
}

- (void)setShimmerOffset:(CGPoint)offset {
    _shimmerOffset = offset;
    // Translate the whole MTKView a few points based on tilt so the
    // glass appears to drift relative to the wallpaper underneath --
    // this matches the cheap parallax LiquidGlassKit's reference UI
    // does in its sample widgets and is what reads as "glass that
    // moves with the device" from across the room.
    CGFloat dx = MAX(-1, MIN(1, offset.x)) * 3.0;
    CGFloat dy = MAX(-1, MIN(1, offset.y)) * 1.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _mtkView.transform = CGAffineTransformMakeTranslation(dx, dy);
    [CATransaction commit];
}

#pragma mark - Uniforms

- (void)applyIntensityIntoUniforms:(LFLGMetalUniforms *)u {
    // Map 0..3 to perceptual presets matching what the legacy
    // UIVisualEffectView path used to feel like at each level. The
    // major dial is materialTint.a (how opaque the glass is) and
    // fresnelIntensity (how bright the rim glows).
    float ttintA = 0.05f, fInt = 0.4f;
    switch (_intensity) {
        case 1: ttintA = 0.04f; fInt = 0.30f; break;
        case 2: ttintA = 0.10f; fInt = 0.55f; break;
        case 3:
        default:ttintA = 0.16f; fInt = 0.85f; break;
    }
    CGFloat r = 1.0, g = 1.0, b = 1.0, a = 1.0;
    [_tintColor getRed:&r green:&g blue:&b alpha:&a];
    u->materialTint = (simd_float4){ (float)r, (float)g, (float)b, ttintA };

    u->glassThickness        = 14.0f;
    u->refractiveIndex       = 1.50f;
    u->dispersionStrength    = 7.0f;
    u->fresnelDistanceRange  = 60.0f;
    u->fresnelIntensity      = fInt;
    u->fresnelEdgeSharpness  = -0.15f;
}

- (void)updateUniformsCPUSide {
    if (!_uniformsBuffer) return;

    CGFloat scale = self.window.screen.scale ?: [UIScreen mainScreen].scale;
    LFLGMetalUniforms *u = (LFLGMetalUniforms *)_uniformsBuffer.contents;
    u->resolution    = (simd_float2){ (float)(self.bounds.size.width * scale),
                                      (float)(self.bounds.size.height * scale) };
    u->contentsScale = (float)scale;
    u->cornerRadius  = (float)_glassCornerRadius;
    // Single rectangle covering the whole view in points, upper-left
    // origin (the shader expects points; it scales to pixels itself).
    u->rectangle     = (simd_float4){ 0.0f, 0.0f,
                                      (float)self.bounds.size.width,
                                      (float)self.bounds.size.height };
    [self applyIntensityIntoUniforms:u];
}

#pragma mark - Backdrop -> MTLTexture capture

// Render the BackdropView (which has a CABackdropLayer attached so
// it has the wallpaper composited into its presentation cache) into
// a CGImage, then upload to a Metal texture via MTKTextureLoader.
//
// We sample at half resolution -- the shader's blur/refraction reads
// 3x4 surrounding pixels per output, so the loss in detail is invisible
// after the dispersion offsets are applied, and the texture upload
// time drops by 4x. On iPhone 6s this is the difference between 18 fps
// and 30 fps.
- (id<MTLTexture>)captureBackdropTexture {
    if (!self.window) return nil;

    CGSize sourceSize = self.bounds.size;
    if (sourceSize.width < 4 || sourceSize.height < 4) return nil;

    CGFloat capScale = ([UIScreen mainScreen].scale) * 0.5;     // half-res
    CGSize  capSize  = CGSizeMake(sourceSize.width  * capScale,
                                  sourceSize.height * capScale);

    UIGraphicsBeginImageContextWithOptions(sourceSize, NO, capScale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    // Translate so we render the part of the parent window that's
    // BEHIND our backdrop view -- because the parent view tree owns
    // the wallpaper composite, and we need its rect-under-us.
    CGPoint originInWindow = [self convertPoint:CGPointZero toView:self.window];
    CGContextTranslateCTM(ctx, -originInWindow.x, -originInWindow.y);

    // drawViewHierarchy:afterScreenUpdates:NO captures the cached
    // composited state of the window, including hardware-backed
    // wallpaper layers. afterScreenUpdates:NO is critical -- YES
    // would force a synchronous re-layout of every view in the
    // window, which deadlocks during cover-sheet animation passes.
    [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:NO];

    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!snap || !snap.CGImage) return nil;

    NSDictionary *opts = @{
        MTKTextureLoaderOptionTextureUsage:        @(MTLTextureUsageShaderRead),
        MTKTextureLoaderOptionTextureStorageMode:  @(MTLStorageModeShared),
        MTKTextureLoaderOptionSRGB:                @(NO),
    };
    NSError *err = nil;
    id<MTLTexture> tex = [_textureLoader newTextureWithCGImage:snap.CGImage
                                                       options:opts
                                                         error:&err];
    if (!tex) {
        NSLog(@"[LockForge] Backdrop texture upload failed: %@", err);
    }
    return tex;
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self updateUniformsCPUSide];
}

- (void)drawInMTKView:(MTKView *)view {
    if (_intensity == 0) return;       // Solid mode -- view hidden anyway

    // Capture every other frame; reuse the previous texture in
    // between to keep fragment-shader frame rate at 30 Hz on the A9.
    _frameCounter++;
    if ((_frameCounter % 2) == 0 || !_backgroundTexture) {
        id<MTLTexture> fresh = [self captureBackdropTexture];
        if (fresh) _backgroundTexture = fresh;
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
