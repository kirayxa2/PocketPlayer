#import "LFLockScreenSelector.h"
#import "LFClockOverlay.h"

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
// viewport width. This is the single most important geometric
// rule -- mismatched aspect was what made my first pass not look
// like the iOS 26 picker.
//
// Once card width is fixed, peek of side cards is automatic:
//
//   peek_per_side = (viewport_width - card_width) / 2
//
// On iPhone 6s (375pt wide) -> 263pt card -> 56pt peek per side.
static const CGFloat kLFCardWidthRatio     = 0.70;     // 70% of screen width
static const CGFloat kLFCardInterSpacing   = 16.0;     // gap between adjacent cards

// How much of the source cover-sheet's BOTTOM we hide in the card
// preview. iOS 16/26 customize-sheet thumbnails show the wallpaper +
// clock + (optional) widgets ONLY -- they don't show the camera /
// flashlight shortcut buttons or the home indicator that live in
// the bottom strip of the live lock screen. We mimic that by
// growing the snapshot view past the bottom edge of the card by this
// many points (in source coordinates), then relying on the card's
// existing clipsToBounds to hide the overflow.
//
// 120pt covers:
//   - camera/flashlight affordance buttons (~70-110pt from bottom)
//   - "swipe up" / "press home" hint (~30-50pt from bottom)
//   - home indicator on devices that have one (~30pt from bottom)
static const CGFloat kLFSnapshotBottomCrop = 120.0;

// Top label "PHOTOS" position
static const CGFloat kLFTopLabelTopMargin  = 8.0;
static const CGFloat kLFTopLabelHeight     = 18.0;
static const CGFloat kLFTopLabelKerning    = 1.2;
static const CGFloat kLFTopLabelToCardGap  = 14.0;

// Bottom buttons.
//
// iOS 26 wallpaper picker layout is: small wallpaper-thumbnail icon
// in the bottom-LEFT, "Customize" pill CENTERED, "+" circle in the
// bottom-RIGHT. We don't have a wallpaper thumbnail (PR-A keeps
// PocketPlayer's wallpaper system separate), so the bar is just
// Customize centered + "+" on the right.
//
// kLFBottomBarSideInset is how far the "+" button sits from the
// right screen edge. Customize is purely centered horizontally and
// doesn't need an inset constant.
static const CGFloat kLFBottomBarMargin    = 16.0;     // distance from safeArea bottom
static const CGFloat kLFBottomBarSideInset = 22.0;     // inset for "+" only
// Customize pill is the visual anchor of the bottom action bar --
// noticeably larger than the auxiliary "+" button so it reads as the
// primary action. iOS 26 dimensions on a 6s-class screen: ~180pt
// wide x 52pt tall, 17pt Semibold label. Earlier 124x50pt was too
// small relative to the card and got lost on the bar.
// User reported the previous 180x52 / 17pt Semibold size still
// looked small relative to the card. Bumped further to match Apple's
// iOS 26 visual weight where Customize is a substantial primary
// action -- 240pt wide x 56pt tall, 18pt Semibold label. At this
// width the button is ~91% of the card width on a 6s, which reads as
// the visual anchor of the bar. The auxiliary "+" button stays at
// 50pt diameter so the size contrast keeps it clearly secondary.
static const CGFloat kLFCustomizeBtnH      = 56.0;
static const CGFloat kLFCustomizeBtnW      = 240.0;
static const CGFloat kLFPlusBtnSize        = 50.0;

// Page dots (above the action bar)
static const CGFloat kLFPageDotSize        = 7.0;
static const CGFloat kLFPageDotSpacing     = 6.0;
static const CGFloat kLFPageDotsBottomGap  = 16.0;     // gap from dots to action bar
static const CGFloat kLFCardToDotsGap      = 18.0;     // gap from card bottom to dots

// Focus pill (inside each card, bottom-center)
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

// =====================================================================

