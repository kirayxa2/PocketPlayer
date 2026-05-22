#import "LFLockScreenWallpaperView.h"
#import "LFLockScreenLibrary.h"

@interface LFLockScreenWallpaperView ()
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, copy)   NSString    *currentlyDisplayedPath;
@end

@implementation LFLockScreenWallpaperView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;     // pure visual layer
    self.backgroundColor        = [UIColor clearColor];
    self.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;

    _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
    _imageView.autoresizingMask = self.autoresizingMask;
    _imageView.contentMode      = UIViewContentModeScaleAspectFill;
    _imageView.clipsToBounds    = YES;
    [self addSubview:_imageView];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(refresh)
               name:LFActiveLockScreenChangedNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(refresh)
               name:LFLockScreenLibraryChangedNotification
             object:nil];

    [self refresh];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refresh {
    LFLockScreenLibrary *lib = [LFLockScreenLibrary shared];
    NSString *path = [lib wallpaperPathForId:lib.activeId];

    if (!path) {
        // No custom wallpaper for this lock screen -- hide so the
        // system wallpaper shows through. The system path is always
        // a valid fallback (it's whatever the user picked in
        // Settings > Wallpaper before installing LockForge).
        self.hidden                  = YES;
        _imageView.image             = nil;
        _currentlyDisplayedPath      = nil;
        return;
    }

    self.hidden = NO;
    if (![path isEqualToString:_currentlyDisplayedPath]) {
        // Decode off the main thread to avoid a hitch when switching
        // active screens. UIImage's JPEG decoder is fast on A9 (~30ms
        // for a 1334x750 image) but still worth keeping off main.
        NSString *capture = [path copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = [UIImage imageWithContentsOfFile:capture];
            dispatch_async(dispatch_get_main_queue(), ^{
                // Guard against another switch having happened while
                // we were decoding -- only apply if we're still the
                // path the active screen wants.
                LFLockScreenLibrary *now = [LFLockScreenLibrary shared];
                NSString *latest = [now wallpaperPathForId:now.activeId];
                if (![latest isEqualToString:capture]) return;
                _imageView.image          = img;
                _currentlyDisplayedPath   = capture;
            });
        });
    }
}

@end
