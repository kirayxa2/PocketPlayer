#import "LFLockScreenWidgetPicker.h"
#import "LFLockScreenWidgetCatalog.h"

#pragma mark - Cell

@interface LFPickerCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel     *nameLabel;
@property (nonatomic, strong) UILabel     *appLabel;
@end

@implementation LFPickerCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.contentView.backgroundColor   = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.contentView.layer.cornerRadius = 18;
    self.contentView.layer.masksToBounds = YES;

    _iconView              = [UIImageView new];
    _iconView.contentMode  = UIViewContentModeScaleAspectFit;
    _iconView.tintColor    = [UIColor whiteColor];
    [self.contentView addSubview:_iconView];

    _nameLabel             = [UILabel new];
    _nameLabel.font        = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _nameLabel.textColor   = [UIColor whiteColor];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:_nameLabel];

    _appLabel              = [UILabel new];
    _appLabel.font         = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
    _appLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.50];
    _appLabel.textAlignment = NSTextAlignmentCenter;
    [self.contentView addSubview:_appLabel];

    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _iconView.frame = CGRectMake((b.size.width - 32) / 2.0, 14, 32, 32);
    _nameLabel.frame = CGRectMake(4, b.size.height - 32, b.size.width - 8, 14);
    _appLabel.frame  = CGRectMake(4, b.size.height - 18, b.size.width - 8, 12);
}
@end

#pragma mark - Picker

@interface LFLockScreenWidgetPicker () <UICollectionViewDataSource,
                                        UICollectionViewDelegate,
                                        UITextFieldDelegate>
@property (nonatomic, assign) LFWidgetFamily targetFamily;
@property (nonatomic, copy)   LFPickerCompletion completion;

@property (nonatomic, strong) UIVisualEffectView *backdrop;
@property (nonatomic, strong) UIView             *sheet;
@property (nonatomic, strong) UILabel            *titleLabel;
@property (nonatomic, strong) UIButton           *closeButton;
@property (nonatomic, strong) UILabel            *suggestionsHeader;
@property (nonatomic, strong) UICollectionView   *suggestionsCV;
@property (nonatomic, strong) UILabel            *allHeader;
@property (nonatomic, strong) UICollectionView   *allCV;

@property (nonatomic, copy)   NSArray<LFLockScreenWidgetDescriptor *> *suggestions;
@property (nonatomic, copy)   NSArray<LFLockScreenWidgetDescriptor *> *allItems;
@end

@implementation LFLockScreenWidgetPicker

- (instancetype)initForFamily:(LFWidgetFamily)family
                   completion:(LFPickerCompletion)completion {
    self = [super init];
    if (!self) return nil;
    _targetFamily = family;
    _completion   = [completion copy];

    NSMutableArray *all = [NSMutableArray array];
    NSMutableArray *sug = [NSMutableArray array];
    for (LFLockScreenWidgetDescriptor *d in [LFLockScreenWidgetCatalog allDescriptors]) {
        BOOL fits = NO;
        for (NSNumber *n in d.supportedFamilies) {
            if ([n integerValue] == family) { fits = YES; break; }
        }
        if (!fits) continue;
        [all addObject:d];
        if (d.isSuggested) [sug addObject:d];
    }
    _allItems    = all;
    _suggestions = sug;
    return self;
}

