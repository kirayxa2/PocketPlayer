#import "PPCatalogService.h"
#import <objc/runtime.h>

NSErrorDomain const PPCatalogErrorDomain = @"PPCatalog";

// =====================================================================
// Constants
// =====================================================================
//
// Hard-coded for now. If we ever support custom catalogs (user-supplied
// GitHub repos), promote these to NSUserDefaults-backed properties.
static NSString *const kRepoOwner   = @"SerStars";
static NSString *const kRepoName    = @"Nugget-Wallpapers";
static NSString *const kRepoBranch  = @"main";

// Catalog metadata is cheap (one API call, ~100KB JSON). Refresh every
// 6 hours so a typical user spends well under the 60/hour unauthenticated
// rate limit. Pull-to-refresh in the UI bypasses this.
static NSTimeInterval const kCacheMaxAge = 6 * 60 * 60;

// Where we keep the cached catalog JSON and downloaded .tendies files.
static NSString *PPCacheRoot(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [caches stringByAppendingPathComponent:@"OnlineCatalog"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return root;
}

@interface PPCatalogService () <NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSArray<PPCatalogItem *> *cache;
@property (nonatomic, strong) NSDate *cacheLoadedAt;
@end

@implementation PPCatalogService

+ (instancetype)shared {
    static PPCatalogService *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PPCatalogService new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest  = 20;
        cfg.timeoutIntervalForResource = 90;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _githubToken = [[NSUserDefaults standardUserDefaults]
                        stringForKey:@"PPGitHubToken"];
        [self loadCacheFromDisk];
    }
    return self;
}

- (void)setGithubToken:(NSString *)githubToken {
    _githubToken = [githubToken copy];
    if (githubToken.length) {
        [[NSUserDefaults standardUserDefaults]
            setObject:githubToken forKey:@"PPGitHubToken"];
    } else {
        [[NSUserDefaults standardUserDefaults]
            removeObjectForKey:@"PPGitHubToken"];
    }
}

#pragma mark Cache I/O

// Cache layout:
//   <CachesRoot>/OnlineCatalog/index.json     <- the parsed item list
//   <CachesRoot>/OnlineCatalog/index.meta     <- last-load timestamp
//   <CachesRoot>/OnlineCatalog/files/<sha>... <- downloaded .tendies files

- (NSString *)indexPath { return [PPCacheRoot() stringByAppendingPathComponent:@"index.json"]; }
- (NSString *)metaPath  { return [PPCacheRoot() stringByAppendingPathComponent:@"index.meta"]; }
- (NSString *)filesDir  {
    NSString *p = [PPCacheRoot() stringByAppendingPathComponent:@"files"];
    [[NSFileManager defaultManager] createDirectoryAtPath:p
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return p;
}

- (void)loadCacheFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:[self indexPath]];
    if (!data) return;
    NSError *err = nil;
    NSArray *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![raw isKindOfClass:[NSArray class]]) return;

    NSMutableArray<PPCatalogItem *> *items = [NSMutableArray array];
    for (NSDictionary *d in raw) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        PPCatalogItem *it = [PPCatalogItem new];
        it.displayName = d[@"displayName"];
        it.category    = d[@"category"];
        it.repoPath    = d[@"repoPath"];
        it.downloadURL = d[@"downloadURL"];
        it.previewURL  = d[@"previewURL"];
        it.sizeBytes   = [d[@"sizeBytes"] longLongValue];
        if (it.displayName.length && it.downloadURL.length) [items addObject:it];
    }
    self.cache = items;

    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[self metaPath]];
    NSNumber *ts = meta[@"loadedAt"];
    if ([ts isKindOfClass:[NSNumber class]]) {
        self.cacheLoadedAt = [NSDate dateWithTimeIntervalSince1970:ts.doubleValue];
    }
}

