#import "PPRootViewController.h"
#import "PPWallpaperLibrary.h"
#import "PPApplyBridge.h"
#import "PPDetailViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kCellID = @"WP";

@interface PPRootViewController () <
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UIDocumentPickerDelegate>

@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UILabel          *emptyLabel;
@end

@implementation PPRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"PocketPoster";

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(tapImport:)];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing      = 10;
    layout.sectionInset            = UIEdgeInsetsMake(12, 12, 12, 12);

    self.grid = [[UICollectionView alloc] initWithFrame:self.view.bounds
                                   collectionViewLayout:layout];
    self.grid.translatesAutoresizingMaskIntoConstraints = NO;
    self.grid.backgroundColor = [UIColor systemBackgroundColor];
    self.grid.dataSource = self;
    self.grid.delegate   = self;
    [self.grid registerClass:[UICollectionViewCell class]
  forCellWithReuseIdentifier:kCellID];
    [self.view addSubview:self.grid];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"No wallpapers yet.\nTap + to import a .tendies file.";
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont systemFontOfSize:16];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.grid.topAnchor      constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.grid.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
        [self.grid.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.widthAnchor   constraintLessThanOrEqualToAnchor:self.view.widthAnchor
                                                              constant:-40],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[PPWallpaperLibrary shared] reload];
    [self refreshEmptyState];
    [self.grid reloadData];
}

- (void)refreshEmptyState {
    BOOL empty = [PPWallpaperLibrary shared].items.count == 0;
    self.emptyLabel.hidden = !empty;
    self.grid.hidden       = empty;
}

#pragma mark Import

- (void)tapImport:(id)sender {
    NSArray *types = @[];
    if (@available(iOS 14.0, *)) {
        // Allow our custom UTI (.tendies) plus generic zip.
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
    // Pre-iOS 14 fallback (we target 15+ but keep the safety net).
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
    NSError *err = nil;
    PPWallpaperItem *it = [[PPWallpaperLibrary shared] importTendiesAtURL:url
                                                                    error:&err];
    if (!it) {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"Import failed"
                             message:err.localizedDescription ?: @"Unknown error"
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self refreshEmptyState];
    [self.grid reloadData];
}

#pragma mark Grid

- (NSInteger)collectionView:(UICollectionView *)cv
       numberOfItemsInSection:(NSInteger)section {
    return [PPWallpaperLibrary shared].items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kCellID
                                                              forIndexPath:ip];
    PPWallpaperItem *it = [PPWallpaperLibrary shared].items[ip.item];

    // Wipe old subviews on reuse.
    for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];

    cell.contentView.backgroundColor   = [UIColor secondarySystemBackgroundColor];
    cell.contentView.layer.cornerRadius = 12;
    cell.contentView.layer.masksToBounds = YES;

    UIImage *preview = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:it.previewPath]) {
        preview = [UIImage imageWithContentsOfFile:it.previewPath];
    }
    UIImageView *iv = [[UIImageView alloc] initWithImage:preview];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    [cell.contentView addSubview:iv];

    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = it.displayName;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    l.textColor = [UIColor labelColor];
    l.numberOfLines = 1;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell.contentView addSubview:l];

    [NSLayoutConstraint activateConstraints:@[
        [iv.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor],
        [iv.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor],
        [iv.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
        [iv.bottomAnchor   constraintEqualToAnchor:l.topAnchor constant:-6],
        [l.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:8],
        [l.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
        [l.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ]];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    // 2-up grid on phone, 3-up on iPad.
    BOOL pad = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    int columns = pad ? 3 : 2;
    CGFloat side = (cv.bounds.size.width - 12 * (columns + 1)) / columns;
    return CGSizeMake(floor(side), floor(side * 9.0 / 16.0) + 28);
}

- (void)collectionView:(UICollectionView *)cv
    didSelectItemAtIndexPath:(NSIndexPath *)ip {
    PPWallpaperItem *it = [PPWallpaperLibrary shared].items[ip.item];
    PPDetailViewController *d = [[PPDetailViewController alloc] initWithItem:it];
    [self.navigationController pushViewController:d animated:YES];
}

@end
