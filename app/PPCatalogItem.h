// PPCatalogItem — single wallpaper entry in the online catalog.
//
// Built from the GitHub Trees API response when the user opens the
// Browse tab. Holds enough state to render a tile (name, category,
// preview URL if any) and to download the wallpaper when tapped.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PPCatalogItem : NSObject

// Display name without extension, "Mario Galaxy" not "mario_galaxy.tendies".
@property (nonatomic, copy) NSString *displayName;

// "Animated", "Static", "Custom", etc. Derived from the parent folder
// inside the repo (wallpapers/<category>/<file>.tendies).
@property (nonatomic, copy) NSString *category;

// Path inside the repo, e.g. "wallpapers/custom/woopah_3.tendies".
// Used to build the raw download URL.
@property (nonatomic, copy) NSString *repoPath;

// Where to fetch the actual .tendies bytes from.
// raw.githubusercontent.com/<owner>/<repo>/<branch>/<repoPath>
@property (nonatomic, copy) NSString *downloadURL;

// Optional preview image URL. Some entries in the repo have a sibling
// .png with the same basename as the .tendies; if present we fill this
// in so the Browse grid can show a real thumbnail. Otherwise the tile
// renders a skeleton placeholder.
@property (nonatomic, copy, nullable) NSString *previewURL;

// File size in bytes if the API returned it; -1 if unknown.
@property (nonatomic, assign) long long sizeBytes;

@end

NS_ASSUME_NONNULL_END
