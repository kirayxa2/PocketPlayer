#import "LFLockEditor.h"
#import "LFClockOverlay.h"
#import "LFClockSettings.h"
#import "LFLockScreenWidgetTray.h"
#import "LFLockScreenWidgetPicker.h"
#import "LFLockScreenWidgetCatalog.h"
#import "LFStocksClient.h"

// =====================================================================
// LFPassthroughView -- transparent container for the editor.
//
// Earlier in the project's life this class forwarded touches through
// to the cover-sheet underneath (via -hitTest: returning nil) because
// the clock lived in the cover-sheet and we needed its drag-resize
// gestures to keep working from inside the editor's overlay.
//
// Now the clock is REPARENTED into the editor's view in
// -presentInWindow:, so every editor-mode interaction (tap, drag-
// resize) hit-tests through this view directly. We keep the class
// for symmetry with the rest of the file, but it's a plain UIView
// today -- there's no longer any pass-through behaviour.
// =====================================================================
@interface LFPassthroughView : UIView
@end
@implementation LFPassthroughView
@end

// Layout constants for the editor's bottom panel. iOS 16/26 customize
// sheet density: 64pt-tall font row, 48pt color dot row, 40pt slider
// row. Total content sits inside ~16pt vertical padding -- the
// overall panel height is computed in viewDidLayoutSubviews because
// safeAreaInsets.bottom isn't known at compile time.
//
// The font row Y-origin is now offset by `kLFPanelTopPad` so the row
// sits BELOW the close-X button at the panel's top-right corner --
// without that offset the picker cells overlap the X visually and
// catch touches meant for it.
static const CGFloat kLFFontRowHeight   = 64;
static const CGFloat kLFColorRowHeight  = 48;
static const CGFloat kLFSliderRowHeight = 40;
static const CGFloat kLFPanelTopPad     = 50;  // leaves room for the close-X
static const CGFloat kLFPanelBotPad     = 16;  // breathing room above safe area
// (Top bar removed earlier -- the editor uses a small close-X on
// the bottom panel instead, matching iOS 16/26's customize sheet.
// Alignment row removed in this pass: iOS 16/26 lock-screen clocks
// are always centred; the row served no purpose and just made the
// panel taller than necessary.)

@interface LFLockEditor () <UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate, UITextFieldDelegate, LFLockScreenWidgetTrayDelegate>
@property (nonatomic, weak)   LFClockOverlay      *clockOverlay;
@property (nonatomic, weak)   UIView              *clockOriginalParent;  // remember home for re-parenting on dismiss
@property (nonatomic, strong) UIVisualEffectView  *dimmer;       // covers wallpaper
// Compact close button -- small "x" pill at the top-right of the
// bottom panel. Replaces the old top bar with Cancel / Done; tapping
// it saves and dismisses (no separate Cancel anymore). Lives INSIDE
// the bottom panel so it slides in/out together with the rest of
// the customize sheet.
@property (nonatomic, strong) UIButton            *closeButton;
@property (nonatomic, strong) UIView              *bottomPanel;
@property (nonatomic, strong) UIVisualEffectView  *bottomPanelBlur;
@property (nonatomic, strong) UICollectionView    *fontPickerRow;
@property (nonatomic, strong) UICollectionView    *colorPickerRow;
@property (nonatomic, strong) UIButton            *glassToggleButton;
@property (nonatomic, strong) UIButton            *solidToggleButton;
@property (nonatomic, strong) UIView              *modeToggleContainer;
// Date editing. Tapping the date pill in the editor flips
// activeTarget to LFEditorTargetDate and the bottom panel re-lays
// itself to show:
//   - the same Font + Color rows (font/color are shared between
//     time and date in this iteration; per-element fonts can be a
//     follow-up PR)
//   - a Date Widget picker (4 cells: Date / Battery / Day / Custom)
//   - a Custom Text field, only visible when the picker selects
//     LFDateWidgetCustomText
//
// Tapping the clock body flips it back to LFEditorTargetClock and
// the panel re-lays to show the Glass/Solid toggle in place of the
// widget picker + text field.
@property (nonatomic, assign) NSInteger            activeTarget;     // 0 = Clock, 1 = Date
@property (nonatomic, strong) UICollectionView    *dateWidgetPickerRow;
@property (nonatomic, strong) UITextField         *customTextField;
@property (nonatomic, strong) UILabel             *targetTitleLabel;
// iOS 16/26 customize-sheet behaviour: the bottom panel is HIDDEN
// when the editor first appears (just selection rect + handle on
// the clock). Tapping the clock toggles the panel up/down. Tapping
// outside the clock and the panel either slides the panel down (if
// up) or dismisses the editor entirely (if already down). This
// state mirrors the panel's current on-screen position.
@property (nonatomic) BOOL   bottomPanelVisible;
@property (nonatomic) CGFloat panelHeight;            // recomputed each layout pass
// Tap recognizers stored as properties so the gesture-recognizer
// delegate can compare against them by identity (not just class) --
// we want VERY specific behaviour for clock-tap vs outside-tap, see
// gestureRecognizerShouldBegin:.
@property (nonatomic, copy)   NSArray<LFLockScreenWidgetDescriptor *> *inlineDescriptors;
@property (nonatomic, strong) UITapGestureRecognizer *clockTap;
@property (nonatomic, strong) UITapGestureRecognizer *outsideTap;
- (void)promptForStocksSymbol;
@end

#define kLFEditorTargetClock  0
#define kLFEditorTargetDate   1

@implementation LFLockEditor

- (instancetype)initWithClockOverlay:(LFClockOverlay *)clockOverlay {
    self = [super init];
    if (!self) return nil;
    _clockOverlay = clockOverlay;
    return self;
}

