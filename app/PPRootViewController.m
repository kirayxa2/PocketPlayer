#import "PPRootViewController.h"
#import "PPWallpaperLibrary.h"
#import "PPApplyBridge.h"
#import "PPDetailViewController.h"
#import "PPImportProgressViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kCellID = @"WPCell";

// =====================================================================
// Library tile cell — same visual language as the Browse tab so the
// two grids feel coherent. Aspect 9:16 (wallpaper-shaped), title on a
// dark gradient at the bottom.
// =====================================================================

@interface PPLibraryTileCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *coverImage;
@property (nonatomic, strong) UIView      *skeleton;
@property (nonatomic, strong) UILabel     *titleLabel;
@property (nonatomic, strong) UIView      *gradientOverlay;
@end

@implementation PPLibraryTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.layer.cornerRadius = 14;
        self.contentView.layer.masksToBounds = YES;
        self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];

        self.layer.shadowColor   = [UIColor.blackColor CGColor];
        self.layer.shadowOpacity = 0.10;
        self.layer.shadowOffset  = CGSizeMake(0, 4);
        self.layer.shadowRadius  = 10;
        self.layer.masksToBounds = NO;

        _coverImage = [UIImageView new];
        _coverImage.translatesAutoresizingMaskIntoConstraints = NO;
        _coverImage.contentMode = UIViewContentModeScaleAspectFill;
        _coverImage.clipsToBounds = YES;
        [self.contentView addSubview:_coverImage];

        _skeleton = [UIView new];
        _skeleton.translatesAutoresizingMaskIntoConstraints = NO;
        _skeleton.backgroundColor = [UIColor tertiarySystemFillColor];
        [self.contentView addSubview:_skeleton];

        _gradientOverlay = [UIView new];
        _gradientOverlay.translatesAutoresizingMaskIntoConstraints = NO;
        _gradientOverlay.userInteractionEnabled = NO;
        [self.contentView addSubview:_gradientOverlay];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.layer.shadowColor   = [UIColor.blackColor CGColor];
        _titleLabel.layer.shadowOpacity = 0.6;
        _titleLabel.layer.shadowOffset  = CGSizeMake(0, 1);
        _titleLabel.layer.shadowRadius  = 2;
        [self.contentView addSubview:_titleLabel];

        UIView *cv = self.contentView;
        [NSLayoutConstraint activateConstraints:@[
            [_coverImage.topAnchor      constraintEqualToAnchor:cv.topAnchor],
            [_coverImage.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor],
            [_coverImage.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
            [_coverImage.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor],

            [_skeleton.topAnchor        constraintEqualToAnchor:cv.topAnchor],
            [_skeleton.leadingAnchor    constraintEqualToAnchor:cv.leadingAnchor],
            [_skeleton.trailingAnchor   constraintEqualToAnchor:cv.trailingAnchor],
            [_skeleton.bottomAnchor     constraintEqualToAnchor:cv.bottomAnchor],

            [_gradientOverlay.leadingAnchor  constraintEqualToAnchor:cv.leadingAnchor],
            [_gradientOverlay.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
            [_gradientOverlay.bottomAnchor   constraintEqualToAnchor:cv.bottomAnchor],
            [_gradientOverlay.heightAnchor   constraintEqualToAnchor:cv.heightAnchor multiplier:0.45],

            [_titleLabel.leadingAnchor   constraintEqualToAnchor:cv.leadingAnchor constant:10],
            [_titleLabel.trailingAnchor  constraintEqualToAnchor:cv.trailingAnchor constant:-10],
            [_titleLabel.bottomAnchor    constraintEqualToAnchor:cv.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *l in [self.gradientOverlay.layer.sublayers copy]) [l removeFromSuperlayer];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[ (id)[[UIColor.blackColor colorWithAlphaComponent:0.0] CGColor],
                  (id)[[UIColor.blackColor colorWithAlphaComponent:0.55] CGColor],
                  (id)[[UIColor.blackColor colorWithAlphaComponent:0.85] CGColor] ];
    g.locations = @[ @0.0, @0.5, @1.0 ];
    g.frame = self.gradientOverlay.bounds;
    [self.gradientOverlay.layer addSublayer:g];

    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:14].CGPath;
}

- (void)configureWithItem:(PPWallpaperItem *)it {
    self.titleLabel.text = it.displayName;
    UIImage *preview = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:it.previewPath]) {
        preview = [UIImage imageWithContentsOfFile:it.previewPath];
    }
    self.coverImage.image = preview;
    self.skeleton.hidden = (preview != nil);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.coverImage.image = nil;
    self.skeleton.hidden = NO;
}