- (void)presentFromViewController:(UIViewController *)host {
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle   = UIModalTransitionStyleCoverVertical;
    [host presentViewController:self animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.50];

    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark];
    _sheet = [[UIVisualEffectView alloc] initWithEffect:eff];
    _sheet.layer.cornerRadius = 28;
    _sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _sheet.layer.masksToBounds = YES;
    [self.view addSubview:_sheet];

    UIView *content = ((UIVisualEffectView *)_sheet).contentView;

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
        UIImage *xmark = [UIImage systemImageNamed:@"xmark.circle.fill"
                                  withConfiguration:cfg];
        [_closeButton setImage:xmark forState:UIControlStateNormal];
    }
    _closeButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [_closeButton addTarget:self action:@selector(onClose)
           forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:_closeButton];

    _titleLabel              = [UILabel new];
    _titleLabel.text         = @"Add Widget";
    _titleLabel.font         = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    _titleLabel.textColor    = [UIColor whiteColor];
    [content addSubview:_titleLabel];

    _suggestionsHeader            = [UILabel new];
    _suggestionsHeader.text       = @"SUGGESTIONS";
    _suggestionsHeader.font       = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _suggestionsHeader.textColor  = [UIColor colorWithWhite:1.0 alpha:0.50];
    [content addSubview:_suggestionsHeader];

    UICollectionViewFlowLayout *layoutS = [UICollectionViewFlowLayout new];
    layoutS.scrollDirection      = UICollectionViewScrollDirectionHorizontal;
    layoutS.itemSize             = CGSizeMake(96, 100);
    layoutS.minimumLineSpacing   = 10;
    layoutS.sectionInset         = UIEdgeInsetsMake(0, 16, 0, 16);
    _suggestionsCV = [[UICollectionView alloc] initWithFrame:CGRectZero
                                       collectionViewLayout:layoutS];
    _suggestionsCV.backgroundColor               = [UIColor clearColor];
    _suggestionsCV.dataSource                    = self;
    _suggestionsCV.delegate                      = self;
    _suggestionsCV.showsHorizontalScrollIndicator = NO;
    _suggestionsCV.tag                           = 1;
    [_suggestionsCV registerClass:[LFPickerCell class]
       forCellWithReuseIdentifier:@"sug"];
    [content addSubview:_suggestionsCV];

    _allHeader            = [UILabel new];
    _allHeader.text       = @"ALL WIDGETS";
    _allHeader.font       = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _allHeader.textColor  = [UIColor colorWithWhite:1.0 alpha:0.50];
    [content addSubview:_allHeader];

    UICollectionViewFlowLayout *layoutA = [UICollectionViewFlowLayout new];
    layoutA.itemSize             = CGSizeMake(110, 110);
    layoutA.minimumLineSpacing   = 10;
    layoutA.minimumInteritemSpacing = 10;
    layoutA.sectionInset         = UIEdgeInsetsMake(0, 16, 16, 16);
    _allCV = [[UICollectionView alloc] initWithFrame:CGRectZero
                                collectionViewLayout:layoutA];
    _allCV.backgroundColor                = [UIColor clearColor];
    _allCV.dataSource                     = self;
    _allCV.delegate                       = self;
    _allCV.showsVerticalScrollIndicator   = NO;
    _allCV.tag                            = 2;
    [_allCV registerClass:[LFPickerCell class] forCellWithReuseIdentifier:@"all"];
    [content addSubview:_allCV];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;

    CGFloat sheetH = MIN(b.size.height - 80, 480);
    _sheet.frame = CGRectMake(0, b.size.height - sheetH, b.size.width, sheetH);

    _closeButton.frame = CGRectMake(b.size.width - 48, 12, 36, 36);
    _titleLabel.frame  = CGRectMake(20, 14, b.size.width - 80, 32);

    CGFloat y = 56;
    _suggestionsHeader.frame = CGRectMake(20, y, 200, 14); y += 18;
    _suggestionsCV.frame     = CGRectMake(0, y, b.size.width, 110); y += 116;
    _allHeader.frame         = CGRectMake(20, y, 200, 14); y += 18;

    CGFloat allCVHeight = sheetH - y - safe.bottom - 12;
    if (allCVHeight < 100) allCVHeight = 100;
    _allCV.frame = CGRectMake(0, y, b.size.width, allCVHeight);
}

- (void)onClose {
    if (_completion) _completion(0, _targetFamily, nil);
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - DataSource / Delegate

- (NSInteger)collectionView:(UICollectionView *)cv
     numberOfItemsInSection:(NSInteger)section {
    return (cv.tag == 1) ? _suggestions.count : _allItems.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)idx {
    LFLockScreenWidgetDescriptor *d = (cv.tag == 1)
        ? _suggestions[idx.item]
        : _allItems[idx.item];
    LFPickerCell *cell = [cv dequeueReusableCellWithReuseIdentifier:
        (cv.tag == 1 ? @"sug" : @"all") forIndexPath:idx];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
        cell.iconView.image = [UIImage systemImageNamed:d.sfSymbolName
                                      withConfiguration:cfg];
    }
    cell.nameLabel.text = d.displayName;
    cell.appLabel.text  = [d.appName uppercaseString];
    return cell;
}

