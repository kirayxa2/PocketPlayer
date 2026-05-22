// LFLockScreenLibrary - storage for the iOS 16/26 carousel of saved
// lock-screens. Holds N preset states; one is "active" at a time and
// its values are mirrored into LFClockSettings.shared so all the
// existing rendering code (clock overlay, widgets, editor) continues
// to read from the same singleton without changes.
//
// Persistence (single-file for atomic writes):
//
//   /var/mobile/Library/LockForge/lockscreens.plist
//     {
//       activeId : <uuid>,
//       screens  : [
//         {
//           id            : <uuid>,
//           name          : "Lock Screen 1",
//           wallpaperPath : <abs path or empty>,
//           settings      : { font, color, vStretch, traySlots, ... },
//         },
//         ...
//       ]
//     }
//
// Wallpapers are JPG files under
//   /var/mobile/Library/LockForge/wallpapers/<uuid>.jpg
// Created on demand when the user picks an image via the carousel "+".
//
// Migration: on first load, if lockscreens.plist doesn't exist but
// clock.plist does (legacy single-screen file), we wrap the legacy
// file as a single screen with a generated uuid and write the new
// plist. Old clock.plist is left in place (harmless backup).
//
// Notifications posted on the default centre:
//   LFActiveLockScreenChangedNotification - active id flipped, all
//                                            renderable surfaces should
//                                            refreshFromSettings.
//   LFLockScreenLibraryChangedNotification - any change to the set
//                                            (added / removed / reorder).
//                                            Selector should reload its
//                                            cards.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const LFActiveLockScreenChangedNotification;
extern NSString *const LFLockScreenLibraryChangedNotification;

@interface LFLockScreenLibrary : NSObject

+ (instancetype)shared;

// Ordered list of all saved lock-screen UUIDs. Always at least one
// entry; the library invents a default screen on first run.
@property (nonatomic, readonly, copy) NSArray<NSString *> *lockScreenIds;

// UUID of the currently-active screen (whose values are mirrored into
// LFClockSettings.shared).
@property (nonatomic, readonly, copy) NSString *activeId;

// Number of screens in the library.
- (NSUInteger)count;

// Display name for a given screen ("Lock Screen 1", "Lock Screen 2"
// etc. by default; user can rename from the editor in a future PR).
- (nullable NSString *)nameForId:(NSString *)uuid;

// Absolute path to the wallpaper file for a given screen, or nil if
// the screen has no custom wallpaper (renders against system default).
- (nullable NSString *)wallpaperPathForId:(NSString *)uuid;

// Switches active to the given uuid. Mirrors that screen's settings
// into LFClockSettings.shared, persists, posts
// LFActiveLockScreenChangedNotification. Caller is the carousel
// scroll-snap delegate.
- (void)setActiveId:(NSString *)uuid;

// Adds a new lock screen with optional wallpaper image. The image is
// JPEG-encoded to /var/mobile/Library/LockForge/wallpapers/<uuid>.jpg
// at quality 0.9 (~250KB on 6s-class screens) and a record is added.
// Returns the new uuid. Also sets the new screen as active so the
// editor opens directly on it.
- (NSString *)addLockScreenWithWallpaperImage:(nullable UIImage *)image;

// Removes the screen with the given uuid. If the active screen is
// removed, the previous one in the array (or the next, if first)
// becomes active. The library always preserves at least one screen;
// removing the last screen is a no-op.
- (void)removeId:(NSString *)uuid;

// Snapshot the CURRENT in-memory state of LFClockSettings.shared back
// into the active screen's record and persist. Called by the editor
// when it's about to dismiss, so user edits travel with the active
// screen across switches.
- (void)flushActiveStateToDisk;

@end

NS_ASSUME_NONNULL_END
