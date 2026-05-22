#import "LFLockScreenLibrary.h"
#import "LFClockSettings.h"

NSString *const LFActiveLockScreenChangedNotification =
    @"LFActiveLockScreenChangedNotification";
NSString *const LFLockScreenLibraryChangedNotification =
    @"LFLockScreenLibraryChangedNotification";

static NSString *const kLFRoot       = @"/var/mobile/Library/LockForge";
static NSString *const kLFLibraryPlist =
    @"/var/mobile/Library/LockForge/lockscreens.plist";
// Legacy single-screen file we migrate from. Keep around as a backup
// after migration -- the new code never writes to it.
static NSString *const kLFLegacyClockPlist =
    @"/var/mobile/Library/LockForge/clock.plist";
static NSString *const kLFWallpaperDir =
    @"/var/mobile/Library/LockForge/wallpapers";

// Keys used inside each lock-screen record. Stable plist strings so
// older builds reading newer plists ignore unknown keys gracefully.
static NSString *const kK_Id             = @"id";
static NSString *const kK_Name           = @"name";
static NSString *const kK_WallpaperPath  = @"wallpaperPath";
static NSString *const kK_Settings       = @"settings";

@interface LFLockScreenLibrary () {
    // Mutable storage: array of NSMutableDictionary records, plus the
    // active uuid. Single-file plist write is atomic.
    NSMutableArray<NSMutableDictionary *> *_screens;
    NSString                              *_activeId;
}
@end

@implementation LFLockScreenLibrary

+ (instancetype)shared {
    static LFLockScreenLibrary *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [LFLockScreenLibrary new];
        [s loadFromDisk];
    });
    return s;
}

#pragma mark - Public read API

- (NSArray<NSString *> *)lockScreenIds {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:_screens.count];
    for (NSDictionary *r in _screens) {
        NSString *uuid = r[kK_Id];
        if ([uuid isKindOfClass:[NSString class]]) [out addObject:uuid];
    }
    return [out copy];
}

- (NSString *)activeId { return _activeId; }
- (NSUInteger)count    { return _screens.count; }

- (NSString *)nameForId:(NSString *)uuid {
    NSDictionary *r = [self recordForId:uuid];
    NSString *n = r[kK_Name];
    return [n isKindOfClass:[NSString class]] ? n : nil;
}

- (NSString *)wallpaperPathForId:(NSString *)uuid {
    NSDictionary *r = [self recordForId:uuid];
    NSString *p = r[kK_WallpaperPath];
    if (![p isKindOfClass:[NSString class]] || p.length == 0) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return p;
}

#pragma mark - Public mutation API

- (void)setActiveId:(NSString *)uuid {
    if (![uuid isKindOfClass:[NSString class]]) return;
    if ([_activeId isEqualToString:uuid])       return;
    NSDictionary *target = [self recordForId:uuid];
    if (!target) return;

    // Snapshot the OUTGOING active state to disk first so user edits
    // travel with the screen they belong to. Without this, switching
    // away discards any tweaks the user made since the last save.
    [self captureCurrentSettingsIntoActiveRecord];

    _activeId = [uuid copy];
    [self mirrorRecordIntoSettings:target];
    [self writeToDisk];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:LFActiveLockScreenChangedNotification object:self];
}

