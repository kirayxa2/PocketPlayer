// PPApplyBridge — talks to the PocketPlayer tweak running inside SpringBoard.
//
// Apply is a TWO-STEP process now, on purpose:
//
//   Step 1. applyItem: — write a manifest to a shared path that the
//   tweak's listener reads, then post Darwin notification
//   "com.vortex.pocketplayer.apply". The tweak copies the chosen
//   .wallpaper bundle into PosterPlayer's active slot. NO respring.
//
//   Step 2. respring — post Darwin notification
//   "com.vortex.pocketplayer.respring". The tweak kills SpringBoard,
//   launchd brings it back in ~3s, and on the next launch PosterKit
//   plus our overlay both pick up the new bundle on lockscreen,
//   homescreen and behind the lock UI.
//
// Splitting these lets users on fragile jailbreaks (where respring
// occasionally drops the jailbreak and forces a re-Dopamine) hold off
// the respring until they're ready -- e.g. plug in their charger or
// close important apps first. Until they tap Respring, only our
// overlay updates; the system wallpaper takes effect on the next
// natural restart.
//
// Manifest path:  /var/mobile/Library/PocketPlayer/apply.plist
// Manifest keys:
//   sourceBundlePath : NSString  — absolute path to the .wallpaper folder
//   itemID           : NSString
//   displayName      : NSString
//   timestamp        : NSDate

#import <Foundation/Foundation.h>

@class PPWallpaperItem;

@interface PPApplyBridge : NSObject

// Step 1. Stage the bundle for apply. Returns YES if the manifest
// landed and the apply notification was posted. Does NOT respring;
// caller is expected to follow up with -respring when ready.
+ (BOOL)applyItem:(PPWallpaperItem *)item error:(NSError **)error;

// Step 2. Ask the tweak to respring. No-op if the tweak isn't
// installed or running. SpringBoard returns in ~3 seconds.
+ (void)respring;

@end