- (void)saveCacheToDisk {
    NSMutableArray *raw = [NSMutableArray array];
    for (PPCatalogItem *it in self.cache) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"displayName"] = it.displayName ?: @"";
        d[@"category"]    = it.category    ?: @"";
        d[@"repoPath"]    = it.repoPath    ?: @"";
        d[@"downloadURL"] = it.downloadURL ?: @"";
        if (it.previewURL.length) d[@"previewURL"] = it.previewURL;
        d[@"sizeBytes"]   = @(it.sizeBytes);
        [raw addObject:d];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:raw options:0 error:NULL];
    if (data) [data writeToFile:[self indexPath] atomically:YES];

    NSDate *now = [NSDate date];
    self.cacheLoadedAt = now;
    NSDictionary *meta = @{ @"loadedAt": @(now.timeIntervalSince1970) };
    [meta writeToFile:[self metaPath] atomically:YES];
}

- (BOOL)cacheIsFresh {
    if (!self.cacheLoadedAt || self.cache.count == 0) return NO;
    return [[NSDate date] timeIntervalSinceDate:self.cacheLoadedAt] < kCacheMaxAge;
}

#pragma mark Catalog fetch

- (void)fetchCatalogForceRefresh:(BOOL)forceRefresh
                      completion:(void (^)(NSArray<PPCatalogItem *> *,
                                           NSError * _Nullable))completion {
    // Serve from cache if it's fresh and nobody asked us to refresh.
    if (!forceRefresh && [self cacheIsFresh]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(self.cache, nil);
        });
        return;
    }

    // GitHub Trees API: one call returns the whole repo's file tree.
    // recursive=1 walks subdirectories. Response has {"tree":[...],"truncated":bool}.
    NSString *u = [NSString stringWithFormat:
        @"https://api.github.com/repos/%@/%@/git/trees/%@?recursive=1",
        kRepoOwner, kRepoName, kRepoBranch];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"PocketPoster/0.1" forHTTPHeaderField:@"User-Agent"];
    if (self.githubToken.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.githubToken]
            forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        // Always trampoline back to main before invoking the caller.
        void (^hand)(NSArray *, NSError *) = ^(NSArray *items, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(items, err); });
        };

        if (e) {
            // Network error -- fall back to whatever we cached, if any.
            if (self.cache.count) {
                hand(self.cache, nil);
            } else {
                hand(nil, [NSError errorWithDomain:PPCatalogErrorDomain
                                              code:PPCatalogErrorNetworkFailure
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                     e.localizedDescription ?: @"Network error"}]);
            }
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        if (http.statusCode == 403 || http.statusCode == 429) {
            hand(self.cache.count ? self.cache : nil,
                 [NSError errorWithDomain:PPCatalogErrorDomain
                                     code:PPCatalogErrorRateLimited
                                 userInfo:@{NSLocalizedDescriptionKey:
                                            @"GitHub rate limit reached. Try again later."}]);
            return;
        }
        if (http.statusCode < 200 || http.statusCode >= 300) {
            hand(self.cache.count ? self.cache : nil,
                 [NSError errorWithDomain:PPCatalogErrorDomain
                                     code:PPCatalogErrorNetworkFailure
                                 userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}]);
            return;
        }

        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                              options:0
                                                                error:NULL];
        NSArray *tree = root[@"tree"];
        if (![tree isKindOfClass:[NSArray class]]) {
            hand(nil, [NSError errorWithDomain:PPCatalogErrorDomain
                                          code:PPCatalogErrorParseFailure
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                 @"Unexpected response shape"}]);
            return;
        }

        NSArray<PPCatalogItem *> *parsed = [self parseTree:tree];
        if (parsed.count == 0) {
            hand(nil, [NSError errorWithDomain:PPCatalogErrorDomain
                                          code:PPCatalogErrorEmpty
                                      userInfo:@{NSLocalizedDescriptionKey:
                                                 @"No wallpapers found in repo"}]);
            return;
        }

        self.cache = parsed;
        [self saveCacheToDisk];
        hand(parsed, nil);
    }];
    [task resume];
}

