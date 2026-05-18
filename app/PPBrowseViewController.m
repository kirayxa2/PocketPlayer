#import "PPBrowseViewController.h"
#import "PPCatalogService.h"
#import "PPCatalogItem.h"
#import "PPWallpaperLibrary.h"
#import "PPApplyBridge.h"
#import "PPImportProgressViewController.h"
#import <objc/runtime.h>

static NSString *const kCellID = @"BR";

// =====================================================================
// Tile cell
// =====================================================================

@interface PPBrowseTileCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *coverImage;
@property (nonatomic, strong) UIView      *skeleton;
@property (nonatomic, strong) UILabel     *titleLabel;
@property (nonatomic, strong) UILabel     *categoryLabel;
@property (nonatomic, strong) UIView      *gradientOverlay;
@property (nonatomic, copy)   NSString    *currentURL;
@end

@implementation PPBrowseTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.contentView.layer.cornerRadius = 14;
        self.contentView.layer.masksToBounds = YES;
        self.contentView.backgroundColor = [UIColor secondarySystemBackgroundColor];

        // Subtle elevation. Apple's photo grid look.
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

        // Skeleton (shown until the cover image loads).
        _skeleton = [UIView new];
        _skeleton.translatesAutoresizingMaskIntoConstraints = NO;
        _skeleton.backgroundColor = [UIColor tertiarySystemFillColor];
        [self.contentView addSubview:_skeleton];

        _gradientOverlay = [UIView new];
        _gradientOverlay.translatesAutoresizingMaskIntoConstraints = NO;
        _gradientOverlay.userInteractionEnabled = NO;
        // Add the gradient via a CAGradientLayer in -layoutSubviews.
        [self.contentView addSubview:_gradientOverlay];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        // Slight text shadow so the name is readable even on bright covers.
        _titleLabel.layer.shadowColor   = [UIColor.blackColor CGColor];
        _titleLabel.layer.shadowOpacity = 0.6;
        _titleLabel.layer.shadowOffset  = CGSizeMake(0, 1);
        _titleLabel.layer.shadowRadius  = 2;
        [self.contentView addSubview:_titleLabel];

        _categoryLabel = [UILabel new];
        _categoryLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _categoryLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _categoryLabel.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.85];
        _categoryLabel.layer.shadowColor   = [UIColor.blackColor CGColor];
        _categoryLabel.layer.shadowOpacity = 0.5;
        _categoryLabel.layer.shadowOffset  = CGSizeMake(0, 1);
        _categoryLabel.layer.shadowRadius  = 2;
        [self.contentView addSubview:_categoryLabel];

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

            [_categoryLabel.leadingAnchor  constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_categoryLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_categoryLabel.bottomAnchor   constraintEqualToAnchor:_titleLabel.topAnchor constant:-2],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    // Re-add the gradient layer at the right size on each layout pass.
    for (CALayer *l in [self.gradientOverlay.layer.sublayers copy]) {
        [l removeFromSuperlayer];
    }
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

- (void)configureWithItem:(PPCatalogItem *)item {
    self.titleLabel.text = item.displayName;
    self.categoryLabel.text = [item.category uppercaseString];
    self.coverImage.image = nil;
    self.skeleton.hidden = NO;
    self.currentURL = item.previewURL;

    if (!item.previewURL.length) return;

    NSString *url = item.previewURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *d = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
        UIImage *img = d ? [UIImage imageWithData:d] : nil;
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Make sure the cell wasn't reused for a different tile in
            // the meantime -- compare against the URL we set above.
            if (![self.currentURL isEqualToString:url]) return;
            self.coverImage.image = img;
            self.skeleton.hidden = YES;
        });
    });
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.coverImage.image = nil;
    self.skeleton.hidden  = NO;
    self.currentURL = nil;
}

@end

// =====================================================================
// Category chip strip (horizontal scroll of pills)
// =====================================================================

@interface PPCategoryChipsView : UIView
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, copy) NSString             *selectedCategory;
@property (nonatomic, copy) void (^onSelect)(NSString *);
@end

