#import "CLIRegistry.h"
#import "TickerPanel.h"

NSString *const CLIUpdateStateQueued = @"queued";
NSString *const CLIUpdateStateRunning = @"running";
NSString *const CLIUpdateStateSucceeded = @"succeeded";
NSString *const CLIUpdateStateFailed = @"failed";

static NSString *const DefaultVersionPattern = @"(\\d+(?:\\.\\d+)+(?:[-+][0-9A-Za-z.]+)?)";
static const NSTimeInterval GitHubCacheLifetime = 6 * 60 * 60;
static const NSTimeInterval ProbeBudget = 25;
static const NSTimeInterval UpdateTimeout = 15 * 60;
static const NSTimeInterval SuccessDisplayDuration = 120;

static NSString *ShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value ?: @"" stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSArray<NSString *> *StringList(id value) {
    if ([value isKindOfClass:[NSString class]]) return @[value];
    if ([value isKindOfClass:[NSArray class]]) return value;
    return @[];
}

static BOOL IsSystemPath(NSString *path) {
    for (NSString *prefix in @[@"/usr/bin/", @"/bin/", @"/usr/sbin/", @"/sbin/", @"/System/", @"/Library/Apple/"]) {
        if ([path hasPrefix:prefix]) return YES;
    }
    return NO;
}

@interface CLIRegistryService ()
@property NSArray<NSDictionary *> *registryEntries;
@property NSString *iconDirectory;
@property NSURL *versionCacheURL;
@property NSURL *githubCacheURL;
@property NSMutableDictionary *versionCache;
@property NSMutableDictionary *githubCache;
@property NSMutableDictionary<NSString *, NSImage *> *iconCache;
@property (nonatomic) NSArray<NSDictionary *> *statuses;
@property (readwrite, getter=isChecking) BOOL checking;
@property BOOL pendingForce;
@property NSArray<NSDictionary *> *pendingInventory;
@property NSMutableDictionary<NSString *, NSMutableDictionary *> *updateStates;
@property NSOperationQueue *updateQueue;
@property NSString *loginPath;
@property NSDate *lastChangeNotification;
@property BOOL changeNotificationScheduled;
@property NSArray<NSDictionary *> *lastInventory;
@end

@implementation CLIRegistryService

- (instancetype)initWithRegistryURL:(NSURL *)registryURL iconDirectory:(NSString *)iconDirectory cacheDirectory:(NSURL *)cacheDirectory {
    self = [super init];
    if (!self) return nil;
    NSData *data = [NSData dataWithContentsOfURL:registryURL];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *entries = [json isKindOfClass:[NSDictionary class]] ? json[@"clis"] : nil;
    self.registryEntries = [entries isKindOfClass:[NSArray class]] ? entries : @[];
    self.iconDirectory = iconDirectory;
    self.versionCacheURL = [cacheDirectory URLByAppendingPathComponent:@"cli-versions.json"];
    self.githubCacheURL = [cacheDirectory URLByAppendingPathComponent:@"github-releases.json"];
    self.versionCache = [self loadJSONDictionary:self.versionCacheURL];
    self.githubCache = [self loadJSONDictionary:self.githubCacheURL];
    self.iconCache = [NSMutableDictionary dictionary];
    self.updateStates = [NSMutableDictionary dictionary];
    self.updateQueue = [[NSOperationQueue alloc] init];
    self.updateQueue.maxConcurrentOperationCount = 1;
    self.statuses = @[];
    return self;
}

- (NSArray<NSDictionary *> *)entries {
    return self.registryEntries;
}

- (NSMutableDictionary *)loadJSONDictionary:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [json isKindOfClass:[NSMutableDictionary class]] ? json : [NSMutableDictionary dictionary];
}

- (void)saveJSONDictionary:(NSDictionary *)dictionary toURL:(NSURL *)url {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:url atomically:YES];
}

#pragma mark Icons