// Override loadView so the root view is our passthrough class instead
// of a plain UIView. Without this, all touches to the empty middle
// area get absorbed by the editor's root and never reach the clock.
- (void)loadView {
    LFPassthroughView *root = [[LFPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    // Build the inline-descriptor list ONCE for use by the date-pill
    // picker row. Drawn from the central catalog so adding a new
    // inline widget kind shows up here automatically without editor-
    // side code changes.
    NSMutableArray *inl = [NSMutableArray array];
    for (LFLockScreenWidgetDescriptor *d in [LFLockScreenWidgetCatalog allDescriptors]) {
        for (NSNumber *n in d.supportedFamilies) {
            if ([n integerValue] == LFWidgetFamilyInline) {
                [inl addObject:d];
                break;
            }
        }
    }
    _inlineDescriptors = inl;

    [self buildDimmer];
    [self buildBottomPanel];
}

#pragma mark - Setup

- (void)buildDimmer {
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _dimmer = [[UIVisualEffectView alloc] initWithEffect:eff];
    _dimmer.frame = self.view.bounds;
    _dimmer.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                               UIViewAutoresizingFlexibleHeight;
    // CRITICAL: dimmer is just a visual treatment. We must not let it
    // catch any touches, otherwise it eats every drag aimed at the
    // clock under us. With this off, touches on the dimmer fall
    // through to the passthrough root, which forwards them to the
    // cover-sheet view containing the clock.
    _dimmer.userInteractionEnabled = NO;
    [self.view addSubview:_dimmer];
}

// Small "x" close button -- replaces the old Cancel/Done top bar.
// Anchored at the top-right corner of the bottom panel; tapping it
// saves all current settings and dismisses the editor (no separate
// Cancel anymore -- everything is live-saved on close). Lives as a
// subview of `_bottomPanel` so it slides in/out together with the
// rest of the customize sheet -- when the panel is hidden, the X is
// hidden too.
- (void)buildCloseButton {
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
        UIImage *xmark = [UIImage systemImageNamed:@"xmark.circle.fill"
                                 withConfiguration:cfg];
        [_closeButton setImage:xmark forState:UIControlStateNormal];
    } else {
        [_closeButton setTitle:@"Close" forState:UIControlStateNormal];
        [_closeButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    }
    // Translucent grey circle, matches the iOS 16 sheet-close glyph
    // (white-25% on the symbol's filled background).
    _closeButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    [_closeButton addTarget:self
                     action:@selector(onClose)
           forControlEvents:UIControlEventTouchUpInside];
    [_bottomPanel addSubview:_closeButton];
}

- (void)buildBottomPanel {
    _bottomPanel = [UIView new];
    [self.view addSubview:_bottomPanel];

    // Translucent panel base. Liquid-Glass-ish (matches the editor
    // sheet on iOS 26 visually).
    UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark];
    _bottomPanelBlur = [[UIVisualEffectView alloc] initWithEffect:eff];
    _bottomPanelBlur.layer.cornerRadius = 32;
    _bottomPanelBlur.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _bottomPanelBlur.layer.masksToBounds = YES;
    [_bottomPanel addSubview:_bottomPanelBlur];

    [self buildCloseButton];
    [self buildTargetTitle];
    [self buildFontRow];
    [self buildColorRow];
    [self buildModeToggle];
    [self buildDateWidgetPicker];
    [self buildCustomTextField];
}

// Small label at top-left of the panel showing what the user is
// currently editing -- "CLOCK" or "DATE". Same kerning/style as
// "PHOTOS" in the carousel header so the editor visually echoes
// the selector. Updated every time activeTarget changes.
- (void)buildTargetTitle {
    _targetTitleLabel = [UILabel new];
    _targetTitleLabel.textAlignment = NSTextAlignmentLeft;
    _targetTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _targetTitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    [_bottomPanel addSubview:_targetTitleLabel];
    [self refreshTargetTitle];
}

- (void)refreshTargetTitle {
    NSDictionary *attrs = @{
        NSKernAttributeName: @(1.2),
        NSFontAttributeName: _targetTitleLabel.font,
        NSForegroundColorAttributeName: _targetTitleLabel.textColor,
    };
    NSString *txt = (_activeTarget == kLFEditorTargetDate) ? @"DATE" : @"CLOCK";
    _targetTitleLabel.attributedText = [[NSAttributedString alloc]
        initWithString:txt attributes:attrs];
}

- (void)buildFontRow {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize        = CGSizeMake(56, 56);
    layout.minimumLineSpacing = 12;
    layout.sectionInset    = UIEdgeInsetsMake(0, 16, 0, 16);

    _fontPickerRow = [[UICollectionView alloc] initWithFrame:CGRectZero
                                        collectionViewLayout:layout];
    _fontPickerRow.backgroundColor = [UIColor clearColor];
    _fontPickerRow.dataSource      = self;
    _fontPickerRow.delegate        = self;
    _fontPickerRow.showsHorizontalScrollIndicator = NO;
    _fontPickerRow.tag = 1;
    [_fontPickerRow registerClass:[UICollectionViewCell class]
       forCellWithReuseIdentifier:@"font"];
    [_bottomPanel addSubview:_fontPickerRow];
}

- (void)buildColorRow {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize        = CGSizeMake(40, 40);
    layout.minimumLineSpacing = 12;
    layout.sectionInset    = UIEdgeInsetsMake(0, 16, 0, 16);

    _colorPickerRow = [[UICollectionView alloc] initWithFrame:CGRectZero
                                         collectionViewLayout:layout];
    _colorPickerRow.backgroundColor = [UIColor clearColor];
    _colorPickerRow.dataSource      = self;
    _colorPickerRow.delegate        = self;
    _colorPickerRow.showsHorizontalScrollIndicator = NO;
    _colorPickerRow.tag = 2;
    [_colorPickerRow registerClass:[UICollectionViewCell class]
        forCellWithReuseIdentifier:@"color"];
    [_bottomPanel addSubview:_colorPickerRow];
}

// iOS 26 segmented Glass/Solid toggle. Replaces the previous 0..3
// liquidGlassIntensity slider, which the user found ugly and which
// wasn't really matching iOS 26's mode-style switching anyway.
//
// Two modes:
//   Glass: liquidGlassIntensity = 2 (medium-strength Liquid Glass
//          backdrop on the time digits -- translucent blurred panel
//          with subtle rim and specular highlight, the iOS 26 look)
//   Solid: liquidGlassIntensity = 0 (no glass, digits render flat
//          in their picked color; clearest most-readable mode)
//
// Visually it's a single dark pill with two segments inside; the
// active segment gets a brighter "selected" pill, the inactive one
// stays subtly dimmed. Same dimensions as a row of pickers above
// (~40pt tall, full bar width minus side margin).
- (void)buildModeToggle {
    _modeToggleContainer                       = [UIView new];
    _modeToggleContainer.backgroundColor       = [UIColor colorWithWhite:0.0 alpha:0.30];
    _modeToggleContainer.layer.cornerRadius    = 14;
    _modeToggleContainer.layer.masksToBounds   = YES;
    [_bottomPanel addSubview:_modeToggleContainer];

    _glassToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_glassToggleButton setTitle:@"Glass" forState:UIControlStateNormal];
    _glassToggleButton.titleLabel.font =
        [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_glassToggleButton addTarget:self action:@selector(onGlassMode)
                 forControlEvents:UIControlEventTouchUpInside];
    [_modeToggleContainer addSubview:_glassToggleButton];

    _solidToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_solidToggleButton setTitle:@"Solid" forState:UIControlStateNormal];
    _solidToggleButton.titleLabel.font =
        [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_solidToggleButton addTarget:self action:@selector(onSolidMode)
                 forControlEvents:UIControlEventTouchUpInside];
    [_modeToggleContainer addSubview:_solidToggleButton];

    [self refreshModeToggleSelection];
}