@implementation PPCategoryChipsView {
    UIScrollView *_scroll;
    UIStackView  *_stack;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _scroll = [UIScrollView new];
        _scroll.translatesAutoresizingMaskIntoConstraints = NO;
        _scroll.showsHorizontalScrollIndicator = NO;
        _scroll.alwaysBounceHorizontal = YES;
        _scroll.contentInset = UIEdgeInsetsMake(0, 16, 0, 16);
        [self addSubview:_scroll];

        _stack = [UIStackView new];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.spacing = 8;
        _stack.alignment = UIStackViewAlignmentCenter;
        [_scroll addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_scroll.topAnchor      constraintEqualToAnchor:self.topAnchor],
            [_scroll.leadingAnchor  constraintEqualToAnchor:self.leadingAnchor],
            [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_scroll.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor],

            [_stack.topAnchor      constraintEqualToAnchor:_scroll.topAnchor],
            [_stack.leadingAnchor  constraintEqualToAnchor:_scroll.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
            [_stack.bottomAnchor   constraintEqualToAnchor:_scroll.bottomAnchor],
            [_stack.heightAnchor   constraintEqualToAnchor:_scroll.heightAnchor],
        ]];
    }
    return self;
}

- (void)setCategories:(NSArray<NSString *> *)cats {
    _categories = [cats copy];
    [self rebuild];
}

- (void)setSelectedCategory:(NSString *)c {
    _selectedCategory = [c copy];
    [self rebuild];
}

- (void)rebuild {
    for (UIView *v in [_stack.arrangedSubviews copy]) [v removeFromSuperview];
    for (NSString *cat in _categories) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:cat forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        btn.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
        btn.layer.cornerRadius = 16;
        BOOL selected = [cat isEqualToString:_selectedCategory];
        btn.backgroundColor = selected ? [UIColor labelColor]
                                       : [UIColor secondarySystemBackgroundColor];
        [btn setTitleColor:selected ? [UIColor systemBackgroundColor]
                                    : [UIColor labelColor]
                  forState:UIControlStateNormal];
        objc_setAssociatedObject(btn, "PPCat", cat, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [btn addTarget:self action:@selector(tapChip:)
            forControlEvents:UIControlEventTouchUpInside];
        [_stack addArrangedSubview:btn];
    }
}

- (void)tapChip:(UIButton *)btn {
    NSString *cat = objc_getAssociatedObject(btn, "PPCat");
    if (cat && self.onSelect) self.onSelect(cat);
}

@end

// =====================================================================
// Browse VC
// =====================================================================

@interface PPBrowseViewController () <
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout>

@property (nonatomic, strong) UIActivityIndicatorView *bigSpinner;
@property (nonatomic, strong) UILabel              *placeholder;
@property (nonatomic, strong) PPCategoryChipsView  *chips;
@property (nonatomic, strong) UICollectionView     *grid;
@property (nonatomic, strong) UIRefreshControl     *refresh;

@property (nonatomic, copy)   NSArray<PPCatalogItem *> *visibleItems;
@property (nonatomic, copy)   NSString                 *selectedCategory;
@end

