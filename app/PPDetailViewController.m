#import "PPDetailViewController.h"
#import "PPWallpaperLibrary.h"
#import "PPApplyBridge.h"

@interface PPDetailViewController ()
@property (nonatomic, strong) PPWallpaperItem *item;
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

    UILabel *path = [UILabel new];
    path.translatesAutoresizingMaskIntoConstraints = NO;
    path.text = self.item.bundlePath;
    path.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    path.textColor = [UIColor secondaryLabelColor];
    path.numberOfLines = 0;
    path.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:path];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.translatesAutoresizingMaskIntoConstraints = NO;
    [apply setTitle:@"Apply" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    apply.tintColor = [UIColor whiteColor];
    apply.backgroundColor = [UIColor systemBlueColor];
    apply.layer.cornerRadius = 14;
    [apply addTarget:self action:@selector(tapApply:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:apply];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [iv.topAnchor      constraintEqualToAnchor:safe.topAnchor constant:16],
        [iv.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [iv.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [iv.heightAnchor   constraintEqualToAnchor:iv.widthAnchor multiplier:16.0/9.0],

        [path.topAnchor      constraintEqualToAnchor:iv.bottomAnchor constant:16],
        [path.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [path.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [apply.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [apply.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [apply.bottomAnchor   constraintEqualToAnchor:safe.bottomAnchor constant:-24],
        [apply.heightAnchor   constraintEqualToConstant:50],
    ]];
}

- (void)tapApply:(id)sender {
    NSError *err = nil;
    BOOL ok = [PPApplyBridge applyItem:self.item error:&err];
    NSString *title = ok ? @"Sent" : @"Apply failed";
    NSString *msg   = ok
        ? @"PocketPoster posted the apply request. The tweak side of the bridge "
          @"will pick it up — once that lands a respring won't be needed."
        : (err.localizedDescription ?: @"Unknown error");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
