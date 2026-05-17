#import "PPApplyBridge.h"
#import "PPWallpaperLibrary.h"
#import <notify.h>

static NSString *const kPPApplyManifestPath =
    @"/var/jb/var/mobile/Library/PocketPlayer/apply.plist";
static const char *const kPPApplyDarwinName =
    "com.vortex.pocketplayer.apply";

@implementation PPApplyBridge

+ (BOOL)applyItem:(PPWallpaperItem *)item error:(NSError **)error {
    if (!item.bundlePath.length) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:100
                              userInfo:@{NSLocalizedDescriptionKey:@"empty bundle path"}];
        return NO;
    }

    NSString *dir = [kPPApplyManifestPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSDictionary *manifest = @{
        @"sourceBundlePath": item.bundlePath,
        @"itemID":           item.itemID ?: @"",
        @"displayName":      item.displayName ?: @"",
        @"timestamp":        [NSDate date],
    };
    if (![manifest writeToFile:kPPApplyManifestPath atomically:YES]) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:101
                              userInfo:@{NSLocalizedDescriptionKey:
                                  [NSString stringWithFormat:@"could not write manifest at %@",
                                   kPPApplyManifestPath]}];
        return NO;
    }

    // Wake up any listener inside SpringBoard. If nobody's listening yet
    // (older tweak build), this is a harmless no-op.
    notify_post(kPPApplyDarwinName);
    return YES;
}

@end
