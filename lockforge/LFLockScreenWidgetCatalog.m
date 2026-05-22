#import "LFLockScreenWidgetCatalog.h"

// Each widget header is imported here so the registry can construct
// instances. Kept in the same lockforge/ folder so Theos packages them
// without subdir gymnastics.
#import "LFWidgetBattery.h"
#import "LFWidgetWeather.h"
#import "LFWidgetMusic.h"
#import "LFWidgetCalendar.h"
#import "LFWidgetMoonPhase.h"
#import "LFWidgetSteps.h"
#import "LFWidgetWorldClock.h"
#import "LFWidgetReminders.h"
#import "LFWidgetInline.h"

@implementation LFLockScreenWidgetCatalog

// Helper that builds a descriptor in one expression -- keeps the
// +allDescriptors body readable as a flat list.
static LFLockScreenWidgetDescriptor *desc(LFWidgetKind k,
                                          NSString *appName,
                                          NSString *displayName,
                                          NSString *symbol,
                                          NSArray *families,
                                          BOOL suggested) {
    LFLockScreenWidgetDescriptor *d = [LFLockScreenWidgetDescriptor new];
    d.kind               = k;
    d.appName            = appName;
    d.displayName        = displayName;
    d.sfSymbolName       = symbol;
    d.supportedFamilies  = families;
    d.isSuggested        = suggested;
    return d;
}

+ (NSArray<LFLockScreenWidgetDescriptor *> *)allDescriptors {
    static NSArray *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *circ      = @[ @(LFWidgetFamilyCircular) ];
        NSArray *rect      = @[ @(LFWidgetFamilyRectangular) ];
        NSArray *circRect  = @[ @(LFWidgetFamilyCircular), @(LFWidgetFamilyRectangular) ];
        NSArray *inline_   = @[ @(LFWidgetFamilyInline) ];

        all = @[
            // ─── Date-pill (inline) options shown when the user taps
            // the date in edit mode. Apple's iOS 26 inline picker has
            // ~10 options; we cover the same surface where the data
            // is reachable from iOS 15 system APIs.
            desc(LFWidgetKindDate,            @"Date",      @"Date",            @"calendar",                inline_,  YES),
            desc(LFWidgetKindWeatherInline,   @"Weather",   @"Conditions",      @"sun.max.fill",            inline_,  YES),
            desc(LFWidgetKindBatteryInline,   @"Battery",   @"Battery",         @"battery.100",             inline_,  YES),
            desc(LFWidgetKindCalendarInline,  @"Calendar",  @"Next Event",      @"calendar.badge.clock",    inline_,  NO),
            desc(LFWidgetKindRemindersInline, @"Reminders", @"Next Reminder",   @"checklist",               inline_,  NO),
            desc(LFWidgetKindActivityInline,  @"Fitness",   @"Activity",        @"figure.walk",             inline_,  NO),
            desc(LFWidgetKindStocksInline,    @"Stocks",    @"Ticker",          @"chart.line.uptrend.xyaxis",inline_, NO),
            desc(LFWidgetKindAppleTVInline,   @"TV",        @"Now Playing",     @"tv.fill",                 inline_,  NO),
            desc(LFWidgetKindSportsInline,    @"Sports",    @"Game",            @"sportscourt.fill",        inline_,  NO),
            desc(LFWidgetKindDayCounter,      @"Day",       @"Day Counter",     @"number.square.fill",      inline_,  NO),
            desc(LFWidgetKindCustomText,      @"Custom",    @"Custom Text",     @"textformat",              inline_,  NO),

            // ─── Below-clock widget tray options ──
            desc(LFWidgetKindBattery,         @"Battery",   @"Battery",         @"battery.75",              circRect, YES),
            desc(LFWidgetKindWeather,         @"Weather",   @"Conditions",      @"cloud.sun.fill",          circRect, YES),
            desc(LFWidgetKindMusic,           @"Music",     @"Now Playing",     @"music.note",              circRect, YES),
            desc(LFWidgetKindCalendar,        @"Calendar",  @"Up Next",         @"calendar",                circRect, NO),
            desc(LFWidgetKindReminders,       @"Reminders", @"Reminders",       @"checklist",               circ,     NO),
            desc(LFWidgetKindMoonPhase,       @"Astronomy", @"Moon Phase",      @"moon.fill",               circ,     NO),
            desc(LFWidgetKindSteps,           @"Fitness",   @"Steps",           @"figure.walk",             circ,     NO),
            desc(LFWidgetKindWorldClock,      @"Clock",     @"World Clock",     @"globe",                   circ,     NO),
            desc(LFWidgetKindWeatherForecast, @"Weather",   @"Forecast",        @"cloud.sun.rain.fill",     rect,     NO),
            desc(LFWidgetKindNowPlayingDetail,@"Music",     @"Now Playing",     @"play.rectangle.fill",     rect,     NO),
            desc(LFWidgetKindNextEvent,       @"Calendar",  @"Next Event",      @"calendar.badge.clock",    rect,     NO),
        ];
    });
    return all;
}

