#import "PPImportProgressViewController.h"

@interface PPImportStageRow : UIView
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImageView             *icon;     // ✓ or –
@property (nonatomic, strong) UILabel                 *titleLabel;
@property (nonatomic, strong) UILabel                 *detailLabel;
@property (nonatomic, copy)   NSString                *title;
@end

@implementation PPImportStageRow
- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        _title = [title copy];
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        _spinner.hidesWhenStopped = NO;
        _spinner.hidden = YES;
        [self addSubview:_spinner];

        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            _icon.image = [UIImage systemImageNamed:@"minus"];
            _icon.tintColor = [UIColor tertiaryLabelColor];
        }
        [self addSubview:_icon];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [self addSubview:_titleLabel];

        _detailLabel = [UILabel new];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont systemFontOfSize:13];
        _detailLabel.textColor = [UIColor tertiaryLabelColor];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_spinner.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_spinner.widthAnchor   constraintEqualToConstant:24],
            [_spinner.heightAnchor  constraintEqualToConstant:24],

            [_icon.leadingAnchor    constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_icon.centerYAnchor    constraintEqualToAnchor:self.centerYAnchor],
            [_icon.widthAnchor      constraintEqualToConstant:24],
            [_icon.heightAnchor     constraintEqualToConstant:24],

            [_titleLabel.leadingAnchor   constraintEqualToAnchor:_icon.trailingAnchor constant:14],
            [_titleLabel.centerYAnchor   constraintEqualToAnchor:self.centerYAnchor],

            [_detailLabel.leadingAnchor  constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:8],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_detailLabel.centerYAnchor  constraintEqualToAnchor:self.centerYAnchor],

            [self.heightAnchor      constraintEqualToConstant:34],
        ]];
    }
    return self;
}
- (void)setStateIdle {
    [_spinner stopAnimating];
    _spinner.hidden = YES;
    _icon.hidden = NO;
    if (@available(iOS 13.0, *)) {
        _icon.image = [UIImage systemImageNamed:@"minus"];
        _icon.tintColor = [UIColor tertiaryLabelColor];
    }
    _titleLabel.textColor = [UIColor tertiaryLabelColor];
    _detailLabel.text = @"";
}
- (void)setStateRunning {
    _icon.hidden = YES;
    _spinner.hidden = NO;
    [_spinner startAnimating];
    _titleLabel.textColor = [UIColor labelColor];
}
- (void)setStateDone {
    [_spinner stopAnimating];
    _spinner.hidden = YES;
    _icon.hidden = NO;
    if (@available(iOS 13.0, *)) {
        _icon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        _icon.tintColor = [UIColor systemGreenColor];
    }
    _titleLabel.textColor = [UIColor labelColor];
    _detailLabel.text = @"";
}
- (void)setStateFailed {
    [_spinner stopAnimating];
    _spinner.hidden = YES;
    _icon.hidden = NO;
    if (@available(iOS 13.0, *)) {
        _icon.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
        _icon.tintColor = [UIColor systemRedColor];
    }
    _titleLabel.textColor = [UIColor systemRedColor];
}
@end

@interface PPImportProgressViewController ()
@property (nonatomic, strong) UIView   *card;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) NSArray<PPImportStageRow *> *rows;
@property (nonatomic, strong) NSArray<NSString *>         *stageTitles;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIStackView *buttonsStack;
@property (nonatomic, assign) NSUInteger currentStage;
@property (nonatomic, assign) BOOL completed;
@end

@implementation PPImportProgressViewController

- (instancetype)init {
    return [self initWithStageTitles:@[@"Importing", @"Resizing", @"Done"]];
}

