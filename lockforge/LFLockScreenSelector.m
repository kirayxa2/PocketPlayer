#import "LFLockScreenSelector.h"
#import "LFClockOverlay.h"
#import "LFLockScreenLibrary.h"
#import <objc/runtime.h>

// =====================================================================
// iOS 26 selector layout constants -- picked off Apple's actual UI
// dimensions on a 6.1"-class device, then trusted to scale via auto-
// resizing because the geometry is all proportional.
// =====================================================================

// Card visual:
static const CGFloat kLFCardCornerRadius   = 22.0;
static const CGFloat kLFCardBorderWidth    = 0.5;

// Carousel layout proportions, matched to iOS 16/26 reference shots.
//
// The card is sized to the DEVICE'S aspect ratio (so the carousel
// looks like a stack of mini-phones), and occupies ~70% of the
// viewport width.
static const CGFloat kLFCardWidthRatio     = 0.70;
static const CGFloat kLFCardInterSpacing   = 16.0;
static const CGFloat kLFSnapshotBottomCrop = 120.0;

// Top label "PHOTOS" position
static const CGFloat kLFTopLabelTopMargin  = 8.0;
static const CGFloat kLFTopLabelHeight     = 18.0;
static const CGFloat kLFTopLabelKerning    = 1.2;
static const CGFloat kLFTopLabelToCardGap  = 14.0;

// Bottom buttons.
static const CGFloat kLFBottomBarMargin    = 16.0;
static const CGFloat kLFBottomBarSideInset = 22.0;
static const CGFloat kLFCustomizeBtnH      = 50.0;
static const CGFloat kLFCustomizeBtnW      = 200.0;
static const CGFloat kLFPlusBtnSize        = 50.0;

// Page dots
static const CGFloat kLFPageDotSize        = 7.0;
static const CGFloat kLFPageDotSpacing     = 6.0;
static const CGFloat kLFPageDotsBottomGap  = 16.0;
static const CGFloat kLFCardToDotsGap      = 18.0;

// Focus pill (inside each card)
static const CGFloat kLFFocusPillW         = 78.0;
static const CGFloat kLFFocusPillH         = 28.0;
static const CGFloat kLFFocusPillBottomGap = 22.0;
static const CGFloat kLFFocusIconSize      = 14.0;

// Tags so we can find subviews of a generic card without storing
// arrays of separate references for everything.
static const NSInteger kLFTagSnapshot   = 0xF50A;
static const NSInteger kLFTagFocusPill  = 0xF0C5;
static const NSInteger kLFTagFocusIcon  = 0xF06A;
static const NSInteger kLFTagFocusLabel = 0xF06B;
static const NSInteger kLFTagWallpaperImg = 0xF50B;     // UIImageView under snap
// Each card's userdata key for the lock-screen UUID it represents.
static char kLFCardUUIDKey;

// =====================================================================

// Forward decl -- definition below in #pragma mark - Library bitmap
// capture. Needed because viewDidLoad calls it before the function
// itself appears in the file.
static UIImage *LFCaptureLockScreenImage(UIView *coverSheet);

@interface LFLockScreenSelector () <UIScrollViewDelegate,
                                     UINavigationControllerDelegate,
                                     UIImagePickerControllerDelegate>
@property (nonatomic, weak)   UIView          *sourceCoverSheet;
@property (nonatomic, weak)   LFClockOverlay  *clockOverlay;

@property (nonatomic, strong) UILabel         *categoryLabel;
@property (nonatomic, strong) UIScrollView    *cardsScroll;
@property (nonatomic, strong) NSMutableArray<UIView *> *cards;
@property (nonatomic, strong) UIView          *pageDotsContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *pageDots;
@property (nonatomic, strong) UIButton        *customizeButton;
@property (nonatomic, strong) UIButton        *plusButton;

// Cached one-shot live-snapshot of the active screen taken at present
// time. Used as the FIRST card's image; subsequent cards (inactive
// lock screens) just show their wallpaper file with no live overlays.
@property (nonatomic, strong) UIImage         *liveSnapshotAtPresent;
@property (nonatomic, copy)   NSString        *liveSnapshotForUUID;

@property (nonatomic, copy)   NSArray<NSString *> *lockScreenIds;
@property (nonatomic, assign) NSInteger        currentIndex;