- (void)collectionView:(UICollectionView *)cv
didSelectItemAtIndexPath:(NSIndexPath *)idx {
    LFLockScreenWidgetDescriptor *d = (cv.tag == 1)
        ? _suggestions[idx.item]
        : _allItems[idx.item];

    // For widgets that need follow-up config (CustomText / WorldClock)
    // we present a small UIAlertController to collect it. Battery /
    // Weather / Music / Calendar / etc. need no config and ship
    // straight to the size-pick step (or completion if there's only
    // one supported size).
    if (d.kind == LFWidgetKindCustomText) {
        [self promptForCustomTextWithDescriptor:d];
    } else if (d.kind == LFWidgetKindWorldClock) {
        [self promptForTimezoneWithDescriptor:d];
    } else {
        [self promptForSizeWithDescriptor:d config:@{}];
    }
}

#pragma mark - Size picker (1x1 vs 2x1 etc.)

// iOS 26 widget add flow lets the user swipe between size variations
// (Small / Medium / Large) before confirming. On the lock screen only
// two sizes are available -- circular (1x1, "Small") and rectangular
// (2x1, "Medium"). When a descriptor supports both, we show a quick
// action sheet that lets the user pick which one to add. Inline
// widgets are reached through the date picker, never through this
// path, so we only deal with circular vs rectangular here.
- (void)promptForSizeWithDescriptor:(LFLockScreenWidgetDescriptor *)d
                              config:(NSDictionary *)config {
    BOOL supportsCircular = NO, supportsRect = NO;
    for (NSNumber *n in d.supportedFamilies) {
        LFWidgetFamily f = (LFWidgetFamily)[n integerValue];
        if (f == LFWidgetFamilyCircular)    supportsCircular = YES;
        if (f == LFWidgetFamilyRectangular) supportsRect     = YES;
    }

    // Single supported size -> ship the only valid choice. Honor
    // targetFamily preference when both are valid for the SOURCE slot
    // (we filtered to families supported at descriptor level above).
    if (!(supportsCircular && supportsRect)) {
        LFWidgetFamily fam = supportsCircular ? LFWidgetFamilyCircular
                                              : LFWidgetFamilyRectangular;
        if (_completion) _completion(d.kind, fam, config);
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    // Both supported -> action sheet picker. Default selection follows
    // the slot the user originally tapped (targetFamily) so the most
    // common path -- "user tapped a circular slot, picked a widget,
    // wants the circular variant" -- is one tap.
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:d.displayName
                         message:@"Choose a size"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *smallTitle  = (_targetFamily == LFWidgetFamilyCircular)
        ? @"Small (1×1)  ✓" : @"Small (1×1)";
    NSString *mediumTitle = (_targetFamily == LFWidgetFamilyRectangular)
        ? @"Medium (2×1)  ✓" : @"Medium (2×1)";

    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:smallTitle
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) {
        __strong typeof(self) ss = ws;
        if (!ss) return;
        if (ss.completion) ss.completion(d.kind,
                                          LFWidgetFamilyCircular, config);
        [ss dismissViewControllerAnimated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:mediumTitle
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) {
        __strong typeof(self) ss = ws;
        if (!ss) return;
        if (ss.completion) ss.completion(d.kind,
                                          LFWidgetFamilyRectangular, config);
        [ss dismissViewControllerAnimated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Follow-up config prompts

- (void)promptForCustomTextWithDescriptor:(LFLockScreenWidgetDescriptor *)d {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Custom Text"
                         message:@"What should the inline widget show?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"e.g. RISE & SHINE";
    }];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Add"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *_) {
        __strong typeof(self) ss = ws;
        if (!ss) return;
        NSString *text = a.textFields.firstObject.text ?: @"";
        if (ss.completion) ss.completion(d.kind, ss.targetFamily,
                                          @{ @"text": text });
        [ss dismissViewControllerAnimated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptForTimezoneWithDescriptor:(LFLockScreenWidgetDescriptor *)d {
    // Compact list of common timezones; user can edit later through
    // the plist if they want exotic ones. Order chosen to surface the
    // most-likely picks first.
    NSArray<NSString *> *zones = @[
        @"America/Los_Angeles", @"America/New_York",
        @"Europe/London",       @"Europe/Berlin",
        @"Europe/Moscow",       @"Asia/Tokyo",
        @"Asia/Shanghai",       @"Australia/Sydney",
        @"UTC",
    ];
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"World Clock"
                         message:@"Pick a timezone."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (NSString *tz in zones) {
        [a addAction:[UIAlertAction actionWithTitle:tz
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            __strong typeof(self) ss = ws;
            if (!ss) return;
            if (ss.completion) ss.completion(d.kind, ss.targetFamily,
                                              @{ @"timezone": tz });
            [ss dismissViewControllerAnimated:YES completion:nil];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
