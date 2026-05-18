// PPCatalogService — talks to GitHub for the online wallpaper catalog.
//
// Source repo: https://github.com/SerStars/Nugget-Wallpapers
// Layout:      wallpapers/<category>/<name>.tendies  (+ optional .png sibling)
//
// One API call gets the whole tree. Result cached on disk for 6 hours
// so a typical user makes 1-3 GitHub requests per day, well within the
// unauthenticated 60/hour limit. Files themselves come from
// raw.githubusercontent.com which doesn't share that limit.
//
// Public methods are async with completion handlers on the main queue.

#import <Foundation/Foundation.h>
#import "PPCatalogItem.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const PPCatalogErrorDomain;
typedef NS_ENUM(NSInteger, PPCatalogError) {
    PPCatalogErrorNetworkFailure   = 1,
    PPCatalogErrorRateLimited      = 2,   // GitHub returned 403 / X-RateLimit-Remaining: 0
    PPCatalogErrorParseFailure     = 3,
    PPCatalogErrorEmpty            = 4,
};

@interface PPCatalogService : NSObject

+ (instancetype)shared;

// All known online wallpapers, grouped by category. Returns cached
// data immediately if the cache is still warm (<6h old), otherwise
// fetches fresh from GitHub. Set forceRefresh=YES on pull-to-refresh.
//
// `completion` is always called on the main queue.
- (void)fetchCatalogForceRefresh:(BOOL)forceRefresh
                      completion:(void (^)(NSArray<PPCatalogItem *> *items,
                                           NSError * _Nullable error))completion;

// Downloads `item` into the app's cache and reports progress. The
// completion handler hands back a local file path which can be fed
// straight into PPWallpaperLibrary's import pipeline.
//
// If the same file was downloaded earlier and is still on disk, the
// completion fires immediately with the cached path (offline-friendly).
//
// `progress` (0.0..1.0) and `completion` are both called on main.
- (void)downloadItem:(PPCatalogItem *)item
            progress:(void (^_Nullable)(double progress))progress
          completion:(void (^)(NSString * _Nullable localPath,
                               NSError * _Nullable error))completion;

// All distinct categories from the cached catalog, in display order
// ("All" first, then the others alphabetically). For the chip strip.
- (NSArray<NSString *> *)categoriesIncludingAll:(BOOL)includeAll;

// Filter currently-cached items by category name. Pass nil or "All"
// to return everything.
- (NSArray<PPCatalogItem *> *)itemsForCategory:(nullable NSString *)category;

// Optional GitHub personal access token. If non-nil we send it in
// Authorization headers, raising the rate limit from 60 to 5000/hour.
// Stored in NSUserDefaults; nil means unauthenticated.
@property (nonatomic, copy, nullable) NSString *githubToken;

@end

NS_ASSUME_NONNULL_END