@end

@implementation LFLockScreenSelector

- (instancetype)initWithCoverSheetView:(UIView *)coverSheetView
                          clockOverlay:(LFClockOverlay *)overlay {
    if ((self = [super init])) {
        _sourceCoverSheet = coverSheetView;
        _clockOverlay     = overlay;
        _currentIndex     = 0;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // Cache the snapshot of the live lock screen ONCE, while the user
    // hasn't scrolled the active away yet. We use this image for
    // whichever card matches the original-active uuid -- that card
    // gets the "real" preview with clock + widgets, while other cards
    // show only their wallpaper image. This keeps card construction
    // cheap: capture is O(N) only on the first card, the rest are
    // O(1) image-views.
    LFLockScreenLibrary *lib = [LFLockScreenLibrary shared];
    _liveSnapshotForUUID    = [lib.activeId copy];
    _liveSnapshotAtPresent  = LFCaptureLockScreenImage(_sourceCoverSheet);

    // Snapshot the library state for our current pass. We DON'T live-
    // observe library changes here -- if the user adds/removes a card,
    // we rebuild via -reloadCards. Initial scroll position == active.
    _lockScreenIds = [lib.lockScreenIds copy];
    NSInteger idx = [_lockScreenIds indexOfObject:lib.activeId];
    _currentIndex = (idx == NSNotFound) ? 0 : idx;

    [self buildCategoryLabel];
    [self buildCardsScroll];
    [self buildPageDots];
    [self buildBottomBar];
    [self installDismissGesture];

    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(onLibraryChanged:)
               name:LFLockScreenLibraryChangedNotification object:nil];
}

#pragma mark - Build

- (void)buildCategoryLabel {
    _categoryLabel = [UILabel new];
    _categoryLabel.textAlignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName:            [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.6],
        NSKernAttributeName:            @(kLFTopLabelKerning),
    };
    _categoryLabel.attributedText = [[NSAttributedString alloc]
        initWithString:@"PHOTOS" attributes:attrs];
    [self.view addSubview:_categoryLabel];
}

- (void)buildCardsScroll {
    _cardsScroll = [UIScrollView new];
    _cardsScroll.pagingEnabled                  = NO;
    _cardsScroll.showsHorizontalScrollIndicator = NO;
    _cardsScroll.showsVerticalScrollIndicator   = NO;
    _cardsScroll.clipsToBounds                  = NO;     // peek visible past bounds
    _cardsScroll.decelerationRate               = UIScrollViewDecelerationRateFast;
    _cardsScroll.delegate                       = self;
    [self.view addSubview:_cardsScroll];

    _cards = [NSMutableArray array];
    [self reloadCards];
}

- (void)reloadCards {
    for (UIView *v in _cards) [v removeFromSuperview];
    [_cards removeAllObjects];

    LFLockScreenLibrary *lib = [LFLockScreenLibrary shared];
    for (NSString *uuid in _lockScreenIds) {
        UIView *card = [self buildCardForUUID:uuid library:lib];
        [_cardsScroll addSubview:card];
        [_cards addObject:card];
    }

    // Rebuild page dots to match new count.
    if (_pageDotsContainer) [self rebuildPageDots];

    [self.view setNeedsLayout];
}