// Date Widget picker -- horizontal scroll row of 4 pill cells: Date /
// Battery / Day / Custom. Active cell gets a brighter pill backdrop
// like the clock-target font row. Tapping a cell mutates
// LFClockSettings.dateWidget and tells the clock overlay to refresh,
// so the date pill on screen updates instantly.
- (void)buildDateWidgetPicker {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection      = UICollectionViewScrollDirectionHorizontal;
    layout.itemSize             = CGSizeMake(96, 40);
    layout.minimumLineSpacing   = 10;
    layout.sectionInset         = UIEdgeInsetsMake(0, 16, 0, 16);

    _dateWidgetPickerRow = [[UICollectionView alloc] initWithFrame:CGRectZero
                                              collectionViewLayout:layout];
    _dateWidgetPickerRow.backgroundColor = [UIColor clearColor];
    _dateWidgetPickerRow.dataSource      = self;
    _dateWidgetPickerRow.delegate        = self;
    _dateWidgetPickerRow.showsHorizontalScrollIndicator = NO;
    _dateWidgetPickerRow.tag             = 3;
    [_dateWidgetPickerRow registerClass:[UICollectionViewCell class]
             forCellWithReuseIdentifier:@"dateWidget"];
    [_bottomPanel addSubview:_dateWidgetPickerRow];
    _dateWidgetPickerRow.hidden = YES;
}

// Plain UITextField used to edit LFClockSettings.dateCustomText. Only
// visible when the active target is Date AND the selected widget is
// LFDateWidgetCustomText. Live-updates the settings on every
// editingChanged event so the user sees the text appear in the date
// pill while they type.
- (void)buildCustomTextField {
    _customTextField = [UITextField new];
    _customTextField.delegate         = self;
    _customTextField.placeholder      = @"Custom date text…";
    _customTextField.font             = [UIFont systemFontOfSize:15];
    _customTextField.textColor        = [UIColor whiteColor];
    _customTextField.tintColor        = [UIColor whiteColor];
    _customTextField.backgroundColor  = [UIColor colorWithWhite:0.0 alpha:0.30];
    _customTextField.layer.cornerRadius  = 10;
    _customTextField.layer.masksToBounds = YES;
    _customTextField.returnKeyType    = UIReturnKeyDone;
    _customTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    // Inset the editable area a bit so the text doesn't kiss the
    // rounded edge.
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 0)];
    _customTextField.leftView         = spacer;
    _customTextField.leftViewMode     = UITextFieldViewModeAlways;
    _customTextField.rightView        = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 0)];
    _customTextField.rightViewMode    = UITextFieldViewModeAlways;
    [_customTextField addTarget:self
                         action:@selector(onCustomTextChanged)
               forControlEvents:UIControlEventEditingChanged];
    [_bottomPanel addSubview:_customTextField];
    _customTextField.hidden = YES;
    _customTextField.text = [LFClockSettings shared].dateCustomText ?: @"";
}

