#import "PPDetailViewController.h"
#import "PPWallpaperLibrary.h"
#import "PPApplyBridge.h"
#import "PPPreviewRenderer.h"

@interface PPDetailViewController ()
@property (nonatomic, strong) PPWallpaperItem *item;
@property (nonatomic, weak)   UIImageView     *iv;
@end

@implementation PPDetailViewController

- (instancetype)initWithItem:(PPWallpaperItem *)item {
    if ((self = [super init])) {
        _item = item;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = self.item.displayName;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                             target:self
                             action:@selector(tapDelete:)];

    UIImageView *iv = [UIImageView new];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.backgroundColor = [UIColor secondarySystemBackgroundColor];
    iv.layer.cornerRadius = 16;
    iv.layer.masksToBounds = YES;
    iv.image = [[NSFileManager defaultManager]
                fileExistsAtPath:self.item.previewPath]
                    ? [UIImage imageWithContentsOfFile:self.item.previewPath]
                    : nil;
    [self.view addSubview:iv];
    self.iv = iv;

    // No preview yet? Render one lazily and swap it in when ready.
    if (!iv.image) {
        NSString *bundle = self.item.bundlePath;
        NSString *out    = self.item.previewPath;
        __weak typeof(self) wself = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [PPPreviewRenderer renderPreviewForBundle:bundle
                                                 size:CGSizeMake(720, 1280)
                                              outPath:out
                                                error:NULL];
            UIImage *img = [UIImage imageWithContentsOfFile:out];
            dispatch_async(dispatch_get_main_queue(), ^{
                wself.iv.image = img;
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"PPWallpaperPreviewDidUpdate"
                                  object:nil];
            });
        });
    }

    UILabel *path = [UILabel new];
    path.translatesAutoresizingMaskIntoConstraints = NO;
    path.text = self.item.bundlePath;
    path.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    path.textColor = [UIColor secondaryLabelColor];
    path.numberOfLines = 0;
    path.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:path];

    // Two buttons stacked vertically: Apply (primary), Respring (secondary).
    // Apply ONLY copies the bundle into PosterPlayer's active slot;
    // Respring is a separate, explicit action so users on fragile
    // jailbreaks (where respring sometimes drops the JB) can decide
    // when SpringBoard restarts.
    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.translatesAutoresizingMaskIntoConstraints = NO;
    [apply setTitle:@"Apply" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    apply.tintColor = [UIColor whiteColor];
    apply.backgroundColor = [UIColor systemBlueColor];
    apply.layer.cornerRadius = 14;
    [apply addTarget:self action:@selector(tapApply:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:apply];

    UIButton *respring = [UIButton buttonWithType:UIButtonTypeSystem];
    respring.translatesAutoresizingMaskIntoConstraints = NO;
    [respring setTitle:@"Respring" forState:UIControlStateNormal];
    respring.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    respring.tintColor = [UIColor labelColor];
    respring.backgroundColor = [UIColor secondarySystemBackgroundColor];
    respring.layer.cornerRadius = 14;
    [respring addTarget:self action:@selector(tapRespring:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:respring];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [iv.topAnchor      constraintEqualToAnchor:safe.topAnchor constant:16],
        [iv.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [iv.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [iv.heightAnchor   constraintEqualToAnchor:iv.widthAnchor multiplier:16.0/9.0],

        [path.topAnchor      constraintEqualToAnchor:iv.bottomAnchor constant:16],
        [path.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [path.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [respring.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [respring.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [respring.bottomAnchor   constraintEqualToAnchor:safe.bottomAnchor constant:-24],
        [respring.heightAnchor   constraintEqualToConstant:44],

        [apply.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [apply.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [apply.bottomAnchor   constraintEqualToAnchor:respring.topAnchor constant:-12],
        [apply.heightAnchor   constraintEqualToConstant:50],
    ]];
}

- (void)tapApply:(id)sender {
    NSError *err = nil;
    BOOL ok = [PPApplyBridge applyItem:self.item error:&err];
    if (!ok) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"Apply failed"
                             message:err.localizedDescription ?: @"Unknown error"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    // Bundle is staged. Offer the user a respring (which actually
    // applies the wallpaper system-wide) but never force one.
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Wallpaper staged"
                         message:@"PocketPlayer copied the bundle into the active slot.\n\n"
                                 @"Tap Respring to apply it on the lockscreen, behind the lock UI, "
                                 @"and on the home screen. Or wait — it'll take effect on the next "
                                 @"natural reboot too.\n\n"
                                 @"If your jailbreak is fragile after respring, plug in your charger first."
                  preferredStyle:UIAlertControllerStyleAlert];

    [a addAction:[UIAlertAction actionWithTitle:@"Later"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];

    [a addAction:[UIAlertAction actionWithTitle:@"Respring now"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
        [PPApplyBridge respring];
    }]];

    [self presentViewController:a animated:YES completion:nil];
}

- (void)tapRespring:(id)sender {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Respring SpringBoard?"
                         message:@"Closes all foreground apps for ~3 seconds while SpringBoard restarts. "
                                 @"Required to fully apply a freshly staged wallpaper."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Respring"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
        [PPApplyBridge respring];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)tapDelete:(id)sender {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Delete wallpaper?"
                         message:self.item.displayName
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    __weak typeof(self) wself = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Delete"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *_) {
        [[PPWallpaperLibrary shared] deleteItem:wself.item error:NULL];
        [wself.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
