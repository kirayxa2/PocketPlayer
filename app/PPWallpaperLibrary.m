#import "PPWallpaperLibrary.h"
#import "PPPreviewRenderer.h"
#import "PPWallpaperResizer.h"
#import <UIKit/UIKit.h>

@implementation PPWallpaperItem
@end

@interface PPWallpaperLibrary ()
@property (nonatomic, strong) NSMutableArray<PPWallpaperItem *> *cache;
@end

@implementation PPWallpaperLibrary

+ (instancetype)shared {
    static PPWallpaperLibrary *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PPWallpaperLibrary new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableArray array];
        [self reload];
    }
    return self;
}

#pragma mark Paths

// ~/Documents/Wallpapers/   — created lazily on first access.
- (NSString *)libraryRoot {
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [docs stringByAppendingPathComponent:@"Wallpapers"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return root;
}

#pragma mark Reload

- (void)reload {
    [self.cache removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self libraryRoot];

    NSError *err = nil;
    NSArray *names = [fm contentsOfDirectoryAtPath:root error:&err];
    for (NSString *name in names) {
        NSString *dir = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;

        // Find the .wallpaper folder inside the UUID dir.
        NSArray *kids = [fm contentsOfDirectoryAtPath:dir error:NULL];
        NSString *bundle = nil;
        for (NSString *k in kids) {
            if ([k hasSuffix:@".wallpaper"]) { bundle = k; break; }
        }
        if (!bundle) continue; // half-imported, skip

        PPWallpaperItem *it = [PPWallpaperItem new];
        it.itemID      = name;
        it.bundlePath  = [dir stringByAppendingPathComponent:bundle];
        it.previewPath = [dir stringByAppendingPathComponent:@"preview.png"];

        // Read meta.plist if present, else fall back to bundle name.
        NSString *metaPath = [dir stringByAppendingPathComponent:@"meta.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        it.displayName = meta[@"displayName"] ?: [bundle stringByDeletingPathExtension];
        it.importedAt  = meta[@"importedAt"] ?: [NSDate distantPast];

        [self.cache addObject:it];
    }

    [self.cache sortUsingComparator:^NSComparisonResult(PPWallpaperItem *a, PPWallpaperItem *b) {
        return [b.importedAt compare:a.importedAt];
    }];
}

- (NSArray<PPWallpaperItem *> *)items {
    return [self.cache copy];
}

#pragma mark Import

// Native unzip: invoke the system's libcompression / libarchive isn't
// straightforward, so we shell out to /usr/bin/unzip when present, or
// otherwise rely on a tiny inline ZIP reader. For v0.1 we use a very
// small private helper that handles only standard (non-encrypted) ZIPs,
// which is what every .tendies in the wild is. We expose it as a
// separate function so we can swap in libarchive later.
static BOOL PPUnzipFile(NSString *src, NSString *dst, NSError **error);

// Recursively walk `root` (depth-first, breadth-balanced) up to `maxDepth`
// and return the first directory whose name ends in `.wallpaper`, OR if
// none is found, the parent directory of any `*.ca` folder that contains
// `main.caml`. Returns nil if neither pattern matches.
//
// Real-world .tendies layouts seen in the wild:
//   A. Foo.tendies/Foo.wallpaper/Floating.ca/main.caml   (clean)
//   B. Foo.tendies/Floating.ca/main.caml                 (no .wallpaper)
//   C. Foo.tendies/__MACOSX/... + Foo.wallpaper/...       (Mac packers)
//   D. Foo.tendies/Random/Foo.wallpaper/...               (nested)
static NSString *PPFindWallpaperBundleDir(NSString *root, BOOL *needsWrap) {
    if (needsWrap) *needsWrap = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *queue = [NSMutableArray arrayWithObject:root];
    NSString *fallbackCAParent = nil;

    int visited = 0;
    while (queue.count > 0 && visited < 1024) {
        NSString *dir = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;

        NSArray *kids = [fm contentsOfDirectoryAtPath:dir error:NULL];
        if (!kids) continue;

        for (NSString *kid in kids) {
            // Skip Mac metadata dumps.
            if ([kid hasPrefix:@"__MACOSX"]) continue;
            if ([kid hasPrefix:@"."])         continue;

            NSString *kidPath = [dir stringByAppendingPathComponent:kid];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:kidPath isDirectory:&isDir] || !isDir) continue;

            // Best case: a real .wallpaper folder.
            if ([kid hasSuffix:@".wallpaper"]) {
                if (needsWrap) *needsWrap = NO;
                return kidPath;
            }

            // Second best: a *.ca folder with main.caml inside. Remember
            // its parent so we can wrap it later if no .wallpaper exists.
            if ([kid hasSuffix:@".ca"]) {
                NSString *caml = [kidPath stringByAppendingPathComponent:@"main.caml"];
                if ([fm fileExistsAtPath:caml] && !fallbackCAParent) {
                    fallbackCAParent = dir;
                }
            }

            [queue addObject:kidPath];
        }
    }

    if (fallbackCAParent) {
        if (needsWrap) *needsWrap = YES;
        return fallbackCAParent;
    }
    return nil;
}