- (void)onCustomTextChanged {
    NSString *t = _customTextField.text ?: @"";
    LFClockSettings *s = [LFClockSettings shared];
    s.dateCustomText = t;                                  // legacy field
    s.dateInlineConfig = @{ @"text": t };                  // canonical field
    [_clockOverlay refreshFromSettings];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

// Refresh visual state of the Glass / Solid toggle so it matches the
// current LFClockSettings.liquidGlassIntensity. Called from
// onGlassMode / onSolidMode and during initial setup.
- (void)refreshModeToggleSelection {
    BOOL isGlass = ([LFClockSettings shared].liquidGlassIntensity > 0);
    UIColor *active   = [UIColor colorWithWhite:1.0 alpha:0.90];
    UIColor *inactive = [UIColor colorWithWhite:1.0 alpha:0.45];
    [_glassToggleButton setTitleColor:(isGlass ? active : inactive)
                             forState:UIControlStateNormal];
    [_solidToggleButton setTitleColor:(isGlass ? inactive : active)
                             forState:UIControlStateNormal];
    // Selected-segment background pill that highlights the active
    // mode. We layer it as a sibling backdrop INSIDE the toggle
    // container, frame-animated by viewDidLayoutSubviews on each
    // refresh.
    static const NSInteger kModeBackdropTag = 0xB10B;
    UIView *backdrop = [_modeToggleContainer viewWithTag:kModeBackdropTag];
    if (!backdrop) {
        backdrop                       = [UIView new];
        backdrop.tag                   = kModeBackdropTag;
        backdrop.backgroundColor       = [UIColor colorWithWhite:1.0 alpha:0.18];
        backdrop.layer.cornerRadius    = 11;
        backdrop.layer.masksToBounds   = YES;
        backdrop.userInteractionEnabled = NO;
        [_modeToggleContainer insertSubview:backdrop atIndex:0];
    }
    [self.view setNeedsLayout];
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;

    // Visibility based on activeTarget. Clock target shows the Glass/
    // Solid mode toggle; Date target shows the date-widget picker
    // and (conditionally) the custom-text field. Font + Color rows
    // are shared across both targets.
    BOOL isDate = (_activeTarget == kLFEditorTargetDate);
    LFWidgetKind inlineKind = [LFClockSettings shared].dateInlineKind;
    BOOL needsCustomField = (isDate && inlineKind == LFWidgetKindCustomText);

    _modeToggleContainer.hidden  = isDate;
    _dateWidgetPickerRow.hidden  = !isDate;
    _customTextField.hidden      = !needsCustomField;

    // Total panel height: top pad (room for close-X) + target title +
    // font + color + (mode-toggle | date-widget-picker) + (custom-text
    // field?) + bottom pad + safe-area inset.
    CGFloat panelH = kLFPanelTopPad + kLFFontRowHeight + kLFColorRowHeight +
                     kLFSliderRowHeight + kLFPanelBotPad + safe.bottom;
    if (needsCustomField) panelH += 50.0;          // text field row
    _panelHeight = panelH;

    // Panel position: at the screen bottom when visible, fully OFF
    // the bottom edge when hidden. Both states are laid out by frame
    // (no transform) so child layout stays simple.
    CGFloat panelY = _bottomPanelVisible
        ? (self.view.bounds.size.height - panelH)
        : self.view.bounds.size.height;
    _bottomPanel.frame = CGRectMake(0,
                                    panelY,
                                    self.view.bounds.size.width,
                                    panelH);
    _bottomPanelBlur.frame = _bottomPanel.bounds;

    // Close X: 30pt circle at top-right of the panel, 12pt margin.
    // Lives inside _bottomPanel now, so its position is in panel
    // coordinates -- it slides with the panel automatically.
    const CGFloat closeSize = 30.0;
    _closeButton.frame = CGRectMake(self.view.bounds.size.width - 12 - closeSize,
                                    12,
                                    closeSize, closeSize);

    // Target title at top-left, vertically centred against the close
    // button so they sit on the same baseline.
    _targetTitleLabel.frame = CGRectMake(20,
                                         12 + (closeSize - 18) / 2.0,
                                         140, 18);

    // Picker rows. Font row starts BELOW the close-X (kLFPanelTopPad
    // = 50pt = 12pt top inset + 30pt button + 8pt gap) so its cells
    // never overlap the X visually or steal touches from it.
    CGFloat y = kLFPanelTopPad;
    _fontPickerRow.frame  = CGRectMake(0, y, self.view.bounds.size.width, kLFFontRowHeight);
    y += kLFFontRowHeight;
    _colorPickerRow.frame = CGRectMake(0, y, self.view.bounds.size.width, kLFColorRowHeight);
    y += kLFColorRowHeight;

    if (isDate) {
        // Date widget picker takes the slot the mode-toggle would in
        // clock mode. Same height so panel total stays predictable.
        _dateWidgetPickerRow.frame = CGRectMake(0, y, self.view.bounds.size.width, kLFSliderRowHeight);
        y += kLFSliderRowHeight;
        if (needsCustomField) {
            // Custom text field below the picker. 12pt side margins
            // to match the picker section insets.
            _customTextField.frame = CGRectMake(20, y + 6,
                                                self.view.bounds.size.width - 40,
                                                38);
            y += 50.0;
        }
    } else {
        // Mode toggle (Glass / Solid) -- replaces the old liquidGlass
        // slider. Centered horizontally inside the panel with comfortable
        // side margins, ~40pt tall. The selected-segment backdrop pill
        // animates between the two halves so taps feel instant.
        const CGFloat kToggleSideMargin = 32.0;
        const CGFloat kToggleH          = 36.0;
        CGFloat toggleW = self.view.bounds.size.width - 2 * kToggleSideMargin;
        if (toggleW < 120) toggleW = 120;
        _modeToggleContainer.frame = CGRectMake(kToggleSideMargin,
                                                y + (kLFSliderRowHeight - kToggleH) / 2.0,
                                                toggleW, kToggleH);
        CGFloat halfW = toggleW / 2.0;
        _glassToggleButton.frame = CGRectMake(0,        0, halfW, kToggleH);
        _solidToggleButton.frame = CGRectMake(halfW,    0, halfW, kToggleH);

        // Selected-segment backdrop pill: 4pt inset on all sides, slides
        // to the active half. We update its frame inline with the layout
        // pass so the panel slide-up animation carries the backdrop
        // smoothly with it.
        UIView *backdrop = [_modeToggleContainer viewWithTag:0xB10B];
        if (backdrop) {
            const CGFloat inset = 4.0;
            BOOL isGlass = ([LFClockSettings shared].liquidGlassIntensity > 0);
            CGFloat bx = isGlass ? inset : (halfW + inset);
            backdrop.frame = CGRectMake(bx, inset,
                                        halfW - 2 * inset, kToggleH - 2 * inset);
        }
    }
}

#pragma mark - Bottom panel show / hide

// iOS 16/26-style customize-sheet animation: the bottom panel slides
// up from below the screen when the clock is tapped, and slides back
// down when the user taps anywhere outside it. We tween via
// -setNeedsLayout + UIView animation so the layout pass handles the
// frame change, keeping all subview positions correct relative to the
// panel's current bounds without us having to maintain a transform.
- (void)setBottomPanelVisible:(BOOL)visible animated:(BOOL)animated {
    if (_bottomPanelVisible == visible) return;
    _bottomPanelVisible = visible;

    // iOS 26: per-tile minus buttons are visible only while the
    // bottom customize-panel is up. Push the flag down to the tray
    // immediately (before the animation) so the appearance change
    // animates in sync with the panel sliding up/down.
    UIView *trayV = _clockOverlay.widgetTray;
    if ([trayV respondsToSelector:@selector(setBottomPanelOpen:)]) {
        ((LFLockScreenWidgetTray *)trayV).bottomPanelOpen = visible;
    }

    [self.view setNeedsLayout];
    if (animated) {
        // Spring damping 0.9 / no initial velocity is the same curve
        // Apple uses for sheet-up/-down on iOS 16, soft and quick.
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            [self.view layoutIfNeeded];
        }
                         completion:nil];
    } else {
        [self.view layoutIfNeeded];
    }
}

#pragma mark - Tap recognizers