// Build one preview card for a given lock-screen uuid. The active
// screen at the time the selector was presented gets the live
// snapshot (with clock + widgets); all others get a wallpaper-only
// preview. This is the iOS 26 behaviour exactly -- the picker shows
// a static thumbnail per saved screen, only the centred (active)
// one is "live".
- (UIView *)buildCardForUUID:(NSString *)uuid library:(LFLockScreenLibrary *)lib {
    UIView *card = [UIView new];
    objc_setAssociatedObject(card, &kLFCardUUIDKey, uuid,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    card.backgroundColor       = [UIColor blackColor];
    card.layer.cornerRadius    = kLFCardCornerRadius;
    card.layer.masksToBounds   = YES;
    card.layer.borderWidth     = kLFCardBorderWidth;
    card.layer.borderColor     =
        [[UIColor colorWithWhite:1.0 alpha:0.08] CGColor];

    // Layer 1 -- wallpaper image (always present if the screen has a
    // custom wallpaper). Sits at the bottom of the card.
    NSString *wallpaperPath = [lib wallpaperPathForId:uuid];
    if (wallpaperPath) {
        UIImageView *wp = [[UIImageView alloc] initWithImage:
                           [UIImage imageWithContentsOfFile:wallpaperPath]];
        wp.tag                    = kLFTagWallpaperImg;
        wp.contentMode            = UIViewContentModeScaleAspectFill;
        wp.clipsToBounds          = YES;
        wp.userInteractionEnabled = NO;
        [card addSubview:wp];
    }

    // Layer 2 -- live overlay (only the originally-active screen).
    if ([uuid isEqualToString:_liveSnapshotForUUID] && _liveSnapshotAtPresent) {
        UIImageView *snap = [[UIImageView alloc] initWithImage:_liveSnapshotAtPresent];
        snap.tag                     = kLFTagSnapshot;
        snap.userInteractionEnabled  = NO;
        snap.contentMode             = UIViewContentModeScaleAspectFill;
        snap.clipsToBounds           = YES;
        [card addSubview:snap];
    }

    // Focus pill (decorative, same on every card).
    UIView *pill = [UIView new];
    pill.tag                = kLFTagFocusPill;
    pill.backgroundColor    = [UIColor colorWithWhite:0.0 alpha:0.35];
    pill.layer.cornerRadius = kLFFocusPillH / 2.0;
    pill.layer.masksToBounds = YES;
    pill.userInteractionEnabled = NO;
    [card addSubview:pill];

    UIImageView *moon = [UIImageView new];
    moon.tag       = kLFTagFocusIcon;
    moon.tintColor = [UIColor whiteColor];
    moon.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        moon.image = [UIImage systemImageNamed:@"moon.fill" withConfiguration:cfg];
    }
    [pill addSubview:moon];

    UILabel *focusLabel = [UILabel new];
    focusLabel.tag       = kLFTagFocusLabel;
    focusLabel.text      = @"Focus";
    focusLabel.textColor = [UIColor whiteColor];
    focusLabel.font      = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [pill addSubview:focusLabel];

    // Swipe-up gesture for delete. Apple's iOS 16+ flow is long-press
    // -> context menu. The user explicitly DISABLED long-press for
    // delete ("ни какого удержания"); swipe-up is the cleanest
    // alternative because it's an unambiguous gesture (the card
    // doesn't otherwise scroll vertically) and it's also what iOS 26
    // uses to remove cards from the multitasking switcher, so the
    // mental model carries over.
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(onCardSwipeUp:)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp;
    [card addGestureRecognizer:swipe];

    return card;
}

- (void)buildPageDots {
    _pageDotsContainer = [UIView new];
    _pageDots          = [NSMutableArray array];
    [self.view addSubview:_pageDotsContainer];
    [self rebuildPageDots];
}

- (void)rebuildPageDots {
    for (UIView *d in _pageDots) [d removeFromSuperview];
    [_pageDots removeAllObjects];
    NSInteger n = (NSInteger)_lockScreenIds.count;
    for (NSInteger i = 0; i < n; i++) {
        UIView *d = [UIView new];
        d.layer.cornerRadius  = kLFPageDotSize / 2.0;
        d.layer.masksToBounds = YES;
        [_pageDotsContainer addSubview:d];
        [_pageDots addObject:d];
    }
    _pageDotsContainer.hidden = (n <= 1);
    [self refreshDotColors];
}

- (void)refreshDotColors {
    for (NSInteger i = 0; i < _pageDots.count; i++) {
        UIView *d = _pageDots[i];
        d.backgroundColor = (i == _currentIndex)
            ? [UIColor whiteColor]
            : [UIColor colorWithWhite:1.0 alpha:0.30];
    }
}

