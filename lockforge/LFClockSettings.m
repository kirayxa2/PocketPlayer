#import "LFClockSettings.h"

// Where the plist lives. Same parent as PocketPlayer's heartbeat / apply
// manifest, so all our state is under /var/mobile/Library/LockForge/.
static NSString *const kLFSettingsPath =
    @"/var/mobile/Library/LockForge/clock.plist";

@implementation LFClockSettings

+ (instancetype)shared {
    static LFClockSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [LFClockSettings new];
        [s applyDefaults];
        [s load];
    });
    return s;
}

// Sensible defaults: enabled, system thin font, adaptive color, no
// scaling, no offset, no glass, gyro on. Matches what a stock iOS 15
// lock screen looks like on first install -- no surprise UI changes
// until the user enters the editor.
- (void)applyDefaults {
    _enabled              = YES;
    _font                 = LFClockFontSystemThin;
    _colorMode            = LFClockColorAdaptive;
    _customColorRGBA      = @[ @1.0, @1.0, @1.0, @1.0 ];
    _scale                = 1.0;
    _horizontalStretch    = 1.0;
    _verticalStretch      = 1.0;
    _alignment            = LFClockAlignmentCenter;
    _positionOffset       = CGPointZero;
    _liquidGlassIntensity = 0;
    _gyroEffectsEnabled   = YES;
    _dateWidget           = LFDateWidgetDate;
    _dateCustomText       = @"";
    _dateInlineKind       = LFWidgetKindDate;
    _dateInlineConfig     = @{};
    _trayPosition         = LFTrayPositionUnderClock;
    _traySlots            = @[];
}