- (NSImage *)iconForEntry:(NSDictionary *)entry {
    NSString *key = entry[@"id"] ?: @"";
    NSImage *cached = self.iconCache[key];
    if (cached) return cached;

    NSImage *image = nil;
    NSString *iconName = entry[@"icon"];
    if ([iconName isKindOfClass:[NSString class]] && iconName.length > 0) {
        NSString *path = [self.iconDirectory stringByAppendingPathComponent:[iconName stringByAppendingPathExtension:@"png"]];
        image = [[NSImage alloc] initWithContentsOfFile:path];
        image.size = NSMakeSize(14, 14);
        image.template = YES;
    }
    if (!image) image = TickerMonogramIcon(entry[@"mark"] ?: entry[@"label"]);
    self.iconCache[key] = image;
    return image;
}

#pragma mark Version helpers

+ (NSString *)versionFromOutput:(NSString *)output pattern:(NSString *)pattern {
    if (output.length == 0) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern.length > 0 ? pattern : DefaultVersionPattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    if (!match) return nil;
    NSRange range = match.numberOfRanges > 1 ? [match rangeAtIndex:1] : match.range;
    if (range.location == NSNotFound) return nil;
    return [output substringWithRange:range];
}

+ (NSArray<NSNumber *> *)numericComponents:(NSString *)version {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *core = [version componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-+ "]].firstObject;
    for (NSString *part in [core componentsSeparatedByString:@"."]) {
        [parts addObject:@([part integerValue])];
    }
    return parts;
}

+ (NSComparisonResult)compareVersion:(NSString *)a toVersion:(NSString *)b {
    NSArray<NSNumber *> *left = [self numericComponents:a ?: @""];
    NSArray<NSNumber *> *right = [self numericComponents:b ?: @""];
    NSUInteger count = MAX(left.count, right.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger l = i < left.count ? left[i].integerValue : 0;
        NSInteger r = i < right.count ? right[i].integerValue : 0;
        if (l < r) return NSOrderedAscending;
        if (l > r) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

#pragma mark Commands

- (NSString *)run:(NSString *)launchPath arguments:(NSArray<NSString *> *)arguments {
    if (!self.commandRunner) return @"";
    return self.commandRunner(launchPath, arguments) ?: @"";
}

// Runs a shell snippet with the user's login PATH, merging stderr into stdout.
- (NSString *)runShell:(NSString *)script {
    NSString *path = self.loginPath.length > 0 ? self.loginPath : @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    return [self run:@"/usr/bin/env" arguments:@[[@"PATH=" stringByAppendingString:path], @"/bin/sh", @"-c", [script stringByAppendingString:@" 2>&1"]]];
}

// One login shell resolves every registry binary plus the login PATH.
- (NSDictionary<NSString *, NSString *> *)resolveBinaries {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *entry in self.registryEntries) [names addObjectsFromArray:StringList(entry[@"bins"])];
    NSMutableArray *quoted = [NSMutableArray array];
    for (NSString *name in names) [quoted addObject:ShellQuote(name)];

    NSString *script = [NSString stringWithFormat:@"print -r -- \"PATH\t$PATH\"; for b in %@; do p=$(whence -p -- \"$b\" 2>/dev/null) && print -r -- \"$b\t$p\"; done", [quoted componentsJoinedByString:@" "]];
    NSString *output = [self run:@"/usr/bin/env" arguments:@[@"zsh", @"-lc", script]];

    NSMutableDictionary *resolved = [NSMutableDictionary dictionary];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange tab = [line rangeOfString:@"\t"];
        if (tab.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:tab.location];
        NSString *value = [line substringFromIndex:tab.location + 1];
        if ([key isEqualToString:@"PATH"]) {
            self.loginPath = value;
        } else if (value.length > 0) {
            resolved[key] = value;
        }
    }
    return resolved;
}

- (NSString *)cacheStampForPath:(NSString *)path {
    NSString *target = [path stringByResolvingSymlinksInPath];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:target error:nil];
    return [NSString stringWithFormat:@"%@|%.0f", target, [attributes.fileModificationDate timeIntervalSince1970]];
}