// Walks the GitHub tree response. Each entry looks like:
//   { "path": "wallpapers/custom/woopah_3.tendies",
//     "type": "blob",
//     "size": 12345,
//     "sha":  "abc...",
//     "url":  "...api..." }
//
// We pick out blobs ending in .tendies, derive the category from the
// parent dir, and pair with a sibling .png if present.
- (NSArray<PPCatalogItem *> *)parseTree:(NSArray *)tree {
    // Index by path (without extension) so we can pair .tendies with .png.
    NSMutableDictionary<NSString *, NSDictionary *> *byBaseTendies = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *>     *byBasePreview = [NSMutableDictionary dictionary];

    for (NSDictionary *entry in tree) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = entry[@"type"];
        NSString *path = entry[@"path"];
        if (![type isEqualToString:@"blob"]) continue;
        if (![path isKindOfClass:[NSString class]] || !path.length) continue;
        // Only files inside wallpapers/.
        if (![path hasPrefix:@"wallpapers/"]) continue;

        NSString *low = path.lowercaseString;
        NSString *base = [path stringByDeletingPathExtension];

        if ([low hasSuffix:@".tendies"]) {
            byBaseTendies[base] = entry;
        } else if ([low hasSuffix:@".png"]
                   || [low hasSuffix:@".jpg"]
                   || [low hasSuffix:@".jpeg"]
                   || [low hasSuffix:@".webp"]) {
            // Keep the FULL preview path (with original extension) so we
            // can build the raw URL with the right suffix.
            byBasePreview[base] = path;
        }
    }

    NSMutableArray<PPCatalogItem *> *out = [NSMutableArray array];
    for (NSString *base in byBaseTendies) {
        NSDictionary *entry = byBaseTendies[base];
        NSString *path = entry[@"path"];

        PPCatalogItem *it = [PPCatalogItem new];
        // wallpapers/<category>/<file>.tendies  ->  category = "<category>"
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        if (parts.count >= 3) {
            it.category = [parts[1] capitalizedString];
        } else {
            it.category = @"Other";
        }
        // Display name = file stem with _ -> space, capitalized words.
        NSString *stem = [[path lastPathComponent] stringByDeletingPathExtension];
        stem = [stem stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        stem = [stem stringByReplacingOccurrencesOfString:@"-" withString:@" "];
        it.displayName = stem.length ? stem : @"Wallpaper";
        it.repoPath    = path;
        it.downloadURL = [self rawURLForPath:path];

        NSString *previewPath = byBasePreview[base];
        if (previewPath.length) {
            it.previewURL = [self rawURLForPath:previewPath];
        }

        NSNumber *size = entry[@"size"];
        if ([size isKindOfClass:[NSNumber class]]) it.sizeBytes = size.longLongValue;

        [out addObject:it];
    }

    // Stable sort: category, then name.
    [out sortUsingComparator:^NSComparisonResult(PPCatalogItem *a, PPCatalogItem *b) {
        NSComparisonResult c = [a.category caseInsensitiveCompare:b.category];
        if (c != NSOrderedSame) return c;
        return [a.displayName caseInsensitiveCompare:b.displayName];
    }];
    return out;
}

- (NSString *)rawURLForPath:(NSString *)path {
    // GitHub's CDN. Doesn't share the API rate limit.
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]];
    return [NSString stringWithFormat:
        @"https://raw.githubusercontent.com/%@/%@/%@/%@",
        kRepoOwner, kRepoName, kRepoBranch, encoded];
}

#pragma mark Categories / filtering