// Build a "what's actually in this archive" snippet for error messages.
// Helps the user (and us) debug weird .tendies layouts without SSH.
static NSString *PPDescribeArchiveContents(NSString *root) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:root];
    NSString *p;
    int count = 0;
    while ((p = [e nextObject]) && count < 12) {
        if ([p hasPrefix:@"__MACOSX"]) continue;
        [lines addObject:p];
        count++;
    }
    if (lines.count == 0) return @"(empty)";
    NSString *joined = [lines componentsJoinedByString:@"\n  "];
    return [@"  " stringByAppendingString:joined];
}

- (PPWallpaperItem *)importTendiesAtURL:(NSURL *)url
                                  error:(NSError **)error {
    // Backwards-compatible one-shot. Unpacks AND resizes to the main
    // screen in a single call; returns the ready-to-display item.
    PPWallpaperItem *it = [self beginImportTendiesAtURL:url error:error];
    if (!it) return nil;
    UIScreen *s = [UIScreen mainScreen];
    NSError *re = nil;
    if (![self resizeItem:it toSize:s.bounds.size error:&re]) {
        // Resize failure isn't fatal -- the unscaled bundle still
        // renders, just with the canvas-fit hack the runtime applies.
        // Log it via the caller's error pointer if they passed one but
        // the item is otherwise valid.
        if (error && !*error) *error = re;
    }
    return it;
}

- (PPWallpaperItem *)beginImportTendiesAtURL:(NSURL *)url
                                       error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self libraryRoot];

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *itemDir = [root stringByAppendingPathComponent:uuid];
    if (![fm createDirectoryAtPath:itemDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:error]) {
        return nil;
    }

    // Stage the source zip into the item dir. URLs from the document
    // picker are sometimes coordinated -- accessing the resource scope
    // here is the safe path.
    NSString *stagedZip = [itemDir stringByAppendingPathComponent:@"src.tendies"];
    BOOL gotData = NO;
    if ([url startAccessingSecurityScopedResource]) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        [url stopAccessingSecurityScopedResource];
        if (data) {
            [data writeToFile:stagedZip atomically:YES];
            gotData = YES;
        }
    }
    if (!gotData) {
        // Last-resort copy (works for files in our own sandbox / Inbox).
        if (![fm copyItemAtPath:url.path toPath:stagedZip error:error]) {
            [fm removeItemAtPath:itemDir error:NULL];
            return nil;
        }
    }

    // Default display name from the source filename: "mario_galaxy.tendies"
    // -> "mario galaxy". Caller of -beginImportTendiesAtPath:displayName:
    // can override this by passing a non-nil string.
    NSString *baseFromURL = [[url.lastPathComponent stringByDeletingPathExtension]
                             stringByReplacingOccurrencesOfString:@"_" withString:@" "];

    return [self _finishStagedImportAtItemDir:itemDir
                                    stagedZip:stagedZip
                                  displayName:baseFromURL
                                    sourceURL:url.absoluteString
                                        error:error];
}