- (NSString *)addLockScreenWithWallpaperImage:(UIImage *)image {
    // Snapshot whatever the user has on the current active so we
    // don't lose edits when we switch to the new screen.
    [self captureCurrentSettingsIntoActiveRecord];

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *wallpaperPath = nil;
    if (image) {
        [[NSFileManager defaultManager] createDirectoryAtPath:kLFWallpaperDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        wallpaperPath = [kLFWallpaperDir stringByAppendingFormat:@"/%@.jpg", uuid];
        // q=0.9 keeps quality high while staying near 250KB on 6s-class
        // screens. Store JPEG (not PNG) -- wallpaper photos compress
        // well as JPEG, and we don't need transparency.
        NSData *data = UIImageJPEGRepresentation(image, 0.9);
        [data writeToFile:wallpaperPath atomically:YES];
    }

    // Default settings dictionary mirrors `LFClockSettings -applyDefaults`
    // so a fresh screen looks identical to a vanilla install. We DON'T
    // copy the current active screen's settings -- creating a new
    // screen should give the user a clean slate to customise.
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];

    NSString *defaultName = [NSString stringWithFormat:@"Lock Screen %lu",
                             (unsigned long)(_screens.count + 1)];

    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:@{
        kK_Id:            uuid,
        kK_Name:          defaultName,
        kK_WallpaperPath: wallpaperPath ?: @"",
        kK_Settings:      settings,
    }];
    [_screens addObject:record];
    _activeId = [uuid copy];

    // Reset settings to defaults for the new screen.
    [self resetSettingsToDefaults];

    [self writeToDisk];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:LFLockScreenLibraryChangedNotification object:self];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:LFActiveLockScreenChangedNotification object:self];

    return uuid;
}

- (void)removeId:(NSString *)uuid {
    if (_screens.count <= 1) return;     // never remove last
    NSInteger idx = [self indexForId:uuid];
    if (idx < 0) return;

    BOOL removingActive = [_activeId isEqualToString:uuid];
    NSDictionary *removed = _screens[idx];

    // Delete wallpaper file if owned by this screen.
    NSString *wp = removed[kK_WallpaperPath];
    if ([wp isKindOfClass:[NSString class]] && wp.length) {
        [[NSFileManager defaultManager] removeItemAtPath:wp error:NULL];
    }

    [_screens removeObjectAtIndex:idx];

    if (removingActive) {
        // Pick neighbour at the same index (or last if we removed the
        // tail). Mirror its settings into shared.
        NSInteger newIdx = MIN(idx, (NSInteger)_screens.count - 1);
        if (newIdx < 0) newIdx = 0;
        NSDictionary *next = _screens[newIdx];
        _activeId = [next[kK_Id] copy];
        [self mirrorRecordIntoSettings:next];
        [self writeToDisk];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:LFActiveLockScreenChangedNotification object:self];
    } else {
        [self writeToDisk];
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:LFLockScreenLibraryChangedNotification object:self];
}

- (void)flushActiveStateToDisk {
    [self captureCurrentSettingsIntoActiveRecord];
    [self writeToDisk];
}

#pragma mark - Internal helpers

- (NSInteger)indexForId:(NSString *)uuid {
    if (![uuid isKindOfClass:[NSString class]]) return -1;
    for (NSInteger i = 0; i < (NSInteger)_screens.count; i++) {
        if ([_screens[i][kK_Id] isEqual:uuid]) return i;
    }
    return -1;
}

- (NSMutableDictionary *)recordForId:(NSString *)uuid {
    NSInteger idx = [self indexForId:uuid];
    return (idx >= 0) ? _screens[idx] : nil;
}

- (NSMutableDictionary *)activeRecord {
    return [self recordForId:_activeId];
}

#pragma mark - Settings <-> dict translation

// Writes the LIVE values from LFClockSettings.shared into the active
// record's settings dict so they get persisted. Called before any
// active-id change and from -flushActiveStateToDisk.
- (void)captureCurrentSettingsIntoActiveRecord {
    NSMutableDictionary *r = [self activeRecord];
    if (!r) return;
    LFClockSettings *s = [LFClockSettings shared];
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"enabled"]              = @(s.enabled);
    dict[@"font"]                 = @(s.font);
    dict[@"colorMode"]            = @(s.colorMode);
    dict[@"customColorRGBA"]      = s.customColorRGBA ?: @[ @1, @1, @1, @1 ];
    dict[@"scale"]                = @(s.scale);
    dict[@"horizontalStretch"]    = @(s.horizontalStretch);
    dict[@"verticalStretch"]      = @(s.verticalStretch);
    dict[@"alignment"]            = @(s.alignment);
    dict[@"positionOffsetX"]      = @(s.positionOffset.x);
    dict[@"positionOffsetY"]      = @(s.positionOffset.y);
    dict[@"liquidGlassIntensity"] = @(s.liquidGlassIntensity);
    dict[@"gyroEffectsEnabled"]   = @(s.gyroEffectsEnabled);
    dict[@"dateWidget"]           = @(s.dateWidget);
    dict[@"dateCustomText"]       = s.dateCustomText ?: @"";
    dict[@"dateInlineKind"]       = @(s.dateInlineKind);
    dict[@"dateInlineConfig"]     = s.dateInlineConfig ?: @{};
    dict[@"trayPosition"]         = @(s.trayPosition);
    dict[@"traySlots"]            = s.traySlots ?: @[];
    r[kK_Settings] = dict;
}