- (instancetype)initWithStageTitles:(NSArray<NSString *> *)stageTitles {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
        _stageTitles = [stageTitles copy];
        _currentStage = 0;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.45];

    _card = [UIView new];
    _card.translatesAutoresizingMaskIntoConstraints = NO;
    _card.backgroundColor = [UIColor systemBackgroundColor];
    _card.layer.cornerRadius = 18;
    _card.layer.shadowColor  = [UIColor.blackColor CGColor];
    _card.layer.shadowOffset = CGSizeMake(0, 8);
    _card.layer.shadowOpacity= 0.18;
    _card.layer.shadowRadius = 20;
    [self.view addSubview:_card];

    _titleLabel = [UILabel new];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = @"Wait please…";
    _titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:_titleLabel];

    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *t in _stageTitles) {
        [rows addObject:[[PPImportStageRow alloc] initWithTitle:t]];
    }
    _rows = rows;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.alignment = UIStackViewAlignmentFill;
    [_card addSubview:stack];

    // Buttons row, hidden until success. Apply | Close.
    _applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_applyButton setTitle:@"Apply now" forState:UIControlStateNormal];
    [_applyButton.titleLabel setFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]];
    [_applyButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _applyButton.backgroundColor = [UIColor systemBlueColor];
    _applyButton.layer.cornerRadius = 10;
    [_applyButton addTarget:self action:@selector(tapApply)
       forControlEvents:UIControlEventTouchUpInside];

    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_closeButton setTitle:@"Close" forState:UIControlStateNormal];
    [_closeButton.titleLabel setFont:[UIFont systemFontOfSize:16]];
    [_closeButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    _closeButton.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _closeButton.layer.cornerRadius = 10;
    [_closeButton addTarget:self action:@selector(tapClose)
       forControlEvents:UIControlEventTouchUpInside];

    _buttonsStack = [[UIStackView alloc] initWithArrangedSubviews:@[_closeButton, _applyButton]];
    _buttonsStack.translatesAutoresizingMaskIntoConstraints = NO;
    _buttonsStack.axis = UILayoutConstraintAxisHorizontal;
    _buttonsStack.distribution = UIStackViewDistributionFillEqually;
    _buttonsStack.spacing = 8;
    _buttonsStack.hidden = YES;
    [_card addSubview:_buttonsStack];

    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor   constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor   constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [_card.widthAnchor     constraintEqualToConstant:280],

        [_titleLabel.topAnchor      constraintEqualToAnchor:_card.topAnchor constant:18],
        [_titleLabel.leadingAnchor  constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],

        [stack.topAnchor       constraintEqualToAnchor:_titleLabel.bottomAnchor constant:18],
        [stack.leadingAnchor   constraintEqualToAnchor:_card.leadingAnchor constant:24],
        [stack.trailingAnchor  constraintEqualToAnchor:_card.trailingAnchor constant:-24],

        [_buttonsStack.topAnchor      constraintEqualToAnchor:stack.bottomAnchor constant:18],
        [_buttonsStack.leadingAnchor  constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_buttonsStack.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],
        [_buttonsStack.heightAnchor   constraintEqualToConstant:44],
        [_buttonsStack.bottomAnchor   constraintEqualToAnchor:_card.bottomAnchor constant:-18],
    ]];

    // Start: stage 0 running, others idle.
    if (_rows.count > 0) [_rows.firstObject setStateRunning];
    for (NSUInteger i = 1; i < _rows.count; i++) {
        [_rows[i] setStateIdle];
    }
}

- (void)updateCurrentStageDetail:(NSString *)detail {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateCurrentStageDetail:detail]; });
        return;
    }
    if (_currentStage >= _rows.count) return;
    _rows[_currentStage].detailLabel.text = detail ?: @"";
}

- (void)finishCurrentStage {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishCurrentStage]; });
        return;
    }
    if (_completed) return;
    if (_currentStage >= _rows.count) return;

    [_rows[_currentStage] setStateDone];
    if (_currentStage + 1 < _rows.count) {
        _currentStage++;
        [_rows[_currentStage] setStateRunning];
        return;
    }

    // Last stage just finished. Show Apply button.
    _completed = YES;
    [UIView animateWithDuration:0.25 animations:^{
        self.buttonsStack.hidden = NO;
        self.titleLabel.text = @"Ready";
    }];
    if (self.completion) self.completion();
}

- (void)failWithMessage:(NSString *)message {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self failWithMessage:message]; });
        return;
    }
    if (_currentStage < _rows.count) {
        [_rows[_currentStage] setStateFailed];
    }
    if (message.length) self.titleLabel.text = message;
    _completed = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)tapApply {
    // Block the buttons while the apply path runs so the user doesn't
    // mash them. The caller is responsible for calling
    // -dismissAfterApplying when it's done.
    self.applyButton.enabled = NO;
    self.closeButton.enabled = NO;
    self.titleLabel.text = @"Applying…";
    if (self.applyHandler) self.applyHandler();
}

- (void)tapClose {
    if (self.closeHandler) self.closeHandler();
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dismissAfterApplying {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dismissAfterApplying]; });
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
