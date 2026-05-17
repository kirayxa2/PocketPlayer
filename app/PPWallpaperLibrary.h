// PPWallpaperLibrary — single source of truth for the on-device library.
//
// Files live under:  ~/Documents/Wallpapers/<UUID>/
//   - <bundle>.wallpaper/    (the unzipped tendies contents)
//   - meta.plist             (display name, source URL, import date)
//   - preview.png            (rendered later, may not exist on first import)
//
// Everything sandboxed inside the app's own Documents — no privilege
// escalation needed for storage. Apply happens via PPApplyBridge.

#import <Foundation/Foundation.h>

@interface PPWallpaperItem : NSObject
@property (nonatomic, copy) NSString *itemID;          // UUID directory name
@property (nonatomic, copy) NSString *displayName;     // shown in the grid
@property (nonatomic, copy) NSString *bundlePath;      // absolute path to the .wallpaper folder
@property (nonatomic, copy) NSString *previewPath;     // absolute path to preview.png (may not exist yet)
@property (nonatomic, strong) NSDate *importedAt;
@end

@interface PPWallpaperLibrary : NSObject

+ (instancetype)shared;

// Force a re-scan from disk. Cheap, safe to call after every import.
- (void)reload;

// All known items, newest first.
- (NSArray<PPWallpaperItem *> *)items;

// Import a .tendies file at `url`. The library copies it into Documents
// and unzips. Returns the new item, or nil + populated `error`.
- (PPWallpaperItem *)importTendiesAtURL:(NSURL *)url
                                  error:(NSError **)error;

// Hard-delete an item from disk.
- (BOOL)deleteItem:(PPWallpaperItem *)item error:(NSError **)error;

@end