@end

// =====================================================================
// Root VC
// =====================================================================

@interface PPRootViewController () <
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UIDocumentPickerDelegate>

@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UIView           *emptyView;
@property (nonatomic, strong) UILabel          *emptyTitle;
@property (nonatomic, strong) UILabel          *emptySubtitle;
@property (nonatomic, strong) UIButton         *emptyAddButton;
@end

@implementation PPRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Library";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(tapImport:)];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing      = 14;
    layout.sectionInset            = UIEdgeInsetsMake(8, 14, 14, 14);

    self.grid = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                   collectionViewLayout:layout];
    self.grid.translatesAutoresizingMaskIntoConstraints = NO;
    self.grid.backgroundColor = [UIColor systemBackgroundColor];
    self.grid.dataSource = self;
    self.grid.delegate   = self;
    self.grid.alwaysBounceVertical = YES;
    [self.grid registerClass:[PPLibraryTileCell class]
  forCellWithReuseIdentifier:kCellID];
    [self.view addSubview:self.grid];

    [self buildEmptyView];

    [NSLayoutConstraint activateConstraints:@[
        [self.grid.topAnchor      constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.grid.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
        [self.grid.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.emptyView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyView.widthAnchor   constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                                constant:-40],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(previewDidUpdate:)
                                                 name:@"PPWallpaperPreviewDidUpdate"
                                               object:nil];
}

- (void)buildEmptyView {
    self.emptyView = [UIView new];
    self.emptyView.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [UIImageView new];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:48 weight:UIImageSymbolWeightLight];
        icon.image = [UIImage systemImageNamed:@"photo.on.rectangle.angled"
                              withConfiguration:cfg];
    }
    icon.tintColor = [UIColor tertiaryLabelColor];

    self.emptyTitle = [UILabel new];
    self.emptyTitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyTitle.text = @"No wallpapers yet";
    self.emptyTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    self.emptyTitle.textColor = [UIColor labelColor];
    self.emptyTitle.textAlignment = NSTextAlignmentCenter;

    self.emptySubtitle = [UILabel new];
    self.emptySubtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptySubtitle.text = @"Import a .tendies file or grab one from the Browse tab.";
    self.emptySubtitle.font = [UIFont systemFontOfSize:15];
    self.emptySubtitle.textColor = [UIColor secondaryLabelColor];
    self.emptySubtitle.textAlignment = NSTextAlignmentCenter;
    self.emptySubtitle.numberOfLines = 0;

    self.emptyAddButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.emptyAddButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyAddButton setTitle:@"Import .tendies"
                         forState:UIControlStateNormal];
    [self.emptyAddButton.titleLabel setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]];
    self.emptyAddButton.backgroundColor = [UIColor labelColor];
    [self.emptyAddButton setTitleColor:[UIColor systemBackgroundColor]
                              forState:UIControlStateNormal];
    self.emptyAddButton.contentEdgeInsets = UIEdgeInsetsMake(12, 24, 12, 24);
    self.emptyAddButton.layer.cornerRadius = 12;
    [self.emptyAddButton addTarget:self action:@selector(tapImport:)
                  forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon, self.emptyTitle, self.emptySubtitle, self.emptyAddButton
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    [stack setCustomSpacing:6 afterView:self.emptyTitle];
    [stack setCustomSpacing:24 afterView:self.emptySubtitle];

    [self.emptyView addSubview:stack];
    [self.view addSubview:self.emptyView];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor      constraintEqualToAnchor:self.emptyView.topAnchor],
        [stack.leadingAnchor  constraintEqualToAnchor:self.emptyView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.emptyView.trailingAnchor],
        [stack.bottomAnchor   constraintEqualToAnchor:self.emptyView.bottomAnchor],
    ]];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)previewDidUpdate:(NSNotification *)note {
    [self.grid reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[PPWallpaperLibrary shared] reload];
    [self refreshEmptyState];
    [self updateCountInTitle];
    [self.grid reloadData];
}

- (void)refreshEmptyState {
    BOOL empty = [PPWallpaperLibrary shared].items.count == 0;
    self.emptyView.hidden = !empty;
    self.grid.hidden      = empty;
}

