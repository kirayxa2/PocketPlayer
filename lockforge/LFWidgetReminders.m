#import "LFWidgetReminders.h"
#import <EventKit/EventKit.h>

@interface LFWidgetReminders () {
    UILabel    *_countLabel;
    UILabel    *_titleLabel;
    EKEventStore *_store;
    BOOL        _accessGranted;
}
@end

@implementation LFWidgetReminders

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self installGlassBackdrop];

    _countLabel              = [UILabel new];
    _countLabel.textColor    = [UIColor whiteColor];
    _countLabel.textAlignment = NSTextAlignmentCenter;
    _countLabel.font = [LFLockScreenWidget systemFontOfSize:22
                                                     weight:UIFontWeightHeavy];
    [self addSubview:_countLabel];

    _titleLabel              = [UILabel new];
    _titleLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.55];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.font = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
    _titleLabel.text = @"DUE TODAY";
    [self addSubview:_titleLabel];

    _store = [EKEventStore new];
    EKAuthorizationStatus s = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
    _accessGranted = (s == EKAuthorizationStatusAuthorized);
    if (s == EKAuthorizationStatusNotDetermined) {
        __weak typeof(self) weakSelf = self;
        [_store requestAccessToEntityType:EKEntityTypeReminder
                               completion:^(BOOL granted, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) self_ = weakSelf;
                if (!self_) return;
                self_->_accessGranted = granted;
                [self_ refreshContent];
            });
        }];
    }
    [self refreshContent];
    return self;
}

- (NSTimeInterval)preferredRefreshInterval { return 5.0 * 60.0; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _countLabel.frame = CGRectMake(0, b.size.height/2 - 18, b.size.width, 28);
    _titleLabel.frame = CGRectMake(0, b.size.height/2 + 12, b.size.width, 10);
}

- (void)refreshContent {
    if (!_accessGranted) {
        _countLabel.text = @"—";
        _titleLabel.text = @"REMINDERS";
        return;
    }
    NSDate *now = [NSDate date];
    // End-of-day = midnight of tomorrow. Computed via startOfDayForDate
    // (iOS 8+) plus a 1-day calendar component, which handles DST
    // transitions cleanly. Avoids the older variadic
    // -nextDateAfterDate:matchingHour:... signature whose spelling
    // varies between SDK versions.
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *one = [NSDateComponents new];
    one.day = 1;
    NSDate *endOfToday = [cal dateByAddingComponents:one
                                              toDate:[cal startOfDayForDate:now]
                                             options:0];
    NSPredicate *p = [_store predicateForIncompleteRemindersWithDueDateStarting:nil
                                                                          ending:endOfToday
                                                                       calendars:nil];
    [_store fetchRemindersMatchingPredicate:p completion:^(NSArray<EKReminder *> *items) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_countLabel.text = [NSString stringWithFormat:@"%lu",
                                      (unsigned long)items.count];
            self->_titleLabel.text = items.count == 1 ? @"DUE TODAY" : @"DUE TODAY";
        });
    }];
}

@end