- (NSString *)probeVersionForEntry:(NSDictionary *)entry path:(NSString *)path force:(BOOL)force {
    NSString *entryId = entry[@"id"];
    NSString *stamp = [self cacheStampForPath:path];
    NSDictionary *cached;
    @synchronized (self.versionCache) { cached = self.versionCache[entryId]; }
    // Shell-derived versions (e.g. extension counts) can change without the binary changing.
    BOOL cacheable = entry[@"versionShell"] == nil;
    if (!force && cacheable && [cached[@"stamp"] isEqualToString:stamp] && cached[@"version"]) return cached[@"version"];

    NSString *output;
    if ([entry[@"versionShell"] isKindOfClass:[NSString class]]) {
        output = [self runShell:entry[@"versionShell"]];
    } else {
        NSMutableArray *words = [NSMutableArray arrayWithObject:ShellQuote(path)];
        for (NSString *argument in StringList(entry[@"versionArgs"] ?: @[@"--version"])) [words addObject:ShellQuote(argument)];
        output = [self runShell:[words componentsJoinedByString:@" "]];
    }
    NSString *version = [CLIRegistryService versionFromOutput:output pattern:entry[@"versionPattern"]];
    if (version && cacheable) {
        @synchronized (self.versionCache) { self.versionCache[entryId] = @{@"stamp": stamp, @"version": version}; }
    }
    return version;
}

- (NSString *)latestGitHubReleaseForRepo:(NSString *)repo {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSDictionary *cached;
    @synchronized (self.githubCache) { cached = self.githubCache[repo]; }
    if (cached && now - [cached[@"fetchedAt"] doubleValue] < GitHubCacheLifetime) return cached[@"tag"];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", repo]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"CLITicker" forHTTPHeaderField:@"User-Agent"];

    __block NSString *tag = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && [(NSHTTPURLResponse *)response statusCode] == 200) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]] && [json[@"tag_name"] isKindOfClass:[NSString class]]) tag = json[@"tag_name"];
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    // Cache failures too (with the stale tag, if any) so a rate limit does not trigger a request per refresh.
    NSString *result = tag ?: cached[@"tag"];
    @synchronized (self.githubCache) {
        self.githubCache[repo] = result ? @{@"tag": result, @"fetchedAt": @(now)} : @{@"fetchedAt": @(now)};
    }
    return result;
}

#pragma mark Refresh

- (NSDictionary *)inventoryItemForNames:(NSArray<NSString *> *)names source:(NSString *)source inventory:(NSArray<NSDictionary *> *)inventory {
    for (NSString *name in names) {
        NSString *shortName = name.lastPathComponent;
        for (NSDictionary *item in inventory) {
            if (![item[@"source"] isEqualToString:source]) continue;
            if ([item[@"name"] isEqualToString:name] || [item[@"name"] isEqualToString:shortName]) return item;
        }
    }
    return nil;
}

- (void)refreshWithInventory:(NSArray<NSDictionary *> *)items force:(BOOL)force {
    if (self.checking) {
        self.pendingInventory = items ?: @[];
        self.pendingForce = self.pendingForce || force;
        return;
    }
    self.checking = YES;
    self.lastInventory = items ?: @[];
    [self notifyChange];

    NSArray *inventory = [items copy] ?: @[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *resolved = [self resolveBinaries];
        NSMutableDictionary<NSString *, NSDictionary *> *results = [NSMutableDictionary dictionary];
        NSLock *lock = [[NSLock alloc] init];
        dispatch_group_t group = dispatch_group_create();

        for (NSDictionary *entry in self.registryEntries) {
            NSString *path = nil;
            for (NSString *bin in StringList(entry[@"bins"])) {
                path = resolved[bin];
                if (path) break;
            }
            if (!path) continue;

            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSDictionary *status = [self statusForEntry:entry path:path inventory:inventory force:force];
                if (!status) return;
                [lock lock];
                results[entry[@"id"]] = status;
                [lock unlock];
            });
        }

        // A hung probe must not freeze the list; late results are dropped until the next refresh.
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ProbeBudget * NSEC_PER_SEC)));
        [lock lock];
        NSDictionary *snapshot = [results copy];
        [lock unlock];

        NSMutableArray *ordered = [NSMutableArray array];
        for (NSDictionary *entry in self.registryEntries) {
            NSDictionary *status = snapshot[entry[@"id"]];
            if (status) [ordered addObject:status];
        }
        @synchronized (self.versionCache) { [self saveJSONDictionary:self.versionCache toURL:self.versionCacheURL]; }
        @synchronized (self.githubCache) { [self saveJSONDictionary:self.githubCache toURL:self.githubCacheURL]; }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statuses = ordered;
            self.checking = NO;
            [self notifyChange];
            if (self.pendingInventory) {
                NSArray *pending = self.pendingInventory;
                BOOL pendingForce = self.pendingForce;
                self.pendingInventory = nil;
                self.pendingForce = NO;
                [self refreshWithInventory:pending force:pendingForce];
            }
        });
    });
}