- (void)buildBottomBar {
    _customizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_customizeButton setTitle:@"Customize" forState:UIControlStateNormal];
    _customizeButton.titleLabel.font =
        [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_customizeButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    _customizeButton.backgroundColor =
        [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:1.0];
    _customizeButton.layer.cornerRadius   = kLFCustomizeBtnH / 2.0;
    _customizeButton.layer.masksToBounds  = YES;
    [_customizeButton addTarget:self
                         action:@selector(onCustomize)
               forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_customizeButton];

    _plusButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
        UIImage *plus = [UIImage systemImageNamed:@"plus" withConfiguration:cfg];
        [_plusButton setImage:plus forState:UIControlStateNormal];
    } else {
        [_plusButton setTitle:@"+" forState:UIControlStateNormal];
        _plusButton.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
        [_plusButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    }
    _plusButton.tintColor        = [UIColor whiteColor];
    _plusButton.backgroundColor  = [UIColor systemBlueColor];
    _plusButton.layer.cornerRadius   = kLFPlusBtnSize / 2.0;
    _plusButton.layer.masksToBounds  = YES;
    [_plusButton addTarget:self
                    action:@selector(onPlus)
          forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_plusButton];
}

- (void)installDismissGesture {
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(onDismissGesture)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipe];
}

#pragma mark - Library bitmap capture

// Capture the live lock screen as a static UIImage. Same renderer the
// previous build used; kept as a free function so it's easy to call
// from -viewDidLoad without holding a reference to the live window.
static UIImage *LFCaptureLockScreenImage(UIView *coverSheet) {
    if (!coverSheet) return nil;
    UIWindow *coverWindow = coverSheet.window;
    if (!coverWindow) return nil;

    CGRect screenRect = [UIScreen mainScreen].bounds;
    if (screenRect.size.width < 1.0 || screenRect.size.height < 1.0) {
        return nil;
    }

    UIGraphicsBeginImageContextWithOptions(screenRect.size, NO, 0.0);
    if (!UIGraphicsGetCurrentContext()) {
        UIGraphicsEndImageContext();
        return nil;
    }

    BOOL ok = [coverWindow drawViewHierarchyInRect:screenRect
                                afterScreenUpdates:YES];
    (void)ok;

    NSArray<UIWindow *> *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *win in windows) {
        if (win == coverWindow) continue;
        if (win.hidden || win.alpha < 0.01) continue;
        if (win.windowLevel <= coverWindow.windowLevel) continue;
        [win drawViewHierarchyInRect:win.frame afterScreenUpdates:YES];
    }

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGRect b = self.view.bounds;

    _categoryLabel.frame = CGRectMake(0,
                                      safe.top + kLFTopLabelTopMargin,
                                      b.size.width,
                                      kLFTopLabelHeight);

    CGFloat bottomY = b.size.height - safe.bottom -
                      kLFBottomBarMargin - kLFCustomizeBtnH;
    _customizeButton.frame = CGRectMake((b.size.width - kLFCustomizeBtnW) / 2.0,
                                        bottomY,
                                        kLFCustomizeBtnW, kLFCustomizeBtnH);
    _plusButton.frame      = CGRectMake(b.size.width - kLFBottomBarSideInset - kLFPlusBtnSize,
                                        bottomY,
                                        kLFPlusBtnSize, kLFPlusBtnSize);

    NSInteger numCards = (NSInteger)_lockScreenIds.count;
    CGFloat dotsTotalW = numCards * kLFPageDotSize +
                         (numCards - 1) * kLFPageDotSpacing;
    if (dotsTotalW < 0) dotsTotalW = 0;
    CGFloat dotsY = bottomY - kLFPageDotsBottomGap - kLFPageDotSize;
    _pageDotsContainer.frame = CGRectMake((b.size.width - dotsTotalW) / 2.0,
                                          dotsY,
                                          dotsTotalW,
                                          kLFPageDotSize);
    for (NSInteger i = 0; i < _pageDots.count; i++) {
        UIView *d = _pageDots[i];
        d.frame = CGRectMake(i * (kLFPageDotSize + kLFPageDotSpacing), 0,
                             kLFPageDotSize, kLFPageDotSize);
    }

    CGRect screenB = [UIScreen mainScreen].bounds;
    CGFloat sourceW = screenB.size.width;
    CGFloat sourceH = screenB.size.height;
    if (sourceW < 1.0) sourceW = b.size.width;
    if (sourceH < 1.0) sourceH = b.size.height;

    CGFloat usableSourceH = MAX(sourceH - kLFSnapshotBottomCrop, sourceH * 0.5);
    CGFloat cardAspect    = usableSourceH / sourceW;
    CGFloat cardW         = floor(b.size.width * kLFCardWidthRatio);
    CGFloat cardH         = floor(cardW * cardAspect);

    CGFloat areaTop    = CGRectGetMaxY(_categoryLabel.frame) + kLFTopLabelToCardGap;
    CGFloat areaBottom = _pageDotsContainer.frame.origin.y - kLFCardToDotsGap;
    CGFloat areaH      = MAX(0, areaBottom - areaTop);

    if (cardH > areaH) {
        cardH = areaH;
        cardW = floor(cardH / cardAspect);
    }

    CGFloat cardY = areaTop + (areaH - cardH) / 2.0;

    _cardsScroll.frame = CGRectMake(0, cardY, b.size.width, cardH);

    CGFloat sideInset = (b.size.width - cardW) / 2.0;
    _cardsScroll.contentInset = UIEdgeInsetsMake(0, sideInset, 0, sideInset);

    CGFloat snapScale = cardW / sourceW;
    CGFloat snapH     = sourceH * snapScale;
    CGFloat x = 0;
    for (NSInteger i = 0; i < _cards.count; i++) {
        UIView *card = _cards[i];
        card.frame = CGRectMake(x, 0, cardW, cardH);
        x += cardW + kLFCardInterSpacing;

        UIView *wp     = [card viewWithTag:kLFTagWallpaperImg];
        UIView *snap   = [card viewWithTag:kLFTagSnapshot];
        UIView *pill   = [card viewWithTag:kLFTagFocusPill];
        UIImageView *moon = (UIImageView *)[card viewWithTag:kLFTagFocusIcon];
        UILabel *flbl  = (UILabel *)[card viewWithTag:kLFTagFocusLabel];

        // Wallpaper fills the full card; snapshot (when present)
        // overflows below to crop home affordances exactly the way
        // the previous single-card path did.
        wp.frame   = CGRectMake(0, 0, cardW, cardH);
        snap.frame = CGRectMake(0, 0, cardW, snapH);

        pill.frame = CGRectMake((cardW - kLFFocusPillW) / 2.0,
                                cardH - kLFFocusPillH - kLFFocusPillBottomGap,
                                kLFFocusPillW, kLFFocusPillH);
        moon.frame = CGRectMake(10,
                                (kLFFocusPillH - kLFFocusIconSize) / 2.0,
                                kLFFocusIconSize, kLFFocusIconSize);
        [flbl sizeToFit];
        flbl.frame = CGRectMake(28,
                                (kLFFocusPillH - flbl.bounds.size.height) / 2.0,
                                flbl.bounds.size.width,
                                flbl.bounds.size.height);
    }
    CGFloat contentW = (_cards.count > 0) ? (x - kLFCardInterSpacing) : 0;
    _cardsScroll.contentSize = CGSizeMake(contentW, cardH);

    // Snap to whichever index is currently active.
    _cardsScroll.contentOffset = CGPointMake(-sideInset +
        _currentIndex * (cardW + kLFCardInterSpacing), 0);
}