- (void)installEditorTapRecognizers {
    // Tap on the clock toggles the customize sheet up/down. Lives on
    // the clock overlay so it observes touches anywhere inside its
    // bounds (including the resize handle, where a tap with no drag
    // doesn't trigger a resize and so falls through here).
    _clockTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onClockTap:)];
    _clockTap.delegate = self;
    [_clockOverlay addGestureRecognizer:_clockTap];

    // Tap anywhere ELSE in the editor view (the dimmer area, in
    // practice). gestureRecognizerShouldBegin: filters out taps that
    // land inside the clock overlay or inside the bottom panel, so
    // this recognizer only ever fires on TRULY outside taps.
    _outsideTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onOutsideTap:)];
    _outsideTap.delegate = self;
    [self.view addGestureRecognizer:_outsideTap];
}

// Tap on the clock: bring the customize sheet up if it's down,
// otherwise hide it again. Same finger affordance as iOS 16's editor
// where tapping a widget toggles its option sheet.
//
// We also discriminate WHICH element the user tapped: a tap inside
// the date-pill region switches the editor's active target to Date
// and re-lays the bottom panel for date editing; any other tap
// switches back to Clock target. Apple's iOS 16/26 customize sheet
// does the same.
- (void)onClockTap:(UITapGestureRecognizer *)tap {
    NSInteger newTarget = kLFEditorTargetClock;
    CGPoint p = [tap locationInView:_clockOverlay];
    CGRect dateRect = _clockOverlay.datePillFrameInOverlayCoords;
    if (!CGRectIsEmpty(dateRect) && CGRectContainsPoint(dateRect, p)) {
        newTarget = kLFEditorTargetDate;
    }

    if (newTarget != _activeTarget) {
        _activeTarget = newTarget;
        [self refreshTargetTitle];
        // If we just switched into custom-text mode, prefill the
        // text field with the saved string so the user can edit
        // rather than retyping.
        _customTextField.text = [LFClockSettings shared].dateCustomText ?: @"";
        // Bottom panel will re-lay (visibility, panel height) on
        // next layout pass triggered by the toggle below.
        [self.view setNeedsLayout];
        // Always SHOW the panel when switching target -- a target
        // switch is an explicit "I want to edit this" signal, not a
        // toggle. Without this, the second tap on a different
        // element would just hide the panel again.
        if (!_bottomPanelVisible) {
            [self setBottomPanelVisible:YES animated:YES];
        } else {
            // Same visible state, but layout has changed -- animate
            // the height/content swap nicely.
            [UIView animateWithDuration:0.25 animations:^{
                [self.view layoutIfNeeded];
            }];
            // Reload pickers so the new target's selected indices
            // light up.
            [_fontPickerRow reloadData];
            [_colorPickerRow reloadData];
            [_dateWidgetPickerRow reloadData];
        }
        return;
    }
    [self setBottomPanelVisible:!_bottomPanelVisible animated:YES];
}

// Tap on the dimmer / empty area:
//   - if the panel is UP   -> slide it down (one-step retreat)
//   - if the panel is DOWN -> dismiss the editor (no other close
//                              affordance is on screen at this point)
- (void)onOutsideTap:(UITapGestureRecognizer *)tap {
    if (_bottomPanelVisible) {
        [self setBottomPanelVisible:NO animated:YES];
    } else {
        [self onClose];
    }
}

#pragma mark - UIGestureRecognizerDelegate

// Filter outsideTap so it ONLY fires for taps that land in the
// dimmer (i.e. neither in the clock overlay nor in the bottom panel).
// Without this filter, taps inside the panel's empty regions would
// fall through and close it; and a tap on the clock could race
// against clockTap, causing the panel to flash up-then-immediately-
// down on a single touch.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == _outsideTap) {
        CGPoint p = [g locationInView:self.view];
        if (CGRectContainsPoint(_bottomPanel.frame, p))   return NO;
        if (CGRectContainsPoint(_clockOverlay.frame, p))  return NO;
    }
    return YES;
}

// Tap+tap MUST NOT recognize simultaneously: clockTap and
// outsideTap on the same touch sequence would toggle the panel
// twice in a single tap (visible -> hidden -> visible) which
// looks like the panel "flashes". Tap+pan IS allowed (so the
// clock-tap can coexist with the resize handle's pan recognizer).
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    BOOL gIsTap = [g     isKindOfClass:[UITapGestureRecognizer class]];
    BOOL oIsTap = [other isKindOfClass:[UITapGestureRecognizer class]];
    if (gIsTap && oIsTap) return NO;
    return YES;
}

#pragma mark - Buttons

// Single close button -- saves all changes and dismisses the editor.
// (No separate Cancel: every settings change is written to memory
// live as the user toys with the pickers, and persisted to disk on
// dismiss. To revert the user re-edits.)
- (void)onClose {
    [[LFClockSettings shared] save];
    [self dismissEditor];
}

- (void)dismissEditor {
    _clockOverlay.isEditing = NO;

    // Detach ourselves from the widget tray so it stops calling our
    // picker handlers after we've animated away. The tray itself
    // stays in the cover-sheet view tree to render the live widgets;
    // its `isEditing` flips to NO via clockOverlay.isEditing setter.
    UIView *trayCandidate = _clockOverlay.widgetTray;
    if ([trayCandidate isKindOfClass:[LFLockScreenWidgetTray class]]) {
        LFLockScreenWidgetTray *tray = (LFLockScreenWidgetTray *)trayCandidate;
        if (tray.delegate == (id)self) tray.delegate = nil;
    }

    __weak __typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.25 animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL ok) {
        __strong __typeof(weakSelf) self_ = weakSelf;
        if (!self_) return;

        // Put the clock back in its original parent (cover-sheet view)
        // so the lockscreen continues to display it after we're gone.
        // Convert center first so it stays put visually.
        if (self_.clockOverlay && self_.clockOriginalParent) {
            UIWindow *win = self_.view.window;
            CGPoint centerInWindow = [self_.view convertPoint:self_.clockOverlay.center
                                                       toView:win];
            CGPoint centerInOrig   = [self_.clockOriginalParent convertPoint:centerInWindow
                                                                    fromView:win];
            [self_.clockOriginalParent addSubview:self_.clockOverlay];
            self_.clockOverlay.center = centerInOrig;
        }

        [self_.view removeFromSuperview];
        // Tell the tweak's gesture handler we're gone so the next
        // long-press spawns a fresh editor (bug-1 fix).
        id<LFLockEditorDelegate> d = self_.delegate;
        if ([d respondsToSelector:@selector(lockEditorDidDismiss:)]) {
            [d lockEditorDidDismiss:self_];
        }
    }];
}

