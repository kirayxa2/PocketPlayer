#import "PPImportProgressViewController.h"

@interface PPImportStageRow : UIView
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImageView             *icon;     // ✓ or –
@property (nonatomic, strong) UILabel                 *label;
@property (nonatomic, copy)   NSString                *title;
@end

@implementation PPImportStageRow
- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super initWithFrame:CGRectZero])) {
        _title = [title copy];
        self.translatesAutoresizingMaskIntoConstraints = NO;

        // Container that holds (icon|spinner) on the left, label on the right.
        _spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        _spinner.hidesWhenStopped = NO;
        _spinner.hidden = YES;
        [self addSubview:_spinner];

        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.tintColor = [UIColor secondaryLabelColor];
        _icon.contentMode = UIViewContentModeCenter;
        if (@available(iOS 13.0, *)) {
            // U+2014 em-dash visually centered in the icon slot.
            _icon.image = [UIImage systemImageNamed:@"minus"];
            _icon.tintColor = [UIColor tertiaryLabelColor];
        }
        [self addSubview:_icon];

        _label = [UILabel new];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.text = title;
        _label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        _label.textColor = [UIColor secondaryLabelColor];
        [self addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [_spinner.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_spinner.widthAnchor   constraintEqualToConstant:24],
            [_spinner.heightAnchor  constraintEqualToConstant:24],

            [_icon.leadingAnchor    constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_icon.centerYAnchor    constraintEqualToAnchor:self.centerYAnchor],
            [_icon.widthAnchor      constraintEqualToConstant:24],
            [_icon.heightAnchor     constraintEqualToConstant:24],

            [_label.leadingAnchor   constraintEqualToAnchor:_icon.trailingAnchor constant:14],
            [_label.trailingAnchor  constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_label.centerYAnchor   constraintEqualToAnchor:self.centerYAnchor],

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
    _label.textColor = [UIColor tertiaryLabelColor];
}
- (void)setStateRunning {
    _icon.hidden = YES;
    _spinner.hidden = NO;
    [_spinner startAnimating];
    _label.textColor = [UIColor labelColor];
}
- (void)setStateDone {
    [_spinner stopAnimating];
    _spinner.hidden = YES;
    _icon.hidden = NO;
    if (@available(iOS 13.0, *)) {
        _icon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        _icon.tintColor = [UIColor systemGreenColor];
    }
    _label.textColor = [UIColor labelColor];
}
- (void)setStateFailed {
    [_spinner stopAnimating];
    _spinner.hidden = YES;
    _icon.hidden = NO;
    if (@available(iOS 13.0, *)) {
        _icon.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
        _icon.tintColor = [UIColor systemRedColor];
    }
    _label.textColor = [UIColor systemRedColor];
}
@end

@interface PPImportProgressViewController ()
@property (nonatomic, strong) UIView   *card;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) NSArray<PPImportStageRow *> *rows;
@property (nonatomic, assign) PPImportStage currentStage;
@property (nonatomic, assign) BOOL completed;
@end

@implementation PPImportProgressViewController

- (instancetype)init {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
        _currentStage = PPImportStageImporting;
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

    PPImportStageRow *r1 = [[PPImportStageRow alloc] initWithTitle:@"Importing"];
    PPImportStageRow *r2 = [[PPImportStageRow alloc] initWithTitle:@"Resizing"];
    PPImportStageRow *r3 = [[PPImportStageRow alloc] initWithTitle:@"Done"];
    _rows = @[r1, r2, r3];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:_rows];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.alignment = UIStackViewAlignmentFill;
    [_card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [_card.centerXAnchor   constraintEqualToAnchor:self.view.centerXAnchor],
        [_card.centerYAnchor   constraintEqualToAnchor:self.view.centerYAnchor constant:-30],
        [_card.widthAnchor     constraintEqualToConstant:240],

        [_titleLabel.topAnchor      constraintEqualToAnchor:_card.topAnchor constant:18],
        [_titleLabel.leadingAnchor  constraintEqualToAnchor:_card.leadingAnchor constant:18],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-18],

        [stack.topAnchor       constraintEqualToAnchor:_titleLabel.bottomAnchor constant:18],
        [stack.leadingAnchor   constraintEqualToAnchor:_card.leadingAnchor constant:24],
        [stack.trailingAnchor  constraintEqualToAnchor:_card.trailingAnchor constant:-24],
        [stack.bottomAnchor    constraintEqualToAnchor:_card.bottomAnchor constant:-22],
    ]];

    // Start: stage 0 running, others idle.
    [r1 setStateRunning];
    [r2 setStateIdle];
    [r3 setStateIdle];
}

- (void)finishCurrentStage {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishCurrentStage]; });
        return;
    }
    if (_completed) return;
    if (_currentStage >= self.rows.count) return;

    [self.rows[_currentStage] setStateDone];
    if (_currentStage + 1 < self.rows.count) {
        _currentStage++;
        [self.rows[_currentStage] setStateRunning];
    } else {
        // All stages complete.
        _completed = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self dismissViewControllerAnimated:YES completion:^{
                if (self.completion) self.completion();
            }];
        });
    }
}

- (void)failWithMessage:(NSString *)message {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self failWithMessage:message]; });
        return;
    }
    if (_currentStage < self.rows.count) {
        [self.rows[_currentStage] setStateFailed];
    }
    if (message.length) self.titleLabel.text = message;
    _completed = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

@end