#pragma mark - Buttons

- (void)onCustomize {
    // Customize edits the CENTRED card (which we keep in sync with
    // library.activeId via the scroll-snap delegate), so by the time
    // the user taps this, library.activeId already reflects what
    // they're looking at.
    [self.delegate selectorDidRequestEditor:self];
    [self dismissAnimated];
}

- (void)onPlus {
    // iOS 26 "+" presents the photo picker. We accept any photo, scale
    // it to screen size on import, and create a new lock-screen
    // initialised to defaults with that wallpaper.
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType    = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.allowsEditing = NO;
    picker.delegate      = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)onDismissGesture {
    [self.delegate selectorDidDismiss:self];
    [self dismissAnimated];
}

- (void)onCardSwipeUp:(UISwipeGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    UIView *card = g.view;
    NSString *uuid = objc_getAssociatedObject(card, &kLFCardUUIDKey);
    if (![uuid isKindOfClass:[NSString class]]) return;

    LFLockScreenLibrary *lib = [LFLockScreenLibrary shared];
    if (lib.count <= 1) {
        // Last screen: don't allow delete -- explain via alert.
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"Can't Delete"
                             message:@"You need at least one lock screen."
                      preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    // Animate card UP off screen, then mutate library + reload.
    [UIView animateWithDuration:0.20
                     animations:^{
        card.transform = CGAffineTransformMakeTranslation(0, -200);
        card.alpha     = 0;
    }
                     completion:^(BOOL _) {
        [lib removeId:uuid];
        // Library posts LFLockScreenLibraryChangedNotification, our
        // observer reloads the cards array and the layout pass re-
        // snaps to the new active index. (active-changed notification
        // is also posted if we removed the active card, which the
        // tweak picks up to refresh wallpaper / clock.)
    }];
}

- (void)dismissAnimated {
    __weak __typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.25 animations:^{
        weakSelf.view.alpha = 0;
    } completion:^(BOOL ok) {
        [weakSelf.view removeFromSuperview];
    }];
}