@interface LFLockScreenSelector () <UIScrollViewDelegate>
@property (nonatomic, weak)   UIView          *sourceCoverSheet;
@property (nonatomic, weak)   LFClockOverlay  *clockOverlay;

@property (nonatomic, strong) UILabel         *categoryLabel;
@property (nonatomic, strong) UIScrollView    *cardsScroll;
@property (nonatomic, strong) NSMutableArray<UIView *> *cards;
@property (nonatomic, strong) UIView          *pageDotsContainer;
@property (nonatomic, strong) NSMutableArray<UIView *> *pageDots;
@property (nonatomic, strong) UIButton        *customizeButton;
@property (nonatomic, strong) UIButton        *plusButton;

// PR-A: one card only. Refactor to dynamic count when multi-screens land.
@property (nonatomic, assign) NSInteger        numCards;
@property (nonatomic, assign) NSInteger        currentIndex;
@end

@implementation LFLockScreenSelector

- (instancetype)initWithCoverSheetView:(UIView *)coverSheetView
                          clockOverlay:(LFClockOverlay *)overlay {
    if ((self = [super init])) {
        _sourceCoverSheet = coverSheetView;
        _clockOverlay     = overlay;
        _numCards         = 1;     // PR-A
        _currentIndex     = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self buildCategoryLabel];
    [self buildCardsScroll];
    [self buildPageDots];
    [self buildBottomBar];
    [self installDismissGesture];
}

#pragma mark - Build

// "PHOTOS" label at the top -- semibold 13pt, white-60%, uppercase
// with subtle letter-spacing. This matches Apple's typography on iOS
// 26 customize sheet header exactly.
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

// Horizontal scroll view holding the cards. Uses fast deceleration so
// the snap behaves like Apple's "page-with-peek" carousel: each card
// is the natural snap point, but the scroll view itself isn't paged
// (paging would only allow one card per viewport, which kills the
// peek illusion). Manual snap in -scrollViewWillEndDragging:.
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
    for (NSInteger i = 0; i < _numCards; i++) {
        UIView *card = [self buildCard];
        [_cardsScroll addSubview:card];
        [_cards addObject:card];
    }
}