- (void)onGlassMode {
    if ([LFClockSettings shared].liquidGlassIntensity > 0) return;
    // Glass on: pick intensity 2 (medium) -- this matches the iOS 26
    // default Liquid Glass strength on the lock-screen clock face,
    // visible blur with a subtle rim and specular highlight without
    // being heavy. The user can tweak the underlying intensity int
    // through the plist if they really want intensity 1 or 3, but
    // the editor only exposes the binary on/off via the toggle.
    [LFClockSettings shared].liquidGlassIntensity = 2;
    [self refreshModeToggleSelection];
    [_clockOverlay refreshFromSettings];
}

- (void)onSolidMode {
    if ([LFClockSettings shared].liquidGlassIntensity == 0) return;
    [LFClockSettings shared].liquidGlassIntensity = 0;
    [self refreshModeToggleSelection];
    [_clockOverlay refreshFromSettings];
}

#pragma mark - Presentation

- (void)presentInWindow:(UIWindow *)window {
    self.view.frame = window.bounds;
    self.view.alpha = 0;
    [window addSubview:self.view];

    // Move the clock INTO our view, on top of the dimmer, so the user
    // sees it crisp (not behind the dim) AND so its touches go through
    // our editor view directly without competing for hit-tests with
    // the cover-sheet underneath. Saved location remembered so we can
    // put it back when the editor closes.
    _clockOriginalParent = _clockOverlay.superview;
    if (_clockOverlay && _clockOriginalParent) {
        // Convert center to our view's coordinate space first so the
        // clock doesn't visually jump on the reparent.
        CGPoint centerInWindow = [_clockOriginalParent convertPoint:_clockOverlay.center
                                                              toView:window];
        CGPoint centerInUs     = [self.view convertPoint:centerInWindow fromView:window];
        [self.view addSubview:_clockOverlay];     // also removes from old superview
        _clockOverlay.center = centerInUs;
        // The bottom panel + close button must be above the clock
        // for chrome; the clock itself stays above the dimmer.
        [self.view bringSubviewToFront:_clockOverlay];
        [self.view bringSubviewToFront:_bottomPanel];
    }

    // Customize sheet starts HIDDEN -- the editor first reveals just
    // the clock with its selection rect + resize handle, exactly the
    // iOS 16/26 entrance state. The user taps the clock to bring up
    // font / colour / glass options.
    _bottomPanelVisible = NO;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];

    // Editor-level tap recognizers: clock-tap (toggle sheet) and
    // outside-tap (hide sheet, then dismiss). Installed AFTER the
    // clock has been re-parented so the recognizer is attached to
    // the right view instance.
    [self installEditorTapRecognizers];

    _clockOverlay.isEditing = YES;

    // Wire ourselves as the widget tray's delegate. The tray was
    // created lazily by the clock overlay and lives in the cover-
    // sheet's view tree (not inside our editor view), but the editor
    // is the right place to handle picker presentation since the
    // alert/UIViewController API needs a presenter.
    UIView *trayCandidate = _clockOverlay.widgetTray;
    if ([trayCandidate isKindOfClass:[LFLockScreenWidgetTray class]]) {
        LFLockScreenWidgetTray *tray = (LFLockScreenWidgetTray *)trayCandidate;
        tray.delegate  = self;
        tray.isEditing = YES;
    }

    [UIView animateWithDuration:0.25 animations:^{
        self.view.alpha = 1;
    }];
}

#pragma mark - UICollectionViewDataSource / Delegate

- (NSInteger)collectionView:(UICollectionView *)cv
     numberOfItemsInSection:(NSInteger)section {
    if (cv.tag == 1) return LFClockFontCount;
    if (cv.tag == 2) return LFClockColorModeCount;
    if (cv.tag == 3) return _inlineDescriptors.count;
    return 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)idx {
    if (cv.tag == 1) {
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"font"
                                                                   forIndexPath:idx];
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

        UILabel *aa = [UILabel new];
        aa.text          = @"Aa";
        aa.textAlignment = NSTextAlignmentCenter;
        aa.textColor     = [UIColor whiteColor];
        aa.frame         = cell.contentView.bounds;
        aa.font          = [self previewFontForIndex:idx.item];
        [cell.contentView addSubview:aa];

        BOOL selected = (idx.item == [LFClockSettings shared].font);
        cell.contentView.layer.borderColor =
            (selected ? [[UIColor whiteColor] CGColor]
                      : [[UIColor colorWithWhite:1.0 alpha:0.18] CGColor]);
        cell.contentView.layer.borderWidth  = selected ? 2.0 : 1.0;
        cell.contentView.layer.cornerRadius = 16;
        return cell;
    }
    if (cv.tag == 2) {
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"color"
                                                                   forIndexPath:idx];
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
        UIView *dot = [[UIView alloc] initWithFrame:cell.contentView.bounds];
        dot.layer.cornerRadius = cell.contentView.bounds.size.width / 2.0;
        dot.layer.masksToBounds = YES;
        dot.backgroundColor = [self previewColorForIndex:idx.item];
        // Adaptive: show as gradient half-white, half-black.
        if (idx.item == LFClockColorAdaptive) {
            CAGradientLayer *g = [CAGradientLayer layer];
            g.frame = dot.bounds;
            g.colors = @[ (id)[UIColor whiteColor].CGColor,
                          (id)[UIColor blackColor].CGColor ];
            g.startPoint = CGPointMake(0, 0);
            g.endPoint   = CGPointMake(1, 1);
            [dot.layer addSublayer:g];
            dot.backgroundColor = [UIColor clearColor];
        }
        [cell.contentView addSubview:dot];
        BOOL selected = (idx.item == [LFClockSettings shared].colorMode);
        cell.contentView.layer.borderColor =
            (selected ? [[UIColor whiteColor] CGColor]
                      : [[UIColor clearColor] CGColor]);
        cell.contentView.layer.borderWidth  = selected ? 2.0 : 0.0;
        cell.contentView.layer.cornerRadius = cell.contentView.bounds.size.width / 2.0;
        return cell;
    }
    if (cv.tag == 3) {
        UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"dateWidget"
                                                                   forIndexPath:idx];
        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

        // Cells now mirror the iOS 26 inline picker: each cell shows
        // a small SF Symbol icon next to the descriptor display name.
        // Selected cell is highlighted with the same chrome treatment
        // the legacy enum-based picker used.
        LFLockScreenWidgetDescriptor *d = _inlineDescriptors[idx.item];

        UIImageView *iv = [UIImageView new];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.tintColor   = [UIColor whiteColor];
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
            iv.image = [UIImage systemImageNamed:d.sfSymbolName
                              withConfiguration:cfg];
        }
        iv.frame = CGRectMake(8, (cell.contentView.bounds.size.height - 16) / 2.0, 16, 16);
        [cell.contentView addSubview:iv];

        UILabel *lab = [UILabel new];
        lab.text          = d.displayName;
        lab.font          = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.textColor     = [UIColor whiteColor];
        lab.frame         = CGRectMake(28, 0, cell.contentView.bounds.size.width - 36, cell.contentView.bounds.size.height);
        [cell.contentView addSubview:lab];

        BOOL selected = ((LFWidgetKind)d.kind == [LFClockSettings shared].dateInlineKind);
        cell.contentView.backgroundColor =
            selected ? [UIColor colorWithWhite:1.0 alpha:0.18]
                     : [UIColor colorWithWhite:0.0 alpha:0.30];
        cell.contentView.layer.cornerRadius  = 13;
        cell.contentView.layer.masksToBounds = YES;
        cell.contentView.layer.borderColor =
            (selected ? [[UIColor colorWithWhite:1.0 alpha:0.60] CGColor]
                      : [[UIColor clearColor] CGColor]);
        cell.contentView.layer.borderWidth  = selected ? 1.0 : 0.0;
        return cell;
    }
    return [UICollectionViewCell new];
}