- (PPWallpaperItem *)beginImportTendiesAtPath:(NSString *)path
                                  displayName:(NSString *)displayName
                                        error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self libraryRoot];

    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *itemDir = [root stringByAppendingPathComponent:uuid];
    if (![fm createDirectoryAtPath:itemDir
       withIntermediateDirectories:YES
                        attributes:nil
                             error:error]) {
        return nil;
    }

    // Already a plain absolute path inside our sandbox -- no security
    // scope dance, just copy.
    NSString *stagedZip = [itemDir stringByAppendingPathComponent:@"src.tendies"];
    if (![fm copyItemAtPath:path toPath:stagedZip error:error]) {
        [fm removeItemAtPath:itemDir error:NULL];
        return nil;
    }

    // Use caller's displayName if provided, else stem-of-filename.
    NSString *fallback = [[[path lastPathComponent] stringByDeletingPathExtension]
                          stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    NSString *useName = displayName.length ? displayName : fallback;

    return [self _finishStagedImportAtItemDir:itemDir
                                    stagedZip:stagedZip
                                  displayName:useName
                                    sourceURL:path
                                        error:error];
}

// Shared tail of both -beginImportTendiesAtURL: and ...AtPath:. The two
// public entries differ only in HOW they get the .tendies bytes onto
// disk (security-scoped URL read vs. plain copy). After that, the work
// is identical: unzip, locate the wallpaper bundle, wrap it if needed,
// drop scratch, write meta, reload.
- (PPWallpaperItem *)_finishStagedImportAtItemDir:(NSString *)itemDir
                                        stagedZip:(NSString *)stagedZip
                                      displayName:(NSString *)displayName
                                        sourceURL:(NSString *)sourceURL
                                            error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Unzip into a scratch subdir (NOT itemDir directly) so we can move
    // just the relevant payload into place after we figure out the
    // archive's layout. Avoids littering itemDir with __MACOSX/ etc.
    NSString *scratch = [itemDir stringByAppendingPathComponent:@"_unpack"];
    [fm createDirectoryAtPath:scratch
  withIntermediateDirectories:YES
                   attributes:nil
                        error:NULL];
    if (!PPUnzipFile(stagedZip, scratch, error)) {
        [fm removeItemAtPath:itemDir error:NULL];
        return nil;
    }
    [fm removeItemAtPath:stagedZip error:NULL];

    // Try to find a .wallpaper bundle anywhere in the unpacked tree, or
    // failing that the parent of a *.ca/main.caml pair.
    BOOL needsWrap = NO;
    NSString *foundDir = PPFindWallpaperBundleDir(scratch, &needsWrap);

    if (!foundDir) {
        NSString *contents = PPDescribeArchiveContents(scratch);
        NSString *msg = [NSString stringWithFormat:
            @"Couldn't find a wallpaper bundle in this .tendies file.\n\n"
            @"Looked for any *.wallpaper folder, or any *.ca/main.caml.\n"
            @"Archive contents (first 12 entries):\n%@", contents];
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:1
                              userInfo:@{NSLocalizedDescriptionKey: msg}];
        [fm removeItemAtPath:itemDir error:NULL];
        return nil;
    }

    // Decide the bundle name and (if needed) wrap a bare *.ca tree into
    // a synthetic .wallpaper folder so the rest of the codebase (and
    // PosterPlayer itself) sees the layout it expects.
    NSString *bundleName;
    NSString *bundlePath;

    if (needsWrap) {
        // foundDir is the parent of a *.ca/main.caml. Wrap it.
        bundleName = [displayName stringByAppendingPathExtension:@"wallpaper"];
        bundlePath = [itemDir stringByAppendingPathComponent:bundleName];
        [fm createDirectoryAtPath:bundlePath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
        // Move every non-junk child of foundDir into the new .wallpaper.
        for (NSString *kid in [fm contentsOfDirectoryAtPath:foundDir error:NULL]) {
            if ([kid hasPrefix:@"__MACOSX"]) continue;
            NSString *src = [foundDir stringByAppendingPathComponent:kid];
            NSString *dst = [bundlePath stringByAppendingPathComponent:kid];
            [fm moveItemAtPath:src toPath:dst error:NULL];
        }
    } else {
        // foundDir IS the .wallpaper -- move it up to itemDir level.
        bundleName = [foundDir lastPathComponent];
        bundlePath = [itemDir stringByAppendingPathComponent:bundleName];
        [fm moveItemAtPath:foundDir toPath:bundlePath error:NULL];
    }

    // Drop the scratch tree (and any __MACOSX/ etc. left in it).
    [fm removeItemAtPath:scratch error:NULL];

    NSDictionary *meta = @{
        @"displayName": displayName.length ? displayName : [bundleName stringByDeletingPathExtension],
        @"importedAt":  [NSDate date],
        @"sourceURL":   sourceURL ?: @"",
        @"wrapped":     @(needsWrap),
    };
    [meta writeToFile:[itemDir stringByAppendingPathComponent:@"meta.plist"]
            atomically:YES];

    // Don't render preview here -- the caller will trigger that once
    // the resize stage completes (otherwise we'd render a preview of
    // the unscaled CAML, which then needs re-rendering).

    [self reload];
    NSString *uuid = itemDir.lastPathComponent;
    for (PPWallpaperItem *it in self.cache) {
        if ([it.itemID isEqualToString:uuid]) return it;
    }
    return nil;
}

