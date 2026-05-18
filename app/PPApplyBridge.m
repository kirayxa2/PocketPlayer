#import "PPApplyBridge.h"
#import "PPWallpaperLibrary.h"
#import <notify.h>

// Shared manifest path. Both the app (via platform-application
// entitlement) and the SpringBoard tweak read/write here. Note the
// path has NO /var/jb prefix -- that prefix is only for jailbreak's
// own binaries; Apple-namespace paths like /var/mobile/Library/...
// keep their original location on rootless.
static NSString *const kPPApplyManifestPath =
    @"/var/mobile/Library/PocketPlayer/apply.plist";
static const char *const kPPApplyDarwinName    = "com.vortex.pocketplayer.apply";
static const char *const kPPRespringDarwinName = "com.vortex.pocketplayer.respring";

@implementation PPApplyBridge

+ (BOOL)applyItem:(PPWallpaperItem *)item error:(NSError **)error {
    if (!item.bundlePath.length) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:100
                              userInfo:@{NSLocalizedDescriptionKey:@"empty bundle path"}];
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [kPPApplyManifestPath stringByDeletingLastPathComponent];
    NSError *mkdirErr = nil;
    if (![fm createDirectoryAtPath:dir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:&mkdirErr]) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:101
                              userInfo:@{NSLocalizedDescriptionKey:
                                  [NSString stringWithFormat:
                                      @"Couldn't create %@: %@\n\n"
                                      @"This usually means the app's entitlements aren't being "
                                      @"honoured by the jailbreak (platform-application missing "
                                      @"or signing failed). The tweak can't apply wallpapers "
                                      @"until the app can write here.",
                                      dir, mkdirErr.localizedDescription ?: @"unknown"]}];
        return NO;
    }

    NSDictionary *manifest = @{
        @"sourceBundlePath": item.bundlePath,
        @"itemID":           item.itemID ?: @"",
        @"displayName":      item.displayName ?: @"",
        @"timestamp":        [NSDate date],
    };
    if (![manifest writeToFile:kPPApplyManifestPath atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:102
                              userInfo:@{NSLocalizedDescriptionKey:
                                  [NSString stringWithFormat:
                                      @"Could not write manifest at %@", kPPApplyManifestPath]}];
        return NO;
    }

    // Wake up the listener inside SpringBoard. If the tweak isn't
    // installed (or notify_post is filtered), the kqueue watcher
    // inside the tweak picks it up from the file system instead.
    notify_post(kPPApplyDarwinName);
    return YES;
}

+ (void)respring {
    notify_post(kPPRespringDarwinName);
}

@end