- (UIFont *)resolvedFontForReferenceSize:(CGFloat)refSize {
    CGFloat size = refSize * MAX(0.6, MIN(2.8, _scale));
    UIFont *font = nil;

    switch (_font) {
        case LFClockFontSystemThin:
            font = [UIFont systemFontOfSize:size weight:UIFontWeightThin];
            break;
        case LFClockFontSystemBold:
            font = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
            break;
        case LFClockFontRoundedHeavy:
            // SF Pro Rounded -- closest match to iOS 16/26's default "rounded"
            // clock face. UIFontDescriptorSystemDesignRounded available since
            // iOS 13, so it's fine on 15.
            if (@available(iOS 13.0, *)) {
                UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
                UIFontDescriptor *d =
                    [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
                font = d ? [UIFont fontWithDescriptor:d size:size] : base;
            } else {
                font = [UIFont systemFontOfSize:size weight:UIFontWeightHeavy];
            }
            break;
        case LFClockFontSerif: {
            // New York is bundled with iOS but you have to ask via descriptor.
            UIFont *base = [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
            UIFontDescriptor *d =
                [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
            font = d ? [UIFont fontWithDescriptor:d size:size] : base;
            break;
        }
        case LFClockFontMonospace:
            font = [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightSemibold];
            break;
        case LFClockFontCondensedBold: {
            // SF Compact -- closest to iOS 26's second clock style. Falls
            // back to bold system font if the descriptor isn't available.
            UIFontDescriptor *d = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
                UIFontDescriptorFamilyAttribute: @"SFCompactDisplay",
                UIFontDescriptorTraitsAttribute: @{
                    UIFontWeightTrait: @(UIFontWeightBold),
                },
            }];
            font = d ? [UIFont fontWithDescriptor:d size:size] : nil;
            if (!font) font = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
            break;
        }
        case LFClockFontUltraThin:
            font = [UIFont systemFontOfSize:size weight:UIFontWeightUltraLight];
            break;
        default:
            font = [UIFont systemFontOfSize:size weight:UIFontWeightThin];
            break;
    }
    return font ?: [UIFont systemFontOfSize:size weight:UIFontWeightThin];
}

- (UIColor *)resolvedColorForBackgroundLuminance:(NSNumber *)luminance {
    switch (_colorMode) {
        case LFClockColorAdaptive: {
            // No sample? Fall back to white (matches Apple default).
            if (!luminance) return [UIColor whiteColor];
            // Threshold 0.55 picks black on bright wallpapers, white on
            // dark ones. Apple's threshold is more nuanced (per-region)
            // but a single threshold on the average brightness covers
            // 90% of cases on real wallpapers.
            CGFloat lum = [luminance doubleValue];
            return lum > 0.55 ? [UIColor blackColor] : [UIColor whiteColor];
        }
        case LFClockColorWhite:  return [UIColor whiteColor];
        case LFClockColorBlack:  return [UIColor blackColor];
        case LFClockColorRed:    return [UIColor systemRedColor];
        case LFClockColorBlue:   return [UIColor systemBlueColor];
        case LFClockColorYellow: return [UIColor systemYellowColor];
        case LFClockColorPink:   return [UIColor systemPinkColor];
        case LFClockColorCustom: {
            NSArray *c = _customColorRGBA;
            if (c.count != 4) return [UIColor whiteColor];
            return [UIColor colorWithRed:[c[0] doubleValue]
                                   green:[c[1] doubleValue]
                                    blue:[c[2] doubleValue]
                                   alpha:[c[3] doubleValue]];
        }
        default:                 return [UIColor whiteColor];
    }
}

#pragma mark - Persistence

- (void)load {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kLFSettingsPath];
    if (!d) return;
    if (d[@"enabled"])              _enabled              = [d[@"enabled"]              boolValue];
    if (d[@"font"])                 _font                 = (LFClockFont)[d[@"font"] integerValue];
    if (d[@"colorMode"])            _colorMode            = (LFClockColorMode)[d[@"colorMode"] integerValue];
    if (d[@"customColorRGBA"])      _customColorRGBA      = d[@"customColorRGBA"];
    if (d[@"scale"])                _scale                = [d[@"scale"]                doubleValue];
    if (d[@"horizontalStretch"])    _horizontalStretch    = [d[@"horizontalStretch"]    doubleValue];
    if (d[@"verticalStretch"]) {
        _verticalStretch = [d[@"verticalStretch"] doubleValue];
    } else if (d[@"scale"] && fabs(_scale - 1.0) > 0.01) {
        // Legacy plist from a build where Y-axis drag wrote `scale`
        // (uniform font-size multiplier). Now Y-axis writes
        // `verticalStretch`. Migrate: copy the user's saved size
        // onto the axis where it now lives, then reset scale so
        // it doesn't double-multiply.
        _verticalStretch = MAX(1.0, MIN(3.5, _scale));
        _scale           = 1.0;
    }
    // iOS 16/26 lock screen clock cannot be horizontally resized; the
    // editor no longer exposes a way to change horizontalStretch.
    // Old plists (from a build where the resize handle did X-axis
    // stretching) may have a non-1.0 value saved -- reset it so
    // older users don't see oddly-proportioned digits and so the
    // value matches what the editor can produce going forward.
    if (fabs(_horizontalStretch - 1.0) > 0.001) {
        _horizontalStretch = 1.0;
    }
    // Clamp verticalStretch into the current valid range [1.0, 3.5].
    // The minimum 1.0 enforces "you can only resize DOWN" -- there
    // is no compression below natural size. The maximum 3.5 is the
    // largest stretch where the auto-fit font calculation still
    // leaves the digits inside the screen on a 6s. Older plists
    // (from a build where max was 5.0) are scaled down so the user
    // sees proportionally similar size on the new build.
    if (_verticalStretch < 1.0) {
        _verticalStretch = 1.0;
    } else if (_verticalStretch > 3.5) {
        // Map [3.5, 5.0] onto the new [3.0, 3.5] band so a user who
        // had previously dragged "almost to the max" still feels
        // like they're near the max here. Clamp to 3.5 either way.
        CGFloat t = (_verticalStretch - 3.5) / (5.0 - 3.5);  // 0..1
        if (t > 1.0) t = 1.0;
        _verticalStretch = 3.0 + 0.5 * t;
    }
    if (d[@"alignment"])            _alignment            = (LFClockAlignment)[d[@"alignment"] integerValue];
    if (d[@"positionOffsetX"] && d[@"positionOffsetY"]) {
        _positionOffset = CGPointMake([d[@"positionOffsetX"] doubleValue],
                                      [d[@"positionOffsetY"] doubleValue]);
    }
    if (d[@"liquidGlassIntensity"]) _liquidGlassIntensity = [d[@"liquidGlassIntensity"] integerValue];
    if (d[@"gyroEffectsEnabled"])   _gyroEffectsEnabled   = [d[@"gyroEffectsEnabled"]   boolValue];
    if (d[@"dateWidget"])           _dateWidget           = (LFDateWidget)[d[@"dateWidget"] integerValue];
    if (d[@"dateCustomText"])       _dateCustomText       = d[@"dateCustomText"];

    // === Migration & load of the iOS 26 inline-kind / widget-tray fields.
    if (d[@"dateInlineKind"]) {
        _dateInlineKind = (LFWidgetKind)[d[@"dateInlineKind"] integerValue];
    } else {
        // Legacy plist: project the 4-value LFDateWidget enum onto the
        // canonical LFWidgetKind so the user keeps their selection.
        switch (_dateWidget) {
            case LFDateWidgetDate:        _dateInlineKind = LFWidgetKindDate;          break;
            case LFDateWidgetBattery:     _dateInlineKind = LFWidgetKindBatteryInline; break;
            case LFDateWidgetDayCounter:  _dateInlineKind = LFWidgetKindDayCounter;    break;
            case LFDateWidgetCustomText:  _dateInlineKind = LFWidgetKindCustomText;    break;
            default:                      _dateInlineKind = LFWidgetKindDate;          break;
        }
    }
    if ([d[@"dateInlineConfig"] isKindOfClass:[NSDictionary class]]) {
        _dateInlineConfig = d[@"dateInlineConfig"];
    } else if (_dateInlineKind == LFWidgetKindCustomText &&
               _dateCustomText.length) {
        // Migrate legacy custom text into the inline-config dict.
        _dateInlineConfig = @{ @"text": _dateCustomText };
    }
    if (d[@"trayPosition"]) {
        _trayPosition = (LFTrayPosition)[d[@"trayPosition"] integerValue];
    }
    if ([d[@"traySlots"] isKindOfClass:[NSArray class]]) {
        // Sanity-validate each slot dict before keeping it -- a bad
        // plist shouldn't crash the tweak.
        NSMutableArray *clean = [NSMutableArray array];
        for (NSDictionary *e in d[@"traySlots"]) {
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            if (!e[@"kind"] || !e[@"family"]) continue;
            NSDictionary *cfg = e[@"config"];
            if (![cfg isKindOfClass:[NSDictionary class]]) cfg = @{};
            [clean addObject:@{ @"kind":   e[@"kind"],
                                @"family": e[@"family"],
                                @"config": cfg }];
        }
        _traySlots = clean;
    }
}

- (void)save {
    NSString *dir = [kLFSettingsPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSDictionary *d = @{
        @"enabled":              @(_enabled),
        @"font":                 @(_font),
        @"colorMode":            @(_colorMode),
        @"customColorRGBA":      _customColorRGBA ?: @[ @1, @1, @1, @1 ],
        @"scale":                @(_scale),
        @"horizontalStretch":    @(_horizontalStretch),
        @"verticalStretch":      @(_verticalStretch),
        @"alignment":            @(_alignment),
        @"positionOffsetX":      @(_positionOffset.x),
        @"positionOffsetY":      @(_positionOffset.y),
        @"liquidGlassIntensity": @(_liquidGlassIntensity),
        @"gyroEffectsEnabled":   @(_gyroEffectsEnabled),
        @"dateWidget":           @(_dateWidget),
        @"dateCustomText":       _dateCustomText ?: @"",
        @"dateInlineKind":       @(_dateInlineKind),
        @"dateInlineConfig":     _dateInlineConfig ?: @{},
        @"trayPosition":         @(_trayPosition),
        @"traySlots":            _traySlots ?: @[],
    };
    [d writeToFile:kLFSettingsPath atomically:YES];
}

@end