- (BOOL)resizeItem:(PPWallpaperItem *)item
            toSize:(CGSize)targetSize
             error:(NSError **)error {
    if (!item.bundlePath.length) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:40
            userInfo:@{NSLocalizedDescriptionKey: @"Item has no bundle path"}];
        return NO;
    }

    if (![PPWallpaperResizer resizeBundleAtPath:item.bundlePath
                                         toSize:targetSize
                                          error:error]) {
        return NO;
    }

    // Preview is now safe to render: it'll reflect the rescaled CAML.
    NSString *root = [self libraryRoot];
    NSString *itemDir = [root stringByAppendingPathComponent:item.itemID];
    NSString *previewPath = [itemDir stringByAppendingPathComponent:@"preview.png"];
    NSString *bundleForPreview = [item.bundlePath copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [PPPreviewRenderer renderPreviewForBundle:bundleForPreview
                                             size:CGSizeMake(360, 640)
                                          outPath:previewPath
                                            error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"PPWallpaperPreviewDidUpdate"
                              object:nil];
        });
    });

    return YES;
}

- (BOOL)deleteItem:(PPWallpaperItem *)item error:(NSError **)error {
    NSString *root = [self libraryRoot];
    NSString *itemDir = [root stringByAppendingPathComponent:item.itemID];
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:itemDir error:error];
    [self reload];
    return ok;
}

@end

// =====================================================================
// Minimal in-process ZIP extractor.
// We only support classic stored / deflate central-directory archives
// (which is all .tendies files use). No encryption, no zip64. ~120 lines.
// Pulled out as a static so we can replace it with libarchive later.
// =====================================================================

#import <zlib.h>

