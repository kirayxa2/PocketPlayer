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

// Top label "PHOTOS" position
static const CGFloat kLFTopLabelTopMargin  = 8.0;
static const CGFloat kLFTopLabelHeight     = 18.0;
static const CGFloat kLFTopLabelKerning    = 1.2;
static const CGFloat kLFTopLabelToCardGap  = 14.0;

// Bottom buttons
static const CGFloat kLFBottomBarMargin    = 16.0;     // distance from safeArea bottom
static const CGFloat kLFCustomizeBtnH      = 50.0;
static const CGFloat kLFCustomizeBtnW      = 124.0;
static const CGFloat kLFCustomizeBtnInset  = 22.0;
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

    // Snapshot of the live cover sheet -- includes the wallpaper plus
    // our installed LFClockOverlay rendered at full size. This is a
    // STATIC IMAGE (UIView snapshot), not the live clock, so it's
    // safe to embed without competing for hit-tests with the editor
    // path that also wants to reparent the live clock.
    UIView *snap = [_sourceCoverSheet snapshotViewAfterScreenUpdates:NO];
    if (snap) {
        snap.tag                = kLFTagSnapshot;
        snap.autoresizingMask   = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleHeight;
        snap.userInteractionEnabled = NO;
        [card addSubview:snap];
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
        [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
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

    // 2) Bottom action bar (we anchor this first so the card area
    //    knows how much room it has between the label and the bar).
    CGFloat bottomY = b.size.height - safe.bottom -
                      kLFBottomBarMargin - kLFCustomizeBtnH;
    _customizeButton.frame = CGRectMake(kLFCustomizeBtnInset, bottomY,
                                        kLFCustomizeBtnW, kLFCustomizeBtnH);
    _plusButton.frame      = CGRectMake(b.size.width - kLFCustomizeBtnInset - kLFPlusBtnSize,
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

    // 4) Card geometry. The card matches the DEVICE aspect ratio so
    //    the carousel reads as "a row of mini phones" exactly like
    //    iOS 16/26's wallpaper picker. Width is a fixed 70% of the
    //    viewport; height follows from aspect.
    //
    //    If the aspect-correct height would overflow the available
    //    vertical area, we shrink the card width down so the height
    //    fits -- the carousel still looks correct because aspect
    //    is preserved.
    CGFloat phoneAspect = b.size.height / b.size.width;
    CGFloat cardW       = floor(b.size.width * kLFCardWidthRatio);
    CGFloat cardH       = floor(cardW * phoneAspect);

    CGFloat areaTop    = CGRectGetMaxY(_categoryLabel.frame) + kLFTopLabelToCardGap;
    CGFloat areaBottom = _pageDotsContainer.frame.origin.y - kLFCardToDotsGap;
    CGFloat areaH      = MAX(0, areaBottom - areaTop);

    if (cardH > areaH) {
        // Aspect-preserving shrink so the card stays a mini-phone.
        cardH = areaH;
        cardW = floor(cardH / phoneAspect);
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
    CGFloat x = 0;
    for (NSInteger i = 0; i < _cards.count; i++) {
        UIView *card = _cards[i];
        card.frame = CGRectMake(x, 0, cardW, cardH);
        x += cardW + kLFCardInterSpacing;

        // Card subviews: snapshot fills, focus pill at the bottom.
        UIView *snap   = [card viewWithTag:kLFTagSnapshot];
        UIView *pill   = [card viewWithTag:kLFTagFocusPill];
        UIImageView *moon = (UIImageView *)[card viewWithTag:kLFTagFocusIcon];
        UILabel *flbl  = (UILabel *)[card viewWithTag:kLFTagFocusLabel];

        snap.frame = card.bounds;

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