- (NSDictionary *)statusForEntry:(NSDictionary *)entry path:(NSString *)path inventory:(NSArray<NSDictionary *> *)inventory force:(BOOL)force {
    NSString *version = [self probeVersionForEntry:entry path:path force:force];
    NSString *hideWhen = entry[@"hideWhenVersion"];
    if (hideWhen && (!version || [version isEqualToString:hideWhen])) return nil;

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"kind"] = @"registry";
    status[@"id"] = entry[@"id"];
    status[@"title"] = entry[@"label"] ?: entry[@"id"];
    status[@"path"] = path;
    if (version) status[@"version"] = version;
    status[@"state"] = @"unknown";

    NSDictionary *brewItem = [self inventoryItemForNames:StringList(entry[@"brew"]) source:@"Homebrew" inventory:inventory];
    NSDictionary *caskItem = [self inventoryItemForNames:StringList(entry[@"cask"]) source:@"Homebrew Cask" inventory:inventory];
    NSDictionary *npmItem = [self inventoryItemForNames:StringList(entry[@"npm"]) source:@"npm global" inventory:inventory];
    NSString *resolvedTarget = [path stringByResolvingSymlinksInPath];
    BOOL brewPath = [resolvedTarget containsString:@"/Cellar/"] || [resolvedTarget containsString:@"/Caskroom/"] || [path hasPrefix:@"/opt/homebrew/"];
    BOOL npmPath = [resolvedTarget containsString:@"/node_modules/"];

    NSDictionary *inventoryItem = nil;
    if (brewItem && (brewPath || !npmPath)) {
        inventoryItem = brewItem;
        status[@"via"] = @"brew";
    } else if (caskItem && !npmPath) {
        inventoryItem = caskItem;
        status[@"via"] = @"cask";
    } else if (npmItem) {
        inventoryItem = npmItem;
        status[@"via"] = @"npm";
    }

    if (inventoryItem) {
        // Package-manager state comes from the inventory scan (brew outdated / npm outdated -g).
        BOOL outdated = [inventoryItem[@"status"] isEqualToString:@"outdated"];
        status[@"state"] = outdated ? @"outdated" : @"current";
        if (outdated && inventoryItem[@"latestVersion"]) status[@"latest"] = inventoryItem[@"latestVersion"];
        if (!version && inventoryItem[@"currentVersion"]) status[@"version"] = inventoryItem[@"currentVersion"];
        NSString *command = self.inventoryUpdateCommand ? self.inventoryUpdateCommand(inventoryItem) : nil;
        if (command.length > 0) status[@"updateCommand"] = command;
        status[@"inventoryItem"] = inventoryItem;
    } else if (IsSystemPath(path) && !entry[@"selfUpdate"]) {
        status[@"state"] = @"system";
        status[@"via"] = @"system";
    } else {
        status[@"via"] = entry[@"via"] ?: @"self";
        if ([entry[@"selfUpdate"] isKindOfClass:[NSString class]]) status[@"updateCommand"] = entry[@"selfUpdate"];

        NSDictionary *check = entry[@"check"];
        NSString *repo = entry[@"github"];
        if ([check isKindOfClass:[NSDictionary class]] && [check[@"command"] isKindOfClass:[NSString class]]) {
            NSString *output = [[self runShell:check[@"command"]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([check[@"outdatedWhenOutput"] boolValue]) {
                status[@"state"] = output.length > 0 ? @"outdated" : @"current";
            } else {
                NSString *latest = [CLIRegistryService versionFromOutput:output pattern:check[@"latestPattern"]];
                if (latest && version) {
                    status[@"latest"] = latest;
                    status[@"state"] = [CLIRegistryService compareVersion:version toVersion:latest] == NSOrderedAscending ? @"outdated" : @"current";
                }
            }
        } else if ([repo isKindOfClass:[NSString class]] && version) {
            NSString *tag = [self latestGitHubReleaseForRepo:repo];
            NSString *latest = [CLIRegistryService versionFromOutput:tag pattern:nil];
            if (latest) {
                status[@"latest"] = latest;
                status[@"state"] = [CLIRegistryService compareVersion:version toVersion:latest] == NSOrderedAscending ? @"outdated" : @"current";
            }
        }
    }

    NSString *shownVersion = status[@"version"] ?: @"?";
    NSString *suffix = entry[@"versionSuffix"] ?: @"";
    status[@"detail"] = [status[@"state"] isEqualToString:@"outdated"] && status[@"latest"]
        ? [NSString stringWithFormat:@"%@ → %@", shownVersion, status[@"latest"]]
        : [shownVersion stringByAppendingString:suffix];
    status[@"emphasis"] = @([status[@"state"] isEqualToString:@"outdated"]);
    status[@"tooltip"] = status[@"updateCommand"] ? [NSString stringWithFormat:@"%@\nupdate: %@", path, status[@"updateCommand"]] : path;
    return status;
}

#pragma mark Status presentation

- (NSArray<NSDictionary *> *)statuses {
    NSArray *base = _statuses ?: @[];
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:base.count];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSDictionary *status in base) {
        NSMutableDictionary *row = [status mutableCopy];
        row[@"icon"] = [self iconForEntry:[self entryWithId:status[@"id"]]];
        NSDictionary *update = self.updateStates[status[@"id"]];
        NSString *state = update[@"state"];
        BOOL expiredSuccess = [state isEqualToString:CLIUpdateStateSucceeded] && now - [update[@"finishedAt"] doubleValue] > SuccessDisplayDuration;
        // A successful run whose re-check still reports outdated falls back to the update button.
        BOOL successButStillOutdated = [state isEqualToString:CLIUpdateStateSucceeded] && [update[@"recheckedAt"] doubleValue] > 0 && [status[@"state"] isEqualToString:@"outdated"];
        if (state && !expiredSuccess && !successButStillOutdated) {
            row[@"updateState"] = state;
            if (update[@"line"]) row[@"tooltip"] = update[@"line"];
        }
        [merged addObject:row];
    }
    return merged;
}