static uint16_t r16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t r32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL PPUnzipFile(NSString *src, NSString *dstRoot, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:src];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:10
                              userInfo:@{NSLocalizedDescriptionKey:@"Cannot read archive"}];
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger len = data.length;
    if (len < 22) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:11
                              userInfo:@{NSLocalizedDescriptionKey:@"Archive too small"}];
        return NO;
    }

    // Find End of Central Directory record (signature 0x06054b50).
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)len - 22; i >= 0 && i >= (NSInteger)len - 65557; i--) {
        if (r32(bytes + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:12
                              userInfo:@{NSLocalizedDescriptionKey:@"Not a ZIP archive"}];
        return NO;
    }

    uint16_t entries  = r16(bytes + eocd + 10);
    uint32_t cdSize   = r32(bytes + eocd + 12);
    uint32_t cdOffset = r32(bytes + eocd + 16);
    if ((NSUInteger)cdOffset + cdSize > len) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:13
                              userInfo:@{NSLocalizedDescriptionKey:@"Corrupt central directory"}];
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    const uint8_t *cd = bytes + cdOffset;
    const uint8_t *cdEnd = cd + cdSize;

    for (uint16_t i = 0; i < entries; i++) {
        if (cd + 46 > cdEnd) break;
        if (r32(cd) != 0x02014b50) break;

        uint16_t method   = r16(cd + 10);
        uint32_t crc      = r32(cd + 16); (void)crc;
        uint32_t cSize    = r32(cd + 20);
        uint32_t uSize    = r32(cd + 24);
        uint16_t nameLen  = r16(cd + 28);
        uint16_t extraLen = r16(cd + 30);
        uint16_t commLen  = r16(cd + 32);
        uint32_t lhOff    = r32(cd + 42);

        if (cd + 46 + nameLen + extraLen + commLen > cdEnd) break;
        NSString *name = [[NSString alloc] initWithBytes:cd + 46
                                                  length:nameLen
                                                encoding:NSUTF8StringEncoding];
        cd += 46 + nameLen + extraLen + commLen;

        if (!name.length) continue;
        // Reject path traversal.
        if ([name containsString:@".."] || [name hasPrefix:@"/"]) continue;

        // Local header: 30 bytes + nameLen + extraLen, then file data.
        if ((NSUInteger)lhOff + 30 > len) continue;
        const uint8_t *lh = bytes + lhOff;
        if (r32(lh) != 0x04034b50) continue;
        uint16_t lNameLen  = r16(lh + 26);
        uint16_t lExtraLen = r16(lh + 28);
        const uint8_t *fileData = lh + 30 + lNameLen + lExtraLen;
        if ((NSUInteger)(fileData - bytes) + cSize > len) continue;

        NSString *outPath = [dstRoot stringByAppendingPathComponent:name];

        // Directory entry?
        if ([name hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:outPath
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
            continue;
        }
        [fm createDirectoryAtPath:[outPath stringByDeletingLastPathComponent]
       withIntermediateDirectories:YES
                        attributes:nil
                             error:NULL];

        if (method == 0) {
            // Stored.
            NSData *out = [NSData dataWithBytes:fileData length:cSize];
            [out writeToFile:outPath atomically:YES];
        } else if (method == 8) {
            // Deflate via zlib raw inflate.
            NSMutableData *out = [NSMutableData dataWithLength:uSize ?: cSize * 4];
            z_stream z = {0};
            z.next_in   = (Bytef *)fileData;
            z.avail_in  = cSize;
            z.next_out  = out.mutableBytes;
            z.avail_out = (uInt)out.length;
            if (inflateInit2(&z, -15) != Z_OK) continue;
            int rc = inflate(&z, Z_FINISH);
            // Grow buffer if uSize was lying / 0.
            while (rc == Z_BUF_ERROR || (rc == Z_OK && z.avail_out == 0)) {
                NSUInteger old = out.length;
                [out setLength:old * 2 + 1024];
                z.next_out  = (Bytef *)out.mutableBytes + old;
                z.avail_out = (uInt)(out.length - old);
                rc = inflate(&z, Z_FINISH);
            }
            inflateEnd(&z);
            if (rc != Z_STREAM_END) continue;
            [out setLength:z.total_out];
            [out writeToFile:outPath atomically:YES];
        } else {
            // Unknown / encrypted / zip64 — skip.
            continue;
        }
    }
    return YES;
}
