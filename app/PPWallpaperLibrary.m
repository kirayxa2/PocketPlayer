#import "PPWallpaperLibrary.h"

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

- (PPWallpaperItem *)importTendiesAtURL:(NSURL *)url
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

    if (!PPUnzipFile(stagedZip, itemDir, error)) {
        [fm removeItemAtPath:itemDir error:NULL];
        return nil;
    }
    [fm removeItemAtPath:stagedZip error:NULL];

    // Find the .wallpaper folder produced by unzip.
    NSArray *kids = [fm contentsOfDirectoryAtPath:itemDir error:NULL];
    NSString *bundle = nil;
    for (NSString *k in kids) {
        if ([k hasSuffix:@".wallpaper"]) { bundle = k; break; }
    }
    if (!bundle) {
        if (error) *error = [NSError errorWithDomain:@"PocketPoster" code:1
                              userInfo:@{NSLocalizedDescriptionKey:
                                  @"Archive does not contain a .wallpaper bundle"}];
        [fm removeItemAtPath:itemDir error:NULL];
        return nil;
    }

    NSString *displayName = [[url.lastPathComponent stringByDeletingPathExtension]
                             stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    NSDictionary *meta = @{
        @"displayName": displayName ?: bundle,
        @"importedAt":  [NSDate date],
        @"sourceURL":   url.absoluteString ?: @"",
    };
    [meta writeToFile:[itemDir stringByAppendingPathComponent:@"meta.plist"]
            atomically:YES];

    [self reload];
    for (PPWallpaperItem *it in self.cache) {
        if ([it.itemID isEqualToString:uuid]) return it;
    }
    return nil;
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