- (NSDictionary *)entryWithId:(NSString *)entryId {
    for (NSDictionary *entry in self.registryEntries) {
        if ([entry[@"id"] isEqualToString:entryId]) return entry;
    }
    return @{};
}

- (NSString *)activeUpdateSummary {
    for (NSString *entryId in self.updateStates) {
        NSDictionary *update = self.updateStates[entryId];
        if (![update[@"state"] isEqualToString:CLIUpdateStateRunning]) continue;
        NSString *line = update[@"line"];
        return line.length > 0 ? [NSString stringWithFormat:@"%@ · %@", update[@"label"], line] : [NSString stringWithFormat:@"updating %@…", update[@"label"]];
    }
    return nil;
}

// Coalesces streaming progress into at most ~5 panel reloads per second.
- (void)notifyChange {
    if (self.changeNotificationScheduled) return;
    self.changeNotificationScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.changeNotificationScheduled = NO;
        if (self.changeHandler) self.changeHandler();
    });
}

#pragma mark Updates

- (void)runUpdateForStatus:(NSDictionary *)status {
    NSString *entryId = status[@"id"];
    NSString *command = status[@"updateCommand"];
    if (entryId.length == 0 || command.length == 0) return;
    NSString *current = self.updateStates[entryId][@"state"];
    if ([current isEqualToString:CLIUpdateStateRunning] || [current isEqualToString:CLIUpdateStateQueued]) return;

    NSMutableDictionary *update = [@{@"state": CLIUpdateStateQueued, @"label": status[@"title"] ?: entryId, @"command": command} mutableCopy];
    self.updateStates[entryId] = update;
    [self notifyChange];

    [self.updateQueue addOperationWithBlock:^{
        dispatch_sync(dispatch_get_main_queue(), ^{
            update[@"state"] = CLIUpdateStateRunning;
            update[@"line"] = command;
            [self notifyChange];
        });
        int exitCode = [self executeUpdateCommand:command progress:^(NSString *line) {
            dispatch_async(dispatch_get_main_queue(), ^{
                update[@"line"] = line;
                [self notifyChange];
            });
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL succeeded = exitCode == 0;
            update[@"state"] = succeeded ? CLIUpdateStateSucceeded : CLIUpdateStateFailed;
            update[@"finishedAt"] = @([[NSDate date] timeIntervalSince1970]);
            if (!succeeded && [update[@"line"] length] == 0) update[@"line"] = [NSString stringWithFormat:@"exit %d", exitCode];
            [self notifyChange];
            if (self.updateFinishedHandler) self.updateFinishedHandler(status, succeeded);
            [self recheckAfterUpdate:entryId];
        });
    }];
}