- (NSArray<NSString *> *)categoriesIncludingAll:(BOOL)includeAll {
    NSMutableSet *set = [NSMutableSet set];
    for (PPCatalogItem *it in self.cache) {
        if (it.category.length) [set addObject:it.category];
    }
    NSArray *sorted = [set.allObjects sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    if (includeAll) {
        NSMutableArray *with = [NSMutableArray arrayWithObject:@"All"];
        [with addObjectsFromArray:sorted];
        return with;
    }
    return sorted;
}

- (NSArray<PPCatalogItem *> *)itemsForCategory:(NSString *)category {
    if (!category.length || [category isEqualToString:@"All"]) return self.cache ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (PPCatalogItem *it in self.cache) {
        if ([it.category caseInsensitiveCompare:category] == NSOrderedSame) [out addObject:it];
    }
    return out;
}

#pragma mark Download

// Cached file path for a given item. Same .tendies always lands in the
// same place so a re-tap doesn't re-download.
- (NSString *)localPathForItem:(PPCatalogItem *)item {
    NSString *safe = [item.repoPath stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [[self filesDir] stringByAppendingPathComponent:safe];
}

- (void)downloadItem:(PPCatalogItem *)item
            progress:(void (^)(double))progressBlock
          completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion {
    NSString *local = [self localPathForItem:item];

    // Already downloaded?
    if ([[NSFileManager defaultManager] fileExistsAtPath:local]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) progressBlock(1.0);
            completion(local, nil);
        });
        return;
    }

    NSURL *url = [NSURL URLWithString:item.downloadURL];
    if (!url) {
        completion(nil, [NSError errorWithDomain:PPCatalogErrorDomain
                                            code:PPCatalogErrorNetworkFailure
                                        userInfo:@{NSLocalizedDescriptionKey:
                                                   @"Bad download URL"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"PocketPoster/0.1" forHTTPHeaderField:@"User-Agent"];

    // Use a download task with a delegate-backed session so we can
    // surface progress per chunk. We store the progressBlock on the
    // task via objc_setAssociatedObject for retrieval in the delegate.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest  = 30;
    cfg.timeoutIntervalForResource = 180;
    NSURLSession *dl = [NSURLSession sessionWithConfiguration:cfg
                                                     delegate:self
                                                delegateQueue:nil];

    NSURLSessionDownloadTask *task = [dl downloadTaskWithRequest:req];
    // Stash both blocks AND the destination path on the task.
    task.taskDescription = local;
    [self setProgress:progressBlock completion:completion forTask:task];
    [task resume];
}

// Tiny associated-objects helper to attach the per-task callback pair.
- (void)setProgress:(void (^_Nullable)(double))p
         completion:(void (^)(NSString *, NSError *))c
            forTask:(NSURLSessionTask *)t {
    NSMutableDictionary *cbs = objc_getAssociatedObject(t, "PPCBs");
    if (!cbs) {
        cbs = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(t, "PPCBs", cbs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (p) cbs[@"p"] = [p copy];
    cbs[@"c"] = [c copy];
}

#pragma mark NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)total
totalBytesExpectedToWrite:(int64_t)expected {
    NSDictionary *cbs = objc_getAssociatedObject(task, "PPCBs");
    void (^p)(double) = cbs[@"p"];
    if (p && expected > 0) {
        double pct = (double)total / (double)expected;
        dispatch_async(dispatch_get_main_queue(), ^{ p(pct); });
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)location {
    NSString *dst = task.taskDescription;
    NSError *moveErr = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dst error:NULL];
    [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dst] error:&moveErr];

    NSDictionary *cbs = objc_getAssociatedObject(task, "PPCBs");
    void (^c)(NSString *, NSError *) = cbs[@"c"];
    if (c) {
        dispatch_async(dispatch_get_main_queue(), ^{
            c(moveErr ? nil : dst, moveErr);
        });
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;
    NSDictionary *cbs = objc_getAssociatedObject(task, "PPCBs");
    void (^c)(NSString *, NSError *) = cbs[@"c"];
    if (c) {
        dispatch_async(dispatch_get_main_queue(), ^{
            c(nil, error);
        });
    }
}

@end