#pragma mark - Library notifications

- (void)onLibraryChanged:(NSNotification *)n {
    LFLockScreenLibrary *lib = [LFLockScreenLibrary shared];
    _lockScreenIds = [lib.lockScreenIds copy];
    NSInteger idx = [_lockScreenIds indexOfObject:lib.activeId];
    _currentIndex = (idx == NSNotFound) ? 0 : idx;
    [self reloadCards];
}

#pragma mark - Presentation

- (void)presentInWindow:(UIWindow *)window {
    self.view.frame = window.bounds;
    self.view.alpha = 0;
    [window addSubview:self.view];
    [UIView animateWithDuration:0.25 animations:^{
        self.view.alpha = 1;
    }];
}

#pragma mark - UIScrollViewDelegate (snap + active sync)

- (void)scrollViewWillEndDragging:(UIScrollView *)sv
                     withVelocity:(CGPoint)v
              targetContentOffset:(inout CGPoint *)target {
    NSInteger numCards = (NSInteger)_lockScreenIds.count;
    if (numCards <= 1) {
        target->x = -sv.contentInset.left;
        return;
    }
    CGFloat cardW  = (_cards.count > 0) ? _cards.firstObject.frame.size.width
                                        : sv.bounds.size.width;
    CGFloat stride = cardW + kLFCardInterSpacing;
    CGFloat origin = target->x + sv.contentInset.left;
    NSInteger idx  = (NSInteger)round(origin / stride);
    idx = MAX(0, MIN(numCards - 1, idx));
    target->x = -sv.contentInset.left + idx * stride;
    _currentIndex = idx;
    [self refreshDotColors];

    // Apply the new active immediately on snap so the live lockscreen
    // beneath us swaps wallpaper / clock to match by the time the
    // selector fades. Library does the right thing if the uuid is
    // already active (no-op).
    NSString *uuid = _lockScreenIds[idx];
    [[LFLockScreenLibrary shared] setActiveId:uuid];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    [self refreshDotColors];
}

#pragma mark - UIImagePickerControllerDelegate (+ flow)

- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    UIImage *raw = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!raw) return;
        UIImage *cropped = [self imageScaledToScreen:raw];
        NSString *uuid = [[LFLockScreenLibrary shared]
            addLockScreenWithWallpaperImage:cropped];
        // Library posts both LFLockScreenLibraryChangedNotification
        // and LFActiveLockScreenChangedNotification. -onLibraryChanged
        // rebuilds cards; the active-changed notification reaches the
        // wallpaper view + clock overlay via the tweak.
        (void)uuid;
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

// Aspect-fill the picked image to the device screen size, then JPEG-
// encode at quality 0.9. Keeps file size around 200-400KB on 6s and
// avoids storing 10+MB raw images.
- (UIImage *)imageScaledToScreen:(UIImage *)img {
    CGSize target = [UIScreen mainScreen].bounds.size;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize px = CGSizeMake(target.width * scale, target.height * scale);

    CGFloat sx = px.width  / img.size.width;
    CGFloat sy = px.height / img.size.height;
    CGFloat s  = MAX(sx, sy);   // aspect-fill
    CGSize fit = CGSizeMake(img.size.width * s, img.size.height * s);
    CGRect drawRect = CGRectMake((px.width  - fit.width)  / 2.0,
                                 (px.height - fit.height) / 2.0,
                                 fit.width, fit.height);

    UIGraphicsBeginImageContextWithOptions(px, YES, 1.0);
    [img drawInRect:drawRect];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

@end
