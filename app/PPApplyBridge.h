// PPApplyBridge — talks to the PocketPlayer tweak running inside SpringBoard.
//
// Contract:
//   1. App writes a request manifest to a SHARED path that both the app
//      (with platform-application entitlement) and the tweak inside
//      SpringBoard can read:
//          /var/mobile/Library/PocketPlayer/apply.plist
//      Keys:
//        sourceBundlePath : NSString  — absolute path to the .wallpaper folder
//        displayName      : NSString
//        itemID           : NSString
//        timestamp        : NSDate
//
//   2. App posts Darwin notification: "com.vortex.pocketplayer.apply"
//
//   3. Tweak's notify_register_dispatch handler picks it up, copies the
//      bundle into the PosterPlayer active slot, and reloads the poster
//      live -- no respring.

#import <Foundation/Foundation.h>

@class PPWallpaperItem;

@interface PPApplyBridge : NSObject

// Write manifest + post notification. Returns YES if the manifest was
// written and the notification posted. Returns NO + populates `error`
// if even step 1 failed (e.g. sandbox blocking the shared path -- which
// would mean entitlements aren't being honoured).
+ (BOOL)applyItem:(PPWallpaperItem *)item error:(NSError **)error;

@end
