// PPApplyBridge — talks to the PocketPlayer tweak running inside SpringBoard.
//
// V0.1 contract (what the tweak needs to honour, separately):
//   1. The app writes a "request manifest" plist to a shared path:
//        /var/jb/var/mobile/Library/PocketPlayer/apply.plist
//      with keys:
//        sourceBundlePath : NSString  — absolute path to the .wallpaper folder in our Documents
//        timestamp        : NSDate
//   2. The app posts a Darwin notification: "com.vortex.pocketplayer.apply"
//   3. The tweak (next iteration) listens for that notification, reads
//      the manifest, copies the bundle into the active PosterPlayer
//      slot, and applies it without respring.
//
// For now (v0.1 of the app) we only implement steps 1 and 2. The tweak
// side of the contract isn't there yet — applying will only take effect
// once we add the listener to Tweak.x. This way the UI is fully working
// and the wiring is a small follow-up.

#import <Foundation/Foundation.h>

@class PPWallpaperItem;

@interface PPApplyBridge : NSObject

// Returns YES if the manifest was written and the notification posted.
// Does NOT mean the wallpaper actually applied (see header comment).
+ (BOOL)applyItem:(PPWallpaperItem *)item error:(NSError **)error;

@end