// Re-probes versions with the cache bypassed. When the owner rescans inventory it
// calls refreshWithInventory: again, which refreshes Homebrew / npm state as well.
- (void)recheckAfterUpdate:(NSString *)entryId {
    [self refreshWithInventory:self.lastInventory force:YES];
    __weak typeof(self) weakSelf = self;
    void (^mark)(void) = ^{
        NSMutableDictionary *update = weakSelf.updateStates[entryId];
        update[@"recheckedAt"] = @([[NSDate date] timeIntervalSince1970]);
        [weakSelf notifyChange];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ProbeBudget * NSEC_PER_SEC)), dispatch_get_main_queue(), mark);
}

// Streams combined stdout/stderr line by line so the panel can show live progress.
// stdin is /dev/null: updates never block on an interactive prompt.
- (int)executeUpdateCommand:(NSString *)command progress:(void (^)(NSString *line))progress {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/env";
    task.arguments = @[@"zsh", @"-lc", command];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"HOMEBREW_NO_AUTO_UPDATE"] = @"1";
    environment[@"HOMEBREW_NO_ANALYTICS"] = @"1";
    environment[@"HOMEBREW_NO_INSTALL_CLEANUP"] = @"1";
    environment[@"NONINTERACTIVE"] = @"1";
    task.environment = environment;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSMutableString *buffer = [NSMutableString string];
    NSLock *bufferLock = [[NSLock alloc] init];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (data.length == 0) return;
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        [bufferLock lock];
        [buffer appendString:chunk];
        NSArray *lines = [buffer componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]];
        NSString *last = nil;
        for (NSString *line in lines.reverseObjectEnumerator) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length > 0) { last = trimmed; break; }
        }
        if (buffer.length > 8192) [buffer deleteCharactersInRange:NSMakeRange(0, buffer.length - 4096)];
        [bufferLock unlock];
        if (last) progress(last.length > 90 ? [[last substringToIndex:89] stringByAppendingString:@"…"] : last);
    };

    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *finished) { dispatch_semaphore_signal(exited); };
    @try {
        [task launch];
    } @catch (NSException *exception) {
        pipe.fileHandleForReading.readabilityHandler = nil;
        progress(exception.reason ?: @"failed to launch");
        return -1;
    }
    [[pipe fileHandleForWriting] closeFile];

    if (dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(UpdateTimeout * NSEC_PER_SEC))) != 0) {
        [task terminate];
        dispatch_semaphore_wait(exited, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        pipe.fileHandleForReading.readabilityHandler = nil;
        progress(@"timed out");
        return -2;
    }
    pipe.fileHandleForReading.readabilityHandler = nil;
    return task.terminationStatus;
}

@end