// Reads `record[kK_Settings]` and pushes every value into the LFClock-
// Settings singleton, so the renderer reflects the screen we just
// switched to. Mirrors the structure of -[LFClockSettings load] (but
// reads from a dict, not from clock.plist on disk).
- (void)mirrorRecordIntoSettings:(NSDictionary *)record {
    if (!record) return;
    NSDictionary *d = record[kK_Settings];
    if (![d isKindOfClass:[NSDictionary class]]) {
        [self resetSettingsToDefaults];
        return;
    }
    LFClockSettings *s = [LFClockSettings shared];
    if (d[@"enabled"])              s.enabled              = [d[@"enabled"]              boolValue];
    if (d[@"font"])                 s.font                 = (LFClockFont)[d[@"font"] integerValue];
    if (d[@"colorMode"])            s.colorMode            = (LFClockColorMode)[d[@"colorMode"] integerValue];
    if (d[@"customColorRGBA"])      s.customColorRGBA      = d[@"customColorRGBA"];
    if (d[@"scale"])                s.scale                = [d[@"scale"]                doubleValue];
    if (d[@"horizontalStretch"])    s.horizontalStretch    = [d[@"horizontalStretch"]    doubleValue];
    if (d[@"verticalStretch"])      s.verticalStretch      = [d[@"verticalStretch"]      doubleValue];
    if (d[@"alignment"])            s.alignment            = (LFClockAlignment)[d[@"alignment"] integerValue];
    if (d[@"positionOffsetX"] && d[@"positionOffsetY"]) {
        s.positionOffset = CGPointMake([d[@"positionOffsetX"] doubleValue],
                                       [d[@"positionOffsetY"] doubleValue]);
    }
    if (d[@"liquidGlassIntensity"]) s.liquidGlassIntensity = [d[@"liquidGlassIntensity"] integerValue];
    if (d[@"gyroEffectsEnabled"])   s.gyroEffectsEnabled   = [d[@"gyroEffectsEnabled"]   boolValue];
    if (d[@"dateWidget"])           s.dateWidget           = (LFDateWidget)[d[@"dateWidget"] integerValue];
    if (d[@"dateCustomText"])       s.dateCustomText       = d[@"dateCustomText"];
    if (d[@"dateInlineKind"])       s.dateInlineKind       = (LFWidgetKind)[d[@"dateInlineKind"] integerValue];
    if ([d[@"dateInlineConfig"] isKindOfClass:[NSDictionary class]]) {
        s.dateInlineConfig = d[@"dateInlineConfig"];
    } else {
        s.dateInlineConfig = @{};
    }
    if (d[@"trayPosition"])         s.trayPosition         = (LFTrayPosition)[d[@"trayPosition"] integerValue];
    if ([d[@"traySlots"] isKindOfClass:[NSArray class]]) {
        s.traySlots = d[@"traySlots"];
    } else {
        s.traySlots = @[];
    }
    // Clamp / fix values the legacy load path used to repair.
    if (fabs(s.horizontalStretch - 1.0) > 0.001) s.horizontalStretch = 1.0;
    if (s.verticalStretch < 1.0)                  s.verticalStretch  = 1.0;
    else if (s.verticalStretch > 3.5)             s.verticalStretch  = 3.5;
}

