#import "LFWidgetCalendar.h"
#import <EventKit/EventKit.h>

@interface LFWidgetCalendar () {
    UILabel    *_topLabel;        // "12:30" or "TODAY"
    UILabel    *_botLabel;        // event title (rectangular only)
    UIView     *_calColorDot;
    NSTimer    *_pollTimer;
    EKEventStore *_eventStore;
    BOOL        _accessRequested;
    BOOL        _accessGranted;
}
@end

@implementation LFWidgetCalendar

- (instancetype)initWithKind:(LFWidgetKind)kind
                      family:(LFWidgetFamily)family
                      config:(NSDictionary *)config {
    self = [super initWithKind:kind family:family config:config];
    if (!self) return nil;
    [self setupSubviewsForFamily:family];

    _eventStore = [EKEventStore new];
    EKAuthorizationStatus s = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
    _accessGranted   = (s == EKAuthorizationStatusAuthorized);
    _accessRequested = (s != EKAuthorizationStatusNotDetermined);
    if (!_accessRequested) {
        __weak typeof(self) weakSelf = self;
        [_eventStore requestAccessToEntityType:EKEntityTypeEvent
                                    completion:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) self_ = weakSelf;
                if (!self_) return;
                self_->_accessRequested = YES;
                self_->_accessGranted   = granted;
                [self_ refreshContent];
            });
        }];
    }

    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                 repeats:YES
                                                   block:^(NSTimer *_) {
        [weakSelf refreshContent];
    }];

    [self refreshContent];
    return self;
}

- (void)dealloc { [_pollTimer invalidate]; }

- (NSTimeInterval)preferredRefreshInterval { return 60.0; }

- (void)setupSubviewsForFamily:(LFWidgetFamily)family {
    [self installGlassBackdrop];

    _topLabel              = [UILabel new];
    _topLabel.textAlignment = NSTextAlignmentCenter;
    _topLabel.textColor    = [UIColor whiteColor];
    [self addSubview:_topLabel];

    if (family == LFWidgetFamilyRectangular) {
        _calColorDot                       = [UIView new];
        _calColorDot.layer.cornerRadius    = 4;
        _calColorDot.layer.masksToBounds   = YES;
        [self addSubview:_calColorDot];

        _botLabel              = [UILabel new];
        _botLabel.textColor    = [UIColor colorWithWhite:1.0 alpha:0.75];
        _botLabel.font         = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        _botLabel.numberOfLines = 1;
        [self addSubview:_botLabel];

        _topLabel.textAlignment = NSTextAlignmentLeft;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (self.family == LFWidgetFamilyCircular) {
        _topLabel.frame = self.bounds;
        _topLabel.font  = [LFLockScreenWidget systemFontOfSize:14
                                                        weight:UIFontWeightHeavy];
        _topLabel.numberOfLines = 2;
    } else {
        _calColorDot.frame = CGRectMake(10, 14, 8, 8);
        _topLabel.frame    = CGRectMake(24, 6,  b.size.width - 32, 24);
        _topLabel.font     = [LFLockScreenWidget systemFontOfSize:16
                                                           weight:UIFontWeightHeavy];
        _topLabel.textAlignment = NSTextAlignmentLeft;
        _botLabel.frame    = CGRectMake(10, 36, b.size.width - 20, 32);
        _botLabel.numberOfLines = 2;
    }
}

- (void)refreshContent {
    if (!_accessGranted) {
        _topLabel.text = @"CAL OFF";
        if (_botLabel) _botLabel.text = @"Permission denied";
        _calColorDot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        return;
    }
    NSDate *now    = [NSDate date];
    NSDate *until  = [now dateByAddingTimeInterval:24 * 3600];
    NSPredicate *p = [_eventStore predicateForEventsWithStartDate:now
                                                          endDate:until
                                                        calendars:nil];
    NSArray<EKEvent *> *events = [_eventStore eventsMatchingPredicate:p];
    EKEvent *next = [events firstObject];

    if (!next) {
        _topLabel.text = @"NO EVENTS";
        if (_botLabel) _botLabel.text = @"Today is clear";
        _calColorDot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
        return;
    }

    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"h:mm a";

    if (self.family == LFWidgetFamilyCircular) {
        // 2-line: "12:30\nPM" if today, or "TOM\n9:00 AM" if tomorrow.
        NSCalendar *cal = [NSCalendar currentCalendar];
        BOOL isTomorrow = ![cal isDateInToday:next.startDate];
        if (isTomorrow) {
            _topLabel.text = [NSString stringWithFormat:@"TOM\n%@",
                              [fmt stringFromDate:next.startDate]];
        } else {
            _topLabel.text = [fmt stringFromDate:next.startDate];
        }
    } else {
        _topLabel.text = next.title.length ? next.title : @"Untitled";
        if (_botLabel) {
            NSString *start = [fmt stringFromDate:next.startDate];
            NSString *end   = [fmt stringFromDate:next.endDate];
            _botLabel.text = [NSString stringWithFormat:@"%@ - %@", start, end];
        }
        UIColor *c = [UIColor colorWithCGColor:next.calendar.CGColor];
        _calColorDot.backgroundColor = c ?: [UIColor systemBlueColor];
    }
}

@end