+ (NSArray<LFLockScreenWidgetDescriptor *> *)suggestedDescriptors {
    NSMutableArray *r = [NSMutableArray array];
    for (LFLockScreenWidgetDescriptor *d in [self allDescriptors]) {
        if (d.isSuggested) [r addObject:d];
    }
    return r;
}

+ (LFLockScreenWidgetDescriptor *)descriptorForKind:(LFWidgetKind)kind {
    for (LFLockScreenWidgetDescriptor *d in [self allDescriptors]) {
        if (d.kind == kind) return d;
    }
    return nil;
}

+ (NSString *)appGroupNameForKind:(LFWidgetKind)kind {
    LFLockScreenWidgetDescriptor *d = [self descriptorForKind:kind];
    return d.appName ?: @"Other";
}

+ (LFLockScreenWidget *)createWidgetForKind:(LFWidgetKind)kind
                                     family:(LFWidgetFamily)family
                                     config:(NSDictionary *)config {
    LFLockScreenWidgetDescriptor *d = [self descriptorForKind:kind];
    if (!d) return nil;
    BOOL ok = NO;
    for (NSNumber *n in d.supportedFamilies) {
        if ([n integerValue] == family) { ok = YES; break; }
    }
    if (!ok) return nil;

    Class cls = nil;
    switch (kind) {
        // Below-clock tray widgets:
        case LFWidgetKindBattery:           cls = [LFWidgetBattery        class]; break;
        case LFWidgetKindWeather:           cls = [LFWidgetWeather        class]; break;
        case LFWidgetKindMusic:             cls = [LFWidgetMusic          class]; break;
        case LFWidgetKindCalendar:          cls = [LFWidgetCalendar       class]; break;
        case LFWidgetKindMoonPhase:         cls = [LFWidgetMoonPhase      class]; break;
        case LFWidgetKindSteps:             cls = [LFWidgetSteps          class]; break;
        case LFWidgetKindWorldClock:        cls = [LFWidgetWorldClock     class]; break;
        case LFWidgetKindReminders:         cls = [LFWidgetReminders      class]; break;
        case LFWidgetKindWeatherForecast:   cls = [LFWidgetWeather        class]; break;
        case LFWidgetKindNowPlayingDetail:  cls = [LFWidgetMusic          class]; break;
        case LFWidgetKindNextEvent:         cls = [LFWidgetCalendar       class]; break;

        // Inline widgets all share one renderer that handles the variety
        // of single-line content shapes (text-only, text+symbol,
        // text+chevron). Cheap to share since inline content is just a
        // string + maybe an SF Symbol.
        case LFWidgetKindDate:
        case LFWidgetKindDayCounter:
        case LFWidgetKindCustomText:
        case LFWidgetKindWeatherInline:
        case LFWidgetKindBatteryInline:
        case LFWidgetKindCalendarInline:
        case LFWidgetKindRemindersInline:
        case LFWidgetKindStocksInline:
        case LFWidgetKindActivityInline:
        case LFWidgetKindAppleTVInline:
        case LFWidgetKindSportsInline:
            cls = [LFWidgetInline class];
            break;
    }
    if (!cls) return nil;
    return [[cls alloc] initWithKind:kind family:family config:config];
}

+ (UIImage *)previewImageForDescriptor:(LFLockScreenWidgetDescriptor *)d
                                  size:(CGSize)size
                                family:(LFWidgetFamily)family {
    UIGraphicsImageRenderer *r =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        // Translucent dark backdrop with rounded corners, mirrors the
        // chrome of the live widget slot.
        CGFloat radius = (family == LFWidgetFamilyCircular)
            ? size.width / 2.0
            : 16.0;
        UIBezierPath *bp = [UIBezierPath bezierPathWithRoundedRect:
            CGRectMake(0, 0, size.width, size.height) cornerRadius:radius];
        [[UIColor colorWithWhite:1.0 alpha:0.10] setFill];
        [bp fill];

        // Centred SF Symbol glyph as the icon.
        if (@available(iOS 13.0, *)) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                configurationWithPointSize:size.width * 0.40
                                    weight:UIImageSymbolWeightSemibold];
            UIImage *img = [UIImage systemImageNamed:d.sfSymbolName
                                   withConfiguration:cfg];
            if (img) {
                CGSize ts = img.size;
                CGRect tr = CGRectMake((size.width  - ts.width) / 2.0,
                                       (size.height - ts.height) / 2.0,
                                       ts.width, ts.height);
                [[UIColor whiteColor] set];
                UIImage *tinted = [img imageWithTintColor:[UIColor whiteColor]
                                            renderingMode:UIImageRenderingModeAlwaysOriginal];
                [tinted drawInRect:tr];
            }
        }
    }];
}

@end