// Per-cell display strings for the inline-kind picker now come from
// catalog descriptors (`LFLockScreenWidgetCatalog allDescriptors`),
// not a hardcoded switch -- adding a new inline kind to the catalog
// shows up here automatically. The legacy +dateWidgetTitleForIndex:
// helper used for the 4-value LFDateWidget enum has been retired.

- (void)collectionView:(UICollectionView *)cv
didSelectItemAtIndexPath:(NSIndexPath *)idx {
    if (cv.tag == 1) {
        [LFClockSettings shared].font = (LFClockFont)idx.item;
    } else if (cv.tag == 2) {
        [LFClockSettings shared].colorMode = (LFClockColorMode)idx.item;
    } else if (cv.tag == 3) {
        // Inline picker: write to dateInlineKind, preserve any
        // existing config dict where it makes sense (e.g. user re-
        // selecting CustomText shouldn't clear their saved string,
        // user re-selecting Stocks shouldn't clear their ticker).
        LFLockScreenWidgetDescriptor *d = _inlineDescriptors[idx.item];
        LFClockSettings *s = [LFClockSettings shared];
        s.dateInlineKind = d.kind;
        if (d.kind != LFWidgetKindCustomText &&
            d.kind != LFWidgetKindStocksInline) {
            s.dateInlineConfig = @{};
        }
        // Keep the legacy dateWidget enum loosely in sync so older
        // tweak builds rollback-loaded against this plist still see
        // a sensible value.
        switch (d.kind) {
            case LFWidgetKindBatteryInline:   s.dateWidget = LFDateWidgetBattery;     break;
            case LFWidgetKindDayCounter:      s.dateWidget = LFDateWidgetDayCounter;  break;
            case LFWidgetKindCustomText:      s.dateWidget = LFDateWidgetCustomText;  break;
            default:                          s.dateWidget = LFDateWidgetDate;        break;
        }

        // Layout pass so the custom-text field appears/disappears
        // depending on the new kind.
        [self.view setNeedsLayout];
        [UIView animateWithDuration:0.20 animations:^{
            [self.view layoutIfNeeded];
        }];
        // Pre-fill the field with the saved text so the user can
        // edit on entry rather than retyping.
        if (d.kind == LFWidgetKindCustomText) {
            _customTextField.text =
                ([LFClockSettings shared].dateInlineConfig[@"text"]
                 ?: [LFClockSettings shared].dateCustomText) ?: @"";
        }

        // Stocks needs a symbol; surface a prompt as soon as the
        // user picks the kind so the inline pill stops showing the
        // bare "STOCKS" placeholder. The user can re-tap the pill
        // and re-pick Stocks later to change the ticker.
        if (d.kind == LFWidgetKindStocksInline) {
            [self promptForStocksSymbol];
        }
    }
    [_clockOverlay refreshFromSettings];
    [cv reloadData];
}

#pragma mark - Helpers

- (UIFont *)previewFontForIndex:(NSInteger)i {
    LFClockFont saved = [LFClockSettings shared].font;
    [LFClockSettings shared].font = (LFClockFont)i;
    UIFont *f = [[LFClockSettings shared] resolvedFontForReferenceSize:24];
    [LFClockSettings shared].font = saved;
    return f;
}

- (UIColor *)previewColorForIndex:(NSInteger)i {
    LFClockColorMode saved = [LFClockSettings shared].colorMode;
    [LFClockSettings shared].colorMode = (LFClockColorMode)i;
    UIColor *c = [[LFClockSettings shared] resolvedColorForBackgroundLuminance:nil];
    [LFClockSettings shared].colorMode = saved;
    return c;
}