@implementation PPBrowseViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Browse";

    _selectedCategory = @"All";

    // Chips strip.
    _chips = [[PPCategoryChipsView alloc] initWithFrame:CGRectZero];
    _chips.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    _chips.onSelect = ^(NSString *cat) {
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;
        self_.selectedCategory = cat;
        self_.chips.selectedCategory = cat;
        [self_ refreshVisibleItems];
    };
    [self.view addSubview:_chips];

    // Grid.
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing      = 14;
    layout.sectionInset            = UIEdgeInsetsMake(8, 14, 14, 14);

    _grid = [[UICollectionView alloc] initWithFrame:CGRectZero
                              collectionViewLayout:layout];
    _grid.translatesAutoresizingMaskIntoConstraints = NO;
    _grid.backgroundColor = [UIColor systemBackgroundColor];
    _grid.dataSource = self;
    _grid.delegate   = self;
    _grid.alwaysBounceVertical = YES;
    [_grid registerClass:[PPBrowseTileCell class] forCellWithReuseIdentifier:kCellID];
    [self.view addSubview:_grid];

    _refresh = [UIRefreshControl new];
    [_refresh addTarget:self action:@selector(pulledToRefresh)
        forControlEvents:UIControlEventValueChanged];
    _grid.refreshControl = _refresh;

    // Placeholder for empty / failure state.
    _placeholder = [UILabel new];
    _placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    _placeholder.numberOfLines = 0;
    _placeholder.textAlignment = NSTextAlignmentCenter;
    _placeholder.textColor = [UIColor secondaryLabelColor];
    _placeholder.font = [UIFont systemFontOfSize:15];
    _placeholder.hidden = YES;
    [self.view addSubview:_placeholder];

    _bigSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _bigSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    _bigSpinner.hidesWhenStopped = YES;
    [self.view addSubview:_bigSpinner];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_chips.topAnchor      constraintEqualToAnchor:safe.topAnchor],
        [_chips.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_chips.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_chips.heightAnchor   constraintEqualToConstant:48],

        [_grid.topAnchor       constraintEqualToAnchor:_chips.bottomAnchor],
        [_grid.leadingAnchor   constraintEqualToAnchor:self.view.leadingAnchor],
        [_grid.trailingAnchor  constraintEqualToAnchor:self.view.trailingAnchor],
        [_grid.bottomAnchor    constraintEqualToAnchor:self.view.bottomAnchor],

        [_placeholder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_placeholder.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_placeholder.widthAnchor   constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-40],

        [_bigSpinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_bigSpinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self loadCatalogForceRefresh:NO];
}

- (void)loadCatalogForceRefresh:(BOOL)forceRefresh {
    if ([[PPCatalogService shared] itemsForCategory:@"All"].count == 0) {
        [_bigSpinner startAnimating];
    }
    _placeholder.hidden = YES;

    [[PPCatalogService shared] fetchCatalogForceRefresh:forceRefresh
                                              completion:^(NSArray<PPCatalogItem *> *items,
                                                            NSError *error) {
        [self.bigSpinner stopAnimating];
        [self.refresh endRefreshing];

        if (error && items.count == 0) {
            self.placeholder.text = error.localizedDescription
                                 ?: @"Couldn't load the online catalog.";
            self.placeholder.hidden = NO;
            self.grid.hidden = YES;
            return;
        }

        if (error && items.count > 0) {
            // Soft-fail toast: we still show stale cache.
            // (Could show a banner; for now silently use cache.)
        }

        self.placeholder.hidden = YES;
        self.grid.hidden = NO;
        self.chips.categories = [[PPCatalogService shared] categoriesIncludingAll:YES];
        self.chips.selectedCategory = self.selectedCategory;
        [self refreshVisibleItems];
    }];
}

- (void)refreshVisibleItems {
    self.visibleItems = [[PPCatalogService shared] itemsForCategory:self.selectedCategory];
    [self.grid reloadData];
}

- (void)pulledToRefresh {
    [self loadCatalogForceRefresh:YES];
}

#pragma mark Grid

- (NSInteger)collectionView:(UICollectionView *)cv
       numberOfItemsInSection:(NSInteger)section {
    return self.visibleItems.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    PPBrowseTileCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kCellID
                                                            forIndexPath:ip];
    [cell configureWithItem:self.visibleItems[ip.item]];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    BOOL pad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    int columns = pad ? 3 : 2;
    CGFloat spacing = 12;
    CGFloat side = (cv.bounds.size.width - 14 * 2 - spacing * (columns - 1)) / columns;
    // 9:16 portrait tiles -- looks like a wallpaper preview.
    return CGSizeMake(floor(side), floor(side * 16.0 / 9.0));
}

- (void)collectionView:(UICollectionView *)cv
    didSelectItemAtIndexPath:(NSIndexPath *)ip {
    PPCatalogItem *item = self.visibleItems[ip.item];
    [self startImportPipelineForItem:item];
}

#pragma mark Download + import + apply