// Restore LFClockSettings.shared to factory defaults. Called when a
// new screen is added (clean slate) and as a fallback when an active
// record has no settings dict.
- (void)resetSettingsToDefaults {
    LFClockSettings *s = [LFClockSettings shared];
    s.enabled              = YES;
    s.font                 = LFClockFontSystemThin;
    s.colorMode            = LFClockColorAdaptive;
    s.customColorRGBA      = @[ @1.0, @1.0, @1.0, @1.0 ];
    s.scale                = 1.0;
    s.horizontalStretch    = 1.0;
    s.verticalStretch      = 1.0;
    s.alignment            = LFClockAlignmentCenter;
    s.positionOffset       = CGPointZero;
    s.liquidGlassIntensity = 0;
    s.gyroEffectsEnabled   = YES;
    s.dateWidget           = LFDateWidgetDate;
    s.dateCustomText       = @"";
    s.dateInlineKind       = LFWidgetKindDate;
    s.dateInlineConfig     = @{};
    s.trayPosition         = LFTrayPositionUnderClock;
    s.traySlots            = @[];
}

#pragma mark - Disk I/O

- (void)loadFromDisk {
    [[NSFileManager defaultManager] createDirectoryAtPath:kLFRoot
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kLFLibraryPlist];

    if ([root isKindOfClass:[NSDictionary class]]) {
        NSArray *arr = root[@"screens"];
        _screens = [NSMutableArray array];
        if ([arr isKindOfClass:[NSArray class]]) {
            for (NSDictionary *r in arr) {
                if (![r isKindOfClass:[NSDictionary class]]) continue;
                if (![r[kK_Id] isKindOfClass:[NSString class]]) continue;
                [_screens addObject:[r mutableCopy]];
            }
        }
        _activeId = root[@"activeId"];
        if (![_activeId isKindOfClass:[NSString class]] ||
            [self indexForId:_activeId] < 0) {
            _activeId = _screens.firstObject[kK_Id];
        }
    }

    if (_screens.count == 0) {
        // First run / no plist yet. Seed the library: if there's a
        // legacy clock.plist from a single-screen build, wrap it as
        // screen 0; otherwise create a fresh default screen.
        _screens = [NSMutableArray array];
        NSString *uuid = [[NSUUID UUID] UUIDString];
        NSMutableDictionary *seed = [NSMutableDictionary dictionaryWithDictionary:@{
            kK_Id:            uuid,
            kK_Name:          @"Lock Screen 1",
            kK_WallpaperPath: @"",
            kK_Settings:      [NSMutableDictionary dictionary],
        }];
        NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:kLFLegacyClockPlist];
        if ([legacy isKindOfClass:[NSDictionary class]]) {
            seed[kK_Settings] = [legacy mutableCopy];
        }
        [_screens addObject:seed];
        _activeId = uuid;
    }

    // Push the active record's values into LFClockSettings.shared so
    // the rest of the tweak (which reads via the singleton) gets the
    // right state on first read. NB: -[LFClockSettings shared] called
    // re-entrantly during init is fine because that singleton's init
    // is just defaults+ivars; loadFromDisk runs AFTER it during
    // +[LFLockScreenLibrary shared].
    NSDictionary *active = [self activeRecord];
    if (active) [self mirrorRecordIntoSettings:active];

    // If we just migrated from a legacy single-screen file (no
    // lockscreens.plist on disk yet), persist the new format right
    // away so subsequent launches read the new layout.
    if (![[NSFileManager defaultManager] fileExistsAtPath:kLFLibraryPlist]) {
        [self writeToDisk];
    }
}

- (void)writeToDisk {
    [[NSFileManager defaultManager] createDirectoryAtPath:kLFRoot
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSDictionary *root = @{
        @"activeId": _activeId ?: @"",
        @"screens":  _screens  ?: @[],
    };
    [root writeToFile:kLFLibraryPlist atomically:YES];
}

@end