// UIAlertController-based ticker prompt for the Stocks inline widget.
// Looks like Apple's iOS 26 "Edit Widget" sheet for Stocks: a single
// text field pre-filled with the saved symbol (or "AAPL" first time),
// Cancel / Done buttons. We accept anything LFStocksClient can
// normalise -- so users can type "$msft" / "MSFT" / "msft " and we
// store "MSFT". Empty input cancels. On Done we kick the network
// fetch immediately so the inline pill can refresh on the next tick
// with real data instead of "AAPL —".
- (void)promptForStocksSymbol {
    NSString *current =
        [LFClockSettings shared].dateInlineConfig[@"symbol"];
    if (![current isKindOfClass:[NSString class]] || current.length == 0) {
        current = @"AAPL";
    }
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Stock Ticker"
                         message:@"Enter a ticker symbol (e.g. AAPL, MSFT, BRK.B, ^GSPC)"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder            = @"AAPL";
        tf.text                   = current;
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType     = UITextAutocorrectionTypeNo;
        tf.spellCheckingType      = UITextSpellCheckingTypeNo;
        tf.returnKeyType          = UIReturnKeyDone;
        tf.clearButtonMode        = UITextFieldViewModeWhileEditing;
    }];
    __weak __typeof(self) wself = self;
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Done"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *act) {
        UITextField *tf = wa.textFields.firstObject;
        NSString *sym   = [LFStocksClient normalizedSymbol:tf.text];
        if (!sym) return;
        LFClockSettings *s = [LFClockSettings shared];
        // Merge into existing config so we don't drop unrelated keys
        // a future update might add to the Stocks dict.
        NSMutableDictionary *m =
            [(s.dateInlineConfig ?: @{}) mutableCopy];
        m[@"symbol"] = sym;
        s.dateInlineConfig = m;
        // Force-fetch immediately (ignores 5-min TTL) so the user
        // sees a real price within seconds instead of waiting for
        // the next minute-tick to trigger a stale-aware refresh.
        [[LFStocksClient shared] refreshIfStaleForSymbol:sym
                                                   force:YES
                                              completion:^(LFStockQuote *q,
                                                            NSError *err) {
            __strong __typeof(wself) sself = wself;
            [sself.clockOverlay refreshFromSettings];
        }];
        [wself.clockOverlay refreshFromSettings];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - LFLockScreenWidgetTrayDelegate

// Tray asks us to present the picker. We instantiate
// LFLockScreenWidgetPicker, present it modally over our own view, and
// on completion call back into the tray + persist settings.
- (void)trayDidRequestPicker:(LFLockScreenWidgetTray *)tray
                       family:(LFWidgetFamily)family {
    __weak __typeof(self) ws = self;
    LFLockScreenWidgetPicker *picker = [[LFLockScreenWidgetPicker alloc]
        initForFamily:family
            completion:^(LFWidgetKind kind, LFWidgetFamily fam, NSDictionary *cfg) {
        __strong __typeof(self) ss = ws;
        if (!ss || !cfg) return;     // user cancelled
        BOOL ok = [tray addWidgetWithKind:kind family:fam config:cfg];
        if (ok) {
            // Persist to settings.traySlots so the layout survives a
            // SpringBoard respawn. -trayDidUpdateContents: also fires
            // when an internal slot is removed; we re-serialize there
            // too.
            [LFClockSettings shared].traySlots = [tray serializedSlots];
            [[LFClockSettings shared] save];
        } else {
            // Tray refused (capacity exceeded). Friendly inline
            // explanation; a heavy modal alert would be overkill.
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Tray Full"
                                 message:@"There's no room for that widget. Remove an existing one first."
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
            [ss presentViewController:a animated:YES completion:nil];
        }
    }];
    [picker presentFromViewController:self];
}

- (void)trayDidUpdateContents:(LFLockScreenWidgetTray *)tray {
    [LFClockSettings shared].traySlots = [tray serializedSlots];
    [[LFClockSettings shared] save];
}

// User pan'd the tray vertically. iOS 26 lets the user drag the
// tray with the finger (live follow now -- the tray's own
// onDragPan moves its frame in real time during the gesture). At
// release we snap to the nearest of two valid positions:
//
//   * UnderClock -- right beneath the clock-overlay's frame.
//                   ONLY available while the clock is at minimum
//                   vStretch=1.0; if the user is currently in a
//                   stretched-clock state and drops the tray
//                   close to the clock, we ALSO shrink the clock
//                   back to vStretch=1.0 so the tray + clock fit
//                   together cleanly. This is the "widgets stick
//                   to the clock and the clock politely shrinks
//                   to its minimum to make room" behaviour.
//
//   * AtBottom   -- pinned above the camera/flashlight strip
//                   (~110pt above safe-area bottom).
//
// We pick which one based on the tray's CURRENT frame.y after the
// finger lifts -- whichever target Y is closer wins. The tray's
// own onDragPan has already moved the frame to wherever the
// finger ended; we just decide UnderClock vs AtBottom and
// re-anchor via clockOverlay.refreshFromSettings.
- (void)tray:(LFLockScreenWidgetTray *)tray
   didDragWithTranslationY:(CGFloat)dy
                     ended:(BOOL)ended {
    if (!ended) return;

    // Compute target Y for each candidate position so we can
    // pick the closest one to where the finger actually let go.
    UIView *parent = tray.superview;
    if (!parent) return;

    CGFloat parentH    = parent.bounds.size.height;
    UIEdgeInsets safe  = parent.safeAreaInsets;
    CGFloat trayH      = tray.bounds.size.height;
    CGFloat finalY     = tray.frame.origin.y;

    CGFloat targetUnder  = CGRectGetMaxY(_clockOverlay.frame) + 12.0;
    CGFloat targetBottom = parentH - safe.bottom - 110.0 - trayH;

    LFTrayPosition want = (fabs(finalY - targetUnder) <
                           fabs(finalY - targetBottom))
        ? LFTrayPositionUnderClock
        : LFTrayPositionAtBottom;

    // If the user wants UnderClock but the clock is currently
    // stretched, shrink it back to minimum so the tray actually
    // FITS under the (now shorter) clock. Animate the change so
    // the clock visibly recoils up while the tray slides into
    // its new home.
    BOOL needShrink = (want == LFTrayPositionUnderClock &&
                       [LFClockSettings shared].verticalStretch > 1.001);
    if (needShrink) {
        [LFClockSettings shared].verticalStretch = 1.0;
    }

    [LFClockSettings shared].trayPosition = want;
    [[LFClockSettings shared] save];

    // Animate the result so the tray's snap and (optional) clock
    // shrink read as a coherent gesture rather than two independent
    // teleports.
    [UIView animateWithDuration:0.32
                          delay:0
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [_clockOverlay refreshFromSettings];
    }
                     completion:nil];
}

@end