- (void)startImportPipelineForItem:(PPCatalogItem *)item {
    PPImportProgressViewController *progress = [[PPImportProgressViewController alloc]
        initWithStageTitles:@[@"Downloading", @"Importing", @"Resizing", @"Done"]];
    __block NSString *finalBundlePath = nil;
    __block PPWallpaperItem *finalItem = nil;

    progress.applyHandler = ^{
        if (!finalBundlePath.length) {
            [progress dismissAfterApplying];
            return;
        }
        NSError *err = nil;
        if (![PPApplyBridge applyItem:finalItem error:&err]) {
            [progress dismissAfterApplying];
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Apply failed"
                                 message:err.localizedDescription ?: @"Unknown error"
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
            return;
        }
        // Success -- close the card; the lockscreen overlay updates
        // automatically on the next CSCoverSheetView remount, and the
        // user can hit Respring from Detail later if they want it
        // applied everywhere.
        [progress dismissAfterApplying];
    };

    [self presentViewController:progress animated:YES completion:^{
        [self runDownloadAndImport:item progress:progress
              finalBundleOut:&finalBundlePath finalItemOut:&finalItem];
    }];
}

// Called inside the progress card's presentation completion. Runs the
// 4-stage pipeline on a background queue. Stores the resulting bundle
// path / library item via the out-pointers so the applyHandler block
// (set above on the main queue) can read them when the user taps Apply.
//
// Implementation detail: out-pointers are __block-captured by the
// caller; we just write through them.
- (void)runDownloadAndImport:(PPCatalogItem *)item
                    progress:(PPImportProgressViewController *)progress
              finalBundleOut:(NSString * __strong *)bundleOut
                finalItemOut:(PPWallpaperItem * __strong *)itemOut {
    CGSize targetSize = [UIScreen mainScreen].bounds.size;

    // Capture the out-pointers through __block-able plain holders.
    __block NSString *capturedBundle = nil;
    __block PPWallpaperItem *capturedItem = nil;

    void (^handleFailure)(NSString *) = ^(NSString *msg) {
        [progress failWithMessage:msg ?: @"Failed"];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Couldn't add wallpaper"
                                 message:msg ?: @"Unknown error"
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
            // Slight delay so the failure-card animation has a chance.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.presentedViewController) {
                    [self.presentedViewController presentViewController:a
                                                                animated:YES
                                                              completion:nil];
                } else {
                    [self presentViewController:a animated:YES completion:nil];
                }
            });
        });
    };

    // Stage 1: Download.
    [[PPCatalogService shared] downloadItem:item
        progress:^(double pct) {
            int percent = (int)(pct * 100);
            [progress updateCurrentStageDetail:[NSString stringWithFormat:@"%d%%", percent]];
        }
        completion:^(NSString *localPath, NSError *err) {
            if (!localPath || err) {
                handleFailure(err.localizedDescription ?: @"Download failed");
                return;
            }
            [progress finishCurrentStage]; // Downloading -> Importing

            // Stage 2 + 3 happen on a background queue (they're CPU-heavy
            // for big .tendies files).
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *e2 = nil;
                PPWallpaperItem *libItem = [[PPWallpaperLibrary shared]
                    beginImportTendiesAtPath:localPath
                                 displayName:item.displayName
                                       error:&e2];
                if (!libItem) {
                    handleFailure(e2.localizedDescription ?: @"Import failed");
                    return;
                }
                [progress finishCurrentStage]; // Importing -> Resizing

                NSError *e3 = nil;
                [[PPWallpaperLibrary shared] resizeItem:libItem
                                                 toSize:targetSize
                                                  error:&e3];
                // Resize errors aren't fatal -- the unscaled bundle is
                // still usable. Just continue.

                capturedBundle = libItem.bundlePath;
                capturedItem   = libItem;
                if (bundleOut) *bundleOut = capturedBundle;
                if (itemOut)   *itemOut   = capturedItem;

                [progress finishCurrentStage]; // Resizing -> Done
                [progress finishCurrentStage]; // Done -> reveal Apply button
            });
        }];
}

@end