// Capture the live lock screen as a STATIC UIImage by rendering every
// visible window's CALayer into one bitmap context in z-order.
//
// Why not -[UIScreen snapshotViewAfterScreenUpdates:] any more?
//
//   The previous build relied on UIScreen's snapshot view, which
//   returns a UIView whose contents are an iOS-private representation
//   of the captured screen. That view works fine when displayed in
//   the same hierarchy it was captured from -- but reparenting it
//   into a completely different container (our card view inside a
//   horizontal UIScrollView) and resizing it via .frame can leave it
//   blank on iOS 15. The user reported "не видно обоев", which is
//   exactly the failure mode of that approach.
//
//   Honest bitmap rendering avoids the issue entirely. We walk every
//   visible UIWindow on UIApplication, render its layer with
//   -renderInContext: into a fresh CGBitmapContext, and end up with
//   a UIImage that's just an array of pixels -- no iOS-private
//   contents, no source-view dependency, no surprise blank frames
//   when displayed in a foreign hierarchy. UIImageView then displays
//   the UIImage at any size we want with a known scale mode.
//
// On SpringBoard the windows array contains (in z-order, lowest to
// highest):
//
//   - SBWallpaperWindow              <- the wallpaper (THIS is what
//                                       was missing from the previous
//                                       cover-sheet-only snapshot)
//   - SBHomeScreenWindow             <- icons (mostly hidden on
//                                       lock screen)
//   - SBCoverSheetWindow             <- the lock-screen UI
//                                       (notifications, time, our
//                                       installed clock overlay)
//   - SBStatusBarWindow              <- status bar
//
// Iterating in z-order with -renderInContext: composites them
// correctly: wallpaper at the bottom, cover sheet (mostly transparent)
// on top showing through to the wallpaper, our clock on top of that.
// Result is exactly what the user sees on screen the moment they
// long-press.
static UIImage *LFCaptureLockScreenImage(void) {
    CGRect screenRect = [UIScreen mainScreen].bounds;
    if (screenRect.size.width < 1.0 || screenRect.size.height < 1.0) {
        return nil;
    }

    UIGraphicsBeginImageContextWithOptions(screenRect.size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    NSArray<UIWindow *> *windows = [[UIApplication sharedApplication] windows];
    for (UIWindow *win in windows) {
        if (win.hidden || win.alpha < 0.01) continue;

        // Apply each window's transform & frame so it lands at the
        // right place in screen space. Most SB windows have an
        // identity transform & full-screen frame, but be defensive --
        // some of them (e.g. status bar in landscape) may have
        // rotation transforms.
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx,
                              CGRectGetMidX(win.frame),
                              CGRectGetMidY(win.frame));
        CGContextConcatCTM(ctx, win.transform);
        CGContextTranslateCTM(ctx,
                              -win.bounds.size.width / 2.0,
                              -win.bounds.size.height / 2.0);
        [win.layer renderInContext:ctx];
        CGContextRestoreGState(ctx);
    }

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// One preview card. Filled with a snapshot of the cover-sheet view,
// rounded with the iOS 26 card radius, and decorated with a Focus
// pill at the bottom. Tapping the card has no action in PR-A but
// bringing the carousel up already lets the user inspect it.
- (UIView *)buildCard {
    UIView *card = [UIView new];
    card.backgroundColor       = [UIColor blackColor];
    card.layer.cornerRadius    = kLFCardCornerRadius;
    card.layer.masksToBounds   = YES;
    card.layer.borderWidth     = kLFCardBorderWidth;
    card.layer.borderColor     =
        [[UIColor colorWithWhite:1.0 alpha:0.08] CGColor];

    // Render the live lock screen to a static UIImage covering ALL
    // visible windows (wallpaper + cover sheet + clock overlay), then
    // display via UIImageView. See LFCaptureLockScreenImage() doc-
    // comment for why we don't use snapshotViewAfterScreenUpdates:
    // any more (it returns a special iOS-private view that goes blank
    // when reparented into a foreign hierarchy on iOS 15).
    UIImage *snapImage = LFCaptureLockScreenImage();
    if (snapImage) {
        UIImageView *snap = [[UIImageView alloc] initWithImage:snapImage];
        snap.tag                     = kLFTagSnapshot;
        snap.userInteractionEnabled  = NO;
        snap.contentMode             = UIViewContentModeScaleAspectFill;
        snap.clipsToBounds           = YES;
        [card addSubview:snap];
    } else {
        // Last-ditch fallback: try the legacy snapshot path. Better
        // to show a degraded card than a totally black one.
        UIView *snap = [[UIScreen mainScreen] snapshotViewAfterScreenUpdates:YES];
        if (!snap) {
            snap = [_sourceCoverSheet snapshotViewAfterScreenUpdates:YES];
        }
        if (snap) {
            snap.tag                = kLFTagSnapshot;
            snap.userInteractionEnabled = NO;
            [card addSubview:snap];
        }
    }

    // Focus pill -- visually 1:1 with iOS 26 (rounded translucent pill,
    // small moon icon + "Focus" label). Not wired to a real Focus mode
    // on iOS 15 (their Focus API is too different from 16+). Future
    // work could mock it as a setting per saved lock screen.
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

    return card;
}

// Page-dots strip below the cards. Hidden when only one card exists
// (matches Apple's behaviour exactly -- no dots for a single page).
- (void)buildPageDots {
    _pageDotsContainer = [UIView new];
    _pageDots          = [NSMutableArray array];
    for (NSInteger i = 0; i < _numCards; i++) {
        UIView *d = [UIView new];
        d.layer.cornerRadius  = kLFPageDotSize / 2.0;
        d.layer.masksToBounds = YES;
        [_pageDotsContainer addSubview:d];
        [_pageDots addObject:d];
    }
    _pageDotsContainer.hidden = (_numCards <= 1);
    [self refreshDotColors];
    [self.view addSubview:_pageDotsContainer];
}

- (void)refreshDotColors {
    for (NSInteger i = 0; i < _pageDots.count; i++) {
        UIView *d = _pageDots[i];
        d.backgroundColor = (i == _currentIndex)
            ? [UIColor whiteColor]
            : [UIColor colorWithWhite:1.0 alpha:0.30];
    }
}

// "Customize" pill on the left, blue "+" circle on the right.
// Colors are matched to iOS 26 system tokens on dark mode:
//   Customize bg = systemGray6 (RGB 28, 28, 30)
//   "+" bg       = systemBlue  (RGB 0, 122, 255)
- (void)buildBottomBar {
    _customizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_customizeButton setTitle:@"Customize" forState:UIControlStateNormal];
    _customizeButton.titleLabel.font =
        [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
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

// Swipe-down to dismiss -- matches the Apple gesture on the customize
// sheet. Tap-on-empty-area also dismisses.
- (void)installDismissGesture {
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
        initWithTarget:self action:@selector(onDismissGesture)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.view addGestureRecognizer:swipe];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGRect b = self.view.bounds;

    // 1) Top "PHOTOS" label, anchored just under the safe-area top.
    _categoryLabel.frame = CGRectMake(0,
                                      safe.top + kLFTopLabelTopMargin,
                                      b.size.width,
                                      kLFTopLabelHeight);

    // 2) Bottom action bar. iOS 26 layout: Customize pill CENTERED,
    //    "+" circle on the right. The Customize button is the visual
    //    anchor of the bar; "+" is auxiliary and inset from the right.
    CGFloat bottomY = b.size.height - safe.bottom -
                      kLFBottomBarMargin - kLFCustomizeBtnH;
    _customizeButton.frame = CGRectMake((b.size.width - kLFCustomizeBtnW) / 2.0,
                                        bottomY,
                                        kLFCustomizeBtnW, kLFCustomizeBtnH);
    _plusButton.frame      = CGRectMake(b.size.width - kLFBottomBarSideInset - kLFPlusBtnSize,
                                        bottomY,
                                        kLFPlusBtnSize, kLFPlusBtnSize);

    // 3) Page dots row (just above the action bar).
    CGFloat dotsTotalW = (CGFloat)_numCards * kLFPageDotSize +
                         (CGFloat)(_numCards - 1) * kLFPageDotSpacing;
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

    // 4) Card geometry. The card matches the DEVICE aspect ratio MINUS
    //    the bottom-crop strip so what the user sees inside the card
    //    is just wallpaper + clock, no home bar / camera / flashlight.
    //    The snapshot view itself is FULL device aspect (so its
    //    contents render at the same scale as the live lock screen),
    //    but it overflows the card's bottom by kLFSnapshotBottomCrop *
    //    scale, and the card's clipsToBounds hides that overflow.
    //
    //    If the aspect-correct height would overflow the available
    //    vertical area, we shrink the card width down so the height
    //    fits -- the carousel still looks correct because aspect is
    //    preserved.
    //
    //    Source dimensions come from UIScreen (not _sourceCoverSheet)
    //    because we snapshot the WHOLE screen now -- the snapshot view
    //    bounds match the screen bounds, so aspect math has to use
    //    screen dimensions to scale the snapshot correctly inside the
    //    card without distortion.
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
        // Aspect-preserving shrink so the card stays a mini-phone.
        cardH = areaH;
        cardW = floor(cardH / cardAspect);
    }

    CGFloat cardY = areaTop + (areaH - cardH) / 2.0;

    // 5) Scroll view spans the FULL viewport width. Side peek is
    //    achieved by making the contentInset half the leftover space
    //    on each side, which centers the first card and naturally
    //    leaves the next/prev cards peeking in.
    _cardsScroll.frame = CGRectMake(0, cardY, b.size.width, cardH);

    CGFloat sideInset = (b.size.width - cardW) / 2.0;
    _cardsScroll.contentInset = UIEdgeInsetsMake(0, sideInset, 0, sideInset);

    // 6) Lay out the actual cards inside the scroll view.
    //
    //    Snap height = full device aspect at cardW (i.e. it represents
    //    the WHOLE lock screen, including the bottom strip we want to
    //    hide). Card height < snap height by exactly the crop, so the
    //    bottom strip falls outside card.bounds and gets clipped.
    CGFloat snapScale = cardW / sourceW;
    CGFloat snapH     = sourceH * snapScale;
    CGFloat x = 0;
    for (NSInteger i = 0; i < _cards.count; i++) {
        UIView *card = _cards[i];
        card.frame = CGRectMake(x, 0, cardW, cardH);
        x += cardW + kLFCardInterSpacing;

        // Card subviews: snapshot fills width (full device aspect),
        // overflows bottom; focus pill anchored above the (visible)
        // card bottom.
        UIView *snap   = [card viewWithTag:kLFTagSnapshot];
        UIView *pill   = [card viewWithTag:kLFTagFocusPill];
        UIImageView *moon = (UIImageView *)[card viewWithTag:kLFTagFocusIcon];
        UILabel *flbl  = (UILabel *)[card viewWithTag:kLFTagFocusLabel];

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

    // Snap to the active card. -sideInset is x=0 of the first card.
    _cardsScroll.contentOffset = CGPointMake(-sideInset +
        _currentIndex * (cardW + kLFCardInterSpacing), 0);
}

#pragma mark - Buttons

- (void)onCustomize {
    // Tell the tweak's gesture target to spawn the editor; we'll
    // animate ourselves out of the way after.
    [self.delegate selectorDidRequestEditor:self];
    [self dismissAnimated];
}

- (void)onPlus {
    // PR-A: multi-lockscreens not implemented yet; show a friendly
    // notice rather than silently doing nothing.
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"New lock screen"
                         message:@"Multiple lock screens are coming in the next update. For now you have a single editable lock screen."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)onDismissGesture {
    [self.delegate selectorDidDismiss:self];
    [self dismissAnimated];
}

- (void)dismissAnimated {
    __weak __typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.25 animations:^{
        weakSelf.view.alpha = 0;
    } completion:^(BOOL ok) {
        [weakSelf.view removeFromSuperview];
    }];
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

#pragma mark - UIScrollViewDelegate (snap + dot sync)

// Snap to the nearest card boundary on deceleration. This is what
// gives the carousel its "click into place" feel like Apple's. Manual
// snap (vs. pagingEnabled) is required because we want side cards to
// peek -- pagingEnabled forces one viewport per page, which would hide
// the peeks.
- (void)scrollViewWillEndDragging:(UIScrollView *)sv
                     withVelocity:(CGPoint)v
              targetContentOffset:(inout CGPoint *)target {
    if (_numCards <= 1) {
        target->x = -sv.contentInset.left;
        return;
    }
    // Card width is whatever was put in the cards on the most recent
    // layout pass -- read it directly so we don't drift if the layout
    // changes (rotation, multitasking).
    CGFloat cardW  = (_cards.count > 0) ? _cards.firstObject.frame.size.width
                                        : sv.bounds.size.width;
    CGFloat stride = cardW + kLFCardInterSpacing;
    CGFloat origin = target->x + sv.contentInset.left;
    NSInteger idx  = (NSInteger)round(origin / stride);
    idx = MAX(0, MIN(_numCards - 1, idx));
    target->x = -sv.contentInset.left + idx * stride;
    _currentIndex = idx;
    [self refreshDotColors];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    [self refreshDotColors];
}

@end