- (void)updateCountInTitle {
    NSInteger n = [PPWallpaperLibrary shared].items.count;
    if (n == 0) {
        self.title = @"Library";
    } else if (n == 1) {
        self.title = @"1 wallpaper";
    } else {
        self.title = [NSString stringWithFormat:@"%ld wallpapers", (long)n];
    }
}

#pragma mark Import

- (void)tapImport:(id)sender {
    NSArray *types = @[];
    if (@available(iOS 14.0, *)) {
        UTType *tendies = [UTType typeWithIdentifier:@"com.vortex.tendies"];
        UTType *zip     = [UTType typeWithIdentifier:@"public.zip-archive"];
        types = tendies ? @[tendies, zip] : @[zip];
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:types asCopy:YES];
        p.delegate = self;
        p.allowsMultipleSelection = NO;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.zip-archive"] inMode:UIDocumentPickerModeImport];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
         didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url) [self importTendiesAtURL:url];
}

- (void)importTendiesAtURL:(NSURL *)url {
    PPImportProgressViewController *progress = [PPImportProgressViewController new];
    __weak typeof(self) weakSelf = self;
    progress.completion = ^{
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        [self_ refreshEmptyState];
        [self_ updateCountInTitle];
        [self_.grid reloadData];
    };
    // Local imports get the same Apply-now button experience as Browse.
    progress.applyHandler = ^{
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        // The most-recently-imported item is items.firstObject (sorted
        // newest-first by the library).
        PPWallpaperItem *latest = [PPWallpaperLibrary shared].items.firstObject;
        if (!latest) {
            [progress dismissAfterApplying];
            return;
        }
        NSError *err = nil;
        if (![PPApplyBridge applyItem:latest error:&err]) {
            [progress dismissAfterApplying];
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Apply failed"
                                 message:err.localizedDescription ?: @"Unknown error"
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
            [self_ presentViewController:a animated:YES completion:nil];
            return;
        }
        [progress dismissAfterApplying];
    };
    [self presentViewController:progress animated:YES completion:^{
        [self runImportPipelineForURL:url progress:progress];
    }];
}

- (void)runImportPipelineForURL:(NSURL *)url
                       progress:(PPImportProgressViewController *)progress {
    CGSize targetSize = [UIScreen mainScreen].bounds.size;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e1 = nil;
        PPWallpaperItem *it = [[PPWallpaperLibrary shared]
            beginImportTendiesAtURL:url error:&e1];
        if (!it) {
            [progress failWithMessage:@"Import failed"];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *msg = e1.localizedDescription ?: @"Unknown error";
                UIAlertController *a = [UIAlertController
                    alertControllerWithTitle:@"Import failed"
                                     message:msg
                              preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            });
            return;
        }
        [progress finishCurrentStage]; // Importing -> Resizing

        NSError *e2 = nil;
        BOOL ok2 = [[PPWallpaperLibrary shared] resizeItem:it
                                                    toSize:targetSize
                                                     error:&e2];
        if (!ok2) {
            NSLog(@"[PocketPoster] resize warning: %@",
                  e2.localizedDescription ?: @"unknown");
        }

        [progress finishCurrentStage]; // Resizing -> Done
        [progress finishCurrentStage]; // Done -> reveal Apply button
    });
}

#pragma mark Grid

- (NSInteger)collectionView:(UICollectionView *)cv
       numberOfItemsInSection:(NSInteger)section {
    return [PPWallpaperLibrary shared].items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    PPLibraryTileCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kCellID
                                                            forIndexPath:ip];
    PPWallpaperItem *it = [PPWallpaperLibrary shared].items[ip.item];
    [cell configureWithItem:it];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    BOOL pad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    int columns = pad ? 3 : 2;
    CGFloat spacing = 12;
    CGFloat side = (cv.bounds.size.width - 14 * 2 - spacing * (columns - 1)) / columns;
    return CGSizeMake(floor(side), floor(side * 16.0 / 9.0));
}

- (void)collectionView:(UICollectionView *)cv
    didSelectItemAtIndexPath:(NSIndexPath *)ip {
    PPWallpaperItem *it = [PPWallpaperLibrary shared].items[ip.item];
    PPDetailViewController *d = [[PPDetailViewController alloc] initWithItem:it];
    [self.navigationController pushViewController:d animated:YES];
}

@end
