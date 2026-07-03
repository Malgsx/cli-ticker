#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>

static NSString *const StatusCurrent = @"current";
static NSString *const StatusOutdated = @"outdated";
static NSString *const StatusUnknown = @"unknown";

static NSString *const ChangeKindInstalled = @"installed";
static NSString *const ChangeKindUpdated = @"updated";

// How long an install/update event stays visible in the Recently Updated bucket.
static const NSTimeInterval RecentChangeLifetime = 24 * 60 * 60;
static const NSUInteger RecentChangeCapacity = 20;

static NSString *RunCommand(NSString *launchPath, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = arguments;
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"HOMEBREW_NO_AUTO_UPDATE"] = @"1";
    environment[@"HOMEBREW_NO_ANALYTICS"] = @"1";
    environment[@"HOMEBREW_NO_INSTALL_CLEANUP"] = @"1";
    task.environment = environment;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return @"";
    }

    NSData *data = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static NSString *CommandPath(NSString *name) {
    NSString *script = [NSString stringWithFormat:@"command -v %@", name];
    NSString *path = RunCommand(@"/usr/bin/env", @[@"zsh", @"-lc", script]);
    path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return path.length > 0 ? path : nil;
}

static NSMutableDictionary *Item(NSString *name, NSString *current, NSString *latest, NSString *source, NSString *path, NSString *status) {
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"name"] = name ?: @"";
    item[@"source"] = source ?: @"unknown";
    item[@"status"] = status ?: StatusUnknown;
    if (current.length > 0) item[@"currentVersion"] = current;
    if (latest.length > 0) item[@"latestVersion"] = latest;
    if (path.length > 0) item[@"path"] = path;
    return item;
}

static NSString *InventoryKey(NSDictionary *item) {
    return [NSString stringWithFormat:@"%@:%@", item[@"source"] ?: @"", item[@"name"] ?: @""];
}

static NSInteger StatusRank(NSString *status) {
    if ([status isEqualToString:StatusOutdated]) return 0;
    if ([status isEqualToString:StatusUnknown]) return 1;
    return 2;
}

static NSSet<NSString *> *AgentToolNames(void) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"agent",
            @"antigravity",
            @"amp",
            @"claude",
            @"codex",
            @"cora",
            @"coderabbit",
            @"cr",
            @"cursor",
            @"cursor-agent",
            @"droid",
            @"goose",
            @"hermes",
            @"kisuke",
            @"notion",
            @"ntn",
            @"opencode",
            @"pi",
            @"spawn",
            @"toad"
        ]];
    });
    return names;
}

static NSArray<NSString *> *PreferredAgentOrder(void) {
    return @[
        @"codex",
        @"notion",
        @"antigravity",
        @"claude",
        @"amp",
        @"cora",
        @"cursor",
        @"cursor-agent",
        @"goose",
        @"opencode",
        @"coderabbit",
        @"kisuke",
        @"droid",
        @"toad",
        @"spawn",
        @"hermes",
        @"agent",
        @"cr",
        @"pi"
    ];
}

static NSDictionary<NSString *, NSString *> *PackageAliases(void) {
    static NSDictionary<NSString *, NSString *> *aliases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aliases = @{
            @"agy": @"antigravity",
            @"@anthropic-ai/claude-code": @"claude",
            @"@sourcegraph/amp": @"amp",
            @"@mariozechner/pi-coding-agent": @"pi",
            @"block-goose-cli": @"goose",
            @"kisuke-cli-dev": @"kisuke",
            @"notionctl": @"notion",
            @"ntn": @"notion"
        };
    });
    return aliases;
}

static NSDictionary<NSString *, NSDictionary *> *AgentBrandMetadata(void) {
    static NSDictionary<NSString *, NSDictionary *> *metadata;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        metadata = @{
            @"codex": @{@"label": @"Codex", @"mark": @"CX", @"color": [NSColor colorWithCalibratedRed:0.10 green:0.55 blue:0.42 alpha:1.0]},
            @"antigravity": @{@"label": @"Antigravity", @"mark": @"AG", @"color": [NSColor colorWithCalibratedRed:0.16 green:0.48 blue:0.92 alpha:1.0]},
            @"claude": @{@"label": @"Claude", @"mark": @"C", @"color": [NSColor colorWithCalibratedRed:0.78 green:0.34 blue:0.18 alpha:1.0]},
            @"amp": @{@"label": @"Amp", @"mark": @"A", @"color": [NSColor colorWithCalibratedRed:0.42 green:0.27 blue:0.86 alpha:1.0]},
            @"cora": @{@"label": @"Cora", @"mark": @"CO", @"color": [NSColor colorWithCalibratedRed:0.08 green:0.56 blue:0.74 alpha:1.0]},
            @"cursor": @{@"label": @"Cursor", @"mark": @"⌘", @"color": [NSColor colorWithCalibratedWhite:0.12 alpha:1.0]},
            @"cursor-agent": @{@"label": @"Cursor Agent", @"mark": @"CA", @"color": [NSColor colorWithCalibratedWhite:0.12 alpha:1.0]},
            @"goose": @{@"label": @"Goose", @"mark": @"G", @"color": [NSColor colorWithCalibratedRed:0.12 green:0.44 blue:0.82 alpha:1.0]},
            @"notion": @{@"label": @"Notion", @"mark": @"N", @"color": [NSColor colorWithCalibratedRed:0.13 green:0.55 blue:0.90 alpha:1.0]},
            @"opencode": @{@"label": @"OpenCode", @"mark": @"OC", @"color": [NSColor colorWithCalibratedRed:0.12 green:0.12 blue:0.13 alpha:1.0]},
            @"coderabbit": @{@"label": @"CodeRabbit", @"mark": @"CR", @"color": [NSColor colorWithCalibratedRed:0.94 green:0.42 blue:0.18 alpha:1.0]},
            @"kisuke": @{@"label": @"Kisuke", @"mark": @"K", @"color": [NSColor colorWithCalibratedRed:0.83 green:0.66 blue:0.16 alpha:1.0]},
            @"droid": @{@"label": @"Droid", @"mark": @"D", @"color": [NSColor colorWithCalibratedRed:0.25 green:0.67 blue:0.30 alpha:1.0]},
            @"toad": @{@"label": @"Toad", @"mark": @"T", @"color": [NSColor colorWithCalibratedRed:0.18 green:0.52 blue:0.25 alpha:1.0]},
            @"spawn": @{@"label": @"Spawn", @"mark": @"S", @"color": [NSColor colorWithCalibratedRed:0.24 green:0.48 blue:0.72 alpha:1.0]},
            @"hermes": @{@"label": @"Hermes", @"mark": @"H", @"color": [NSColor colorWithCalibratedRed:0.58 green:0.36 blue:0.18 alpha:1.0]},
            @"agent": @{@"label": @"Agent", @"mark": @"AI", @"color": [NSColor colorWithCalibratedRed:0.20 green:0.52 blue:0.62 alpha:1.0]},
            @"cr": @{@"label": @"CR", @"mark": @"CR", @"color": [NSColor colorWithCalibratedRed:0.94 green:0.42 blue:0.18 alpha:1.0]},
            @"pi": @{@"label": @"Pi", @"mark": @"π", @"color": [NSColor colorWithCalibratedRed:0.34 green:0.34 blue:0.72 alpha:1.0]}
        };
    });
    return metadata;
}

static NSImage *AgentIcon(NSString *canonicalName) {
    NSDictionary *logoFiles = @{
        @"codex": @"codex",
        @"antigravity": @"antigravity",
        @"claude": @"anthropic",
        @"amp": @"sourcegraph",
        @"cursor": @"cursor",
        @"cursor-agent": @"cursor",
        @"coderabbit": @"coderabbit",
        @"cr": @"coderabbit",
        @"droid": @"droid",
        @"hermes": @"nousresearch",
        @"goose": @"block-goose",
        @"kisuke": @"kisuke",
        @"notion": @"notion-blue",
        @"toad": @"toad",
        @"spawn": @"spawn"
    };
    NSString *logoName = logoFiles[canonicalName];
    if (logoName.length > 0) {
        NSString *resourcePath = [[NSBundle mainBundle] pathForResource:logoName ofType:@"png" inDirectory:@"Logos"];
        if (resourcePath.length > 0) {
            NSImage *logo = [[NSImage alloc] initWithContentsOfFile:resourcePath];
            if (logo) {
                logo.size = NSMakeSize(18, 18);
                logo.template = NO;
                return logo;
            }
        }
    }

    NSDictionary *meta = AgentBrandMetadata()[canonicalName];
    NSString *mark = meta[@"mark"] ?: [[canonicalName substringToIndex:MIN((NSUInteger)2, canonicalName.length)] uppercaseString];
    NSColor *color = meta[@"color"] ?: [NSColor systemBlueColor];

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image lockFocus];
    NSRect rect = NSMakeRect(1, 1, 16, 16);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4];
    [color setFill];
    [path fill];

    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:mark.length > 1 ? 7 : 10],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    NSSize textSize = [mark sizeWithAttributes:attributes];
    NSPoint point = NSMakePoint((18 - textSize.width) / 2.0, (18 - textSize.height) / 2.0 - 0.5);
    [mark drawAtPoint:point withAttributes:attributes];
    [image unlockFocus];
    image.template = NO;
    return image;
}

static NSString *EscapedAppleScriptString(NSString *string) {
    NSMutableString *escaped = [string mutableCopy];
    [escaped replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString *ShellSingleQuoteEscaped(NSString *string) {
    return [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

static NSTextField *GlassLabel(NSString *text, NSRect frame, NSFont *font, NSColor *color, NSTextAlignment alignment) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.frame = frame;
    label.font = font;
    label.textColor = color;
    label.alignment = alignment;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static BOOL AppExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSString *FindApplicationPath(NSArray<NSString *> *appNames) {
    if (appNames.count == 0) return nil;

    NSArray<NSString *> *roots = @[
        @"/Applications",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]
    ];
    for (NSString *root in roots) {
        for (NSString *name in appNames) {
            NSString *candidate = [root stringByAppendingPathComponent:name];
            if (AppExists(candidate)) return candidate;
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *TerminalCandidates(void) {
    return @[
        @{@"name": @"Ghostty", @"apps": @[@"Ghostty.app"]},
        @{@"name": @"iTerm", @"apps": @[@"iTerm.app", @"iTerm2.app"]},
        @{@"name": @"Warp", @"apps": @[@"Warp.app"]}
    ];
}

static NSString *DefaultTerminalName(void) {
    for (NSDictionary *terminal in TerminalCandidates()) {
        if (FindApplicationPath(terminal[@"apps"])) return terminal[@"name"];
    }
    return @"Terminal";
}

// Maps a canonical agent name to the executable users actually invoke.
static NSString *AgentInvocationName(NSString *canonicalName) {
    static NSDictionary<NSString *, NSString *> *overrides;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        overrides = @{
            @"antigravity": @"agy",
            @"notion": @"ntn"
        };
    });
    return overrides[canonicalName] ?: canonicalName;
}

@interface InventoryService : NSObject
- (NSArray<NSMutableDictionary *> *)refresh;
@end

@implementation InventoryService

- (NSArray<NSMutableDictionary *> *)refresh {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *merged = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableDictionary *> *all = [NSMutableArray array];
    NSLock *allLock = [[NSLock alloc] init];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    void (^addScanner)(NSArray<NSMutableDictionary *> *(^)(void)) = ^(NSArray<NSMutableDictionary *> *(^scanner)(void)) {
        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            NSArray<NSMutableDictionary *> *items = scanner();
            [allLock lock];
            [all addObjectsFromArray:items];
            [allLock unlock];
            dispatch_group_leave(group);
        });
    };

    addScanner(^NSArray<NSMutableDictionary *> *{ return [self pathBinaries]; });
    addScanner(^NSArray<NSMutableDictionary *> *{ return [self brewItemsWithCasks:NO]; });
    addScanner(^NSArray<NSMutableDictionary *> *{ return [self brewItemsWithCasks:YES]; });
    addScanner(^NSArray<NSMutableDictionary *> *{ return [self npmGlobals]; });
    addScanner(^NSArray<NSMutableDictionary *> *{ return [self bunGlobals]; });
    addScanner(^NSArray<NSMutableDictionary *> *{ return [self uvTools]; });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    for (NSMutableDictionary *item in all) {
        NSString *key = [NSString stringWithFormat:@"%@:%@", item[@"source"], item[@"name"]];
        NSMutableDictionary *existing = merged[key];
        if (!existing) {
            merged[key] = item;
            continue;
        }
        if (!existing[@"currentVersion"] && item[@"currentVersion"]) existing[@"currentVersion"] = item[@"currentVersion"];
        if (!existing[@"latestVersion"] && item[@"latestVersion"]) existing[@"latestVersion"] = item[@"latestVersion"];
        if (!existing[@"path"] && item[@"path"]) existing[@"path"] = item[@"path"];
        if (![existing[@"status"] isEqualToString:StatusOutdated]) existing[@"status"] = item[@"status"];
    }

    NSArray *sorted = [merged.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger rankA = StatusRank(a[@"status"]);
        NSInteger rankB = StatusRank(b[@"status"]);
        if (rankA < rankB) return NSOrderedAscending;
        if (rankA > rankB) return NSOrderedDescending;
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return sorted;
}

- (NSArray<NSMutableDictionary *> *)pathBinaries {
    NSString *script =
        @"print -rl -- ${(ps.:.)PATH} | while read -r d; do "
         "case \"$d\" in /usr/bin|/bin|/usr/sbin|/sbin|/System/*|/Library/Apple/*) continue ;; esac; "
         "[ -d \"$d\" ] && find \"$d\" -maxdepth 1 \\( -type f -o -type l \\) -perm +111 -print 2>/dev/null; "
         "done | sort -u";
    NSString *output = RunCommand(@"/usr/bin/env", @[@"zsh", @"-lc", script]);
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) continue;
        NSString *name = line.lastPathComponent;
        if (name.length > 0) [items addObject:Item(name, nil, nil, @"PATH", line, StatusUnknown)];
    }
    return items;
}

- (NSDictionary<NSString *, NSString *> *)brewOutdatedWithCasks:(BOOL)casks brew:(NSString *)brew {
    NSArray *args = casks ? @[@"outdated", @"--cask", @"--verbose"] : @[@"outdated", @"--formula", @"--verbose"];
    NSString *output = RunCommand(brew, args);
    NSMutableDictionary *outdated = [NSMutableDictionary dictionary];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange range = [line rangeOfString:@"<"];
        if (range.location == NSNotFound) continue;
        NSString *left = [[line substringToIndex:range.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *latest = [[line substringFromIndex:range.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *name = [left componentsSeparatedByString:@" "].firstObject;
        if (name.length > 0 && latest.length > 0) outdated[name] = latest;
    }
    return outdated;
}

- (NSArray<NSMutableDictionary *> *)brewItemsWithCasks:(BOOL)casks {
    NSString *brew = CommandPath(@"brew");
    if (!brew) return @[];

    NSArray *args = casks ? @[@"list", @"--cask", @"--versions"] : @[@"list", @"--formula", @"--versions"];
    NSString *output = RunCommand(brew, args);
    NSDictionary *outdated = [self brewOutdatedWithCasks:casks brew:brew];
    NSString *source = casks ? @"Homebrew Cask" : @"Homebrew";

    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray *parts = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *clean = [NSMutableArray array];
        for (NSString *part in parts) if (part.length > 0) [clean addObject:part];
        if (clean.count == 0) continue;
        NSString *name = clean.firstObject;
        NSString *current = clean.count > 1 ? [[clean subarrayWithRange:NSMakeRange(1, clean.count - 1)] componentsJoinedByString:@", "] : nil;
        NSString *latest = outdated[name];
        [items addObject:Item(name, current, latest, source, nil, latest ? StatusOutdated : StatusCurrent)];
    }
    return items;
}

- (NSDictionary<NSString *, NSString *> *)npmOutdated:(NSString *)npm {
    NSString *output = RunCommand(npm, @[@"outdated", @"-g", @"--json"]);
    NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{};
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in json) {
        NSDictionary *info = json[name];
        if ([info isKindOfClass:[NSDictionary class]] && [info[@"latest"] isKindOfClass:[NSString class]]) {
            result[name] = info[@"latest"];
        }
    }
    return result;
}

- (NSArray<NSMutableDictionary *> *)npmGlobals {
    NSString *npm = CommandPath(@"npm");
    if (!npm) return @[];
    NSString *output = RunCommand(npm, @[@"ls", @"-g", @"--depth=0", @"--json"]);
    NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *deps = [json isKindOfClass:[NSDictionary class]] ? json[@"dependencies"] : nil;
    if (![deps isKindOfClass:[NSDictionary class]]) return @[];

    NSDictionary *outdated = [self npmOutdated:npm];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in deps) {
        NSDictionary *info = deps[name];
        NSString *current = [info isKindOfClass:[NSDictionary class]] ? info[@"version"] : nil;
        NSString *latest = outdated[name];
        [items addObject:Item(name, current, latest, @"npm global", nil, latest ? StatusOutdated : StatusCurrent)];
    }
    return items;
}

- (NSArray<NSMutableDictionary *> *)bunGlobals {
    NSString *bun = CommandPath(@"bun");
    if (!bun) return @[];
    NSString *output = RunCommand(bun, @[@"pm", @"ls", @"-g"]);
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *raw in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByReplacingOccurrencesOfString:@"├── " withString:@""];
        line = [line stringByReplacingOccurrencesOfString:@"└── " withString:@""];
        NSRange at = [line rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location == NSNotFound || at.location == 0) continue;
        NSString *name = [line substringToIndex:at.location];
        NSString *version = [line substringFromIndex:at.location + 1];
        [items addObject:Item(name, version, nil, @"Bun global", nil, StatusUnknown)];
    }
    return items;
}

- (NSArray<NSMutableDictionary *> *)uvTools {
    NSString *uv = CommandPath(@"uv");
    if (!uv) return @[];
    NSString *output = RunCommand(uv, @[@"tool", @"list"]);
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:@"-"] || ![line containsString:@" v"]) continue;
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if (parts.count < 2) continue;
        NSString *version = [parts[1] stringByReplacingOccurrencesOfString:@"v" withString:@""];
        [items addObject:Item(parts[0], version, nil, @"uv tool", nil, StatusUnknown)];
    }
    return items;
}

@end

@interface MenuController : NSObject
@property NSStatusItem *statusItem;
@property InventoryService *service;
@property NSArray<NSDictionary *> *items;
@property BOOL refreshing;
@property NSURL *reportURL;
@property NSURL *markdownReportURL;
@property NSURL *changesURL;
@property NSURL *updateRefreshRequestURL;
@property NSDate *lastHandledUpdateRefreshDate;
@property NSString *preferredTerminal;
@property NSArray<NSDictionary *> *recentChanges;
@property (assign) FSEventStreamRef installWatchStream;
@property NSTimer *watcherRefreshTimer;
@property NSArray<NSDictionary *> *allUpdateItems;
@property NSTableView *allUpdatesTableView;
@property NSAlert *allUpdatesAlert;
@property NSArray<NSDictionary *> *searchResultItems;
@property NSTableView *searchResultsTableView;
- (void)scheduleWatcherRefresh;
@end

static void InstallWatchCallback(ConstFSEventStreamRef streamRef,
                                 void *info,
                                 size_t numEvents,
                                 void *eventPaths,
                                 const FSEventStreamEventFlags *eventFlags,
                                 const FSEventStreamEventId *eventIds) {
    MenuController *controller = (__bridge MenuController *)info;
    [controller scheduleWatcherRefresh];
}

@implementation MenuController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.service = [[InventoryService alloc] init];
    self.items = @[];
    NSString *savedTerminal = [[NSUserDefaults standardUserDefaults] stringForKey:@"PreferredTerminal"];
    self.preferredTerminal = savedTerminal.length > 0 ? savedTerminal : DefaultTerminalName();
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"";
    self.statusItem.button.toolTip = @"CLI";
    NSString *statusIconPath = [[NSBundle mainBundle] pathForResource:@"CLIStatusTemplate" ofType:@"png"];
    NSImage *statusIcon = statusIconPath ? [[NSImage alloc] initWithContentsOfFile:statusIconPath] : nil;
    if (statusIcon) {
        statusIcon.size = NSMakeSize(18, 18);
        statusIcon.template = YES;
        self.statusItem.button.image = statusIcon;
        self.statusItem.button.imagePosition = NSImageLeft;
    }

    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"CLITicker" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    self.reportURL = [dir URLByAppendingPathComponent:@"inventory.json"];
    self.markdownReportURL = [dir URLByAppendingPathComponent:@"inventory.md"];
    self.changesURL = [dir URLByAppendingPathComponent:@"changes.json"];
    self.updateRefreshRequestURL = [dir URLByAppendingPathComponent:@"update-refresh-request"];
    NSDictionary *markerAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.updateRefreshRequestURL.path error:nil];
    self.lastHandledUpdateRefreshDate = markerAttributes[NSFileModificationDate];
    self.recentChanges = @[];
    [self loadReport];
    [self loadRecentChanges];
    [self rebuildMenu];
    [self refresh:nil];
    [self startInstallWatcher];

    [NSTimer scheduledTimerWithTimeInterval:15 * 60 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(checkForUpdateRefreshRequest:) userInfo:nil repeats:YES];
    return self;
}

- (void)dealloc {
    [self stopInstallWatcher];
}

- (void)loadReport {
    NSData *data = [NSData dataWithContentsOfURL:self.reportURL];
    if (!data) return;
    NSArray *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([saved isKindOfClass:[NSArray class]]) self.items = saved;
}

- (void)saveReport {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.items options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:self.reportURL atomically:YES];
    [self saveMarkdownReport];
}

#pragma mark - Recently Updated bucket

- (void)loadRecentChanges {
    NSData *data = [NSData dataWithContentsOfURL:self.changesURL];
    if (!data) return;
    NSArray *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([saved isKindOfClass:[NSArray class]]) self.recentChanges = [self prunedChanges:saved];
}

- (void)saveRecentChanges {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.recentChanges options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    [data writeToURL:self.changesURL atomically:YES];
}

- (NSArray<NSDictionary *> *)prunedChanges:(NSArray<NSDictionary *> *)changes {
    NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - RecentChangeLifetime;
    NSMutableArray *pruned = [NSMutableArray array];
    for (NSDictionary *change in changes) {
        if (![change isKindOfClass:[NSDictionary class]]) continue;
        if ([change[@"date"] doubleValue] < cutoff) continue;
        [pruned addObject:change];
        if (pruned.count >= RecentChangeCapacity) break;
    }
    return pruned;
}

- (NSDictionary *)changeOfKind:(NSString *)kind forItem:(NSDictionary *)item previousVersion:(NSString *)previousVersion {
    NSMutableDictionary *change = [NSMutableDictionary dictionary];
    change[@"key"] = InventoryKey(item);
    change[@"name"] = item[@"name"] ?: @"";
    change[@"source"] = item[@"source"] ?: @"";
    change[@"kind"] = kind;
    change[@"date"] = @([[NSDate date] timeIntervalSince1970]);
    if ([item[@"currentVersion"] isKindOfClass:[NSString class]]) change[@"currentVersion"] = item[@"currentVersion"];
    if (previousVersion.length > 0) change[@"previousVersion"] = previousVersion;
    return change;
}

// Diffs a fresh scan against the previous one so installs and version bumps
// land in the Recently Updated bucket without any manual action.
- (void)recordChangesFromItems:(NSArray<NSDictionary *> *)previousItems toItems:(NSArray<NSDictionary *> *)freshItems {
    if (previousItems.count == 0) return;

    NSMutableDictionary<NSString *, NSDictionary *> *previous = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *previousSources = [NSMutableSet set];
    for (NSDictionary *item in previousItems) {
        previous[InventoryKey(item)] = item;
        [previousSources addObject:item[@"source"] ?: @""];
    }

    NSMutableArray<NSDictionary *> *newChanges = [NSMutableArray array];
    for (NSDictionary *item in freshItems) {
        NSDictionary *old = previous[InventoryKey(item)];
        if (!old) {
            // A source absent from the previous scan usually means that scanner
            // failed last time, not that every one of its tools was just installed.
            if (![previousSources containsObject:item[@"source"] ?: @""]) continue;
            [newChanges addObject:[self changeOfKind:ChangeKindInstalled forItem:item previousVersion:nil]];
            continue;
        }
        NSString *oldVersion = old[@"currentVersion"];
        NSString *newVersion = item[@"currentVersion"];
        if (oldVersion.length > 0 && newVersion.length > 0 && ![oldVersion isEqualToString:newVersion]) {
            [newChanges addObject:[self changeOfKind:ChangeKindUpdated forItem:item previousVersion:oldVersion]];
        }
    }
    if (newChanges.count == 0) {
        NSArray *pruned = [self prunedChanges:self.recentChanges];
        if (pruned.count != self.recentChanges.count) {
            self.recentChanges = pruned;
            [self saveRecentChanges];
        }
        return;
    }

    NSMutableSet *changedKeys = [NSMutableSet set];
    for (NSDictionary *change in newChanges) [changedKeys addObject:change[@"key"]];

    NSMutableArray *merged = [newChanges mutableCopy];
    for (NSDictionary *change in self.recentChanges) {
        if ([changedKeys containsObject:change[@"key"]]) continue;
        [merged addObject:change];
    }
    self.recentChanges = [self prunedChanges:merged];
    [self saveRecentChanges];
}

- (NSString *)relativeTimeForTimestamp:(NSTimeInterval)timestamp {
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - timestamp;
    if (elapsed < 60) return @"just now";
    if (elapsed < 60 * 60) return [NSString stringWithFormat:@"%.0fm ago", elapsed / 60];
    if (elapsed < 24 * 60 * 60) return [NSString stringWithFormat:@"%.0fh ago", elapsed / (60 * 60)];
    return [NSString stringWithFormat:@"%.0fd ago", elapsed / (24 * 60 * 60)];
}

- (NSString *)recentChangeTitle:(NSDictionary *)change {
    NSDictionary *itemStub = @{@"name": change[@"name"] ?: @""};
    NSString *label = [self titleNameForItem:itemStub];
    NSString *when = [self relativeTimeForTimestamp:[change[@"date"] doubleValue]];

    NSString *previousVersion = change[@"previousVersion"];
    NSString *currentVersion = change[@"currentVersion"];
    if ([change[@"kind"] isEqualToString:ChangeKindUpdated] && previousVersion.length > 0 && currentVersion.length > 0) {
        return [NSString stringWithFormat:@"%@  %@ → %@  · updated %@", label, previousVersion, currentVersion, when];
    }
    NSString *version = currentVersion.length > 0 ? currentVersion : @"installed";
    return [NSString stringWithFormat:@"%@  %@  · installed %@", label, version, when];
}

- (NSDictionary *)inventoryItemForChange:(NSDictionary *)change {
    NSString *key = change[@"key"];
    for (NSDictionary *item in self.items) {
        if ([InventoryKey(item) isEqualToString:key]) return item;
    }
    return nil;
}

#pragma mark - Install watcher

- (NSArray<NSString *> *)installWatchPaths {
    NSString *home = NSHomeDirectory();
    NSArray<NSString *> *candidates = @[
        @"/opt/homebrew/bin",
        @"/opt/homebrew/Cellar",
        @"/opt/homebrew/Caskroom",
        @"/usr/local/bin",
        @"/usr/local/Cellar",
        @"/usr/local/Caskroom",
        [home stringByAppendingPathComponent:@".local/bin"],
        [home stringByAppendingPathComponent:@".bun/bin"],
        [home stringByAppendingPathComponent:@".npm-global/bin"],
        [home stringByAppendingPathComponent:@".claude/local/bin"]
    ];

    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *candidate in candidates) {
        BOOL isDirectory = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) {
            [paths addObject:candidate];
        }
    }
    return paths;
}

- (void)startInstallWatcher {
    NSArray<NSString *> *paths = [self installWatchPaths];
    if (paths.count == 0) return;

    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    FSEventStreamRef stream = FSEventStreamCreate(kCFAllocatorDefault,
                                                  InstallWatchCallback,
                                                  &context,
                                                  (__bridge CFArrayRef)paths,
                                                  kFSEventStreamEventIdSinceNow,
                                                  2.0,
                                                  kFSEventStreamCreateFlagNone);
    if (!stream) return;

    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
    if (!FSEventStreamStart(stream)) {
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        return;
    }
    self.installWatchStream = stream;
}

- (void)stopInstallWatcher {
    if (!self.installWatchStream) return;
    FSEventStreamStop(self.installWatchStream);
    FSEventStreamInvalidate(self.installWatchStream);
    FSEventStreamRelease(self.installWatchStream);
    self.installWatchStream = NULL;
}

// Debounced so a burst of file events from one install triggers a single rescan
// after the package manager has finished writing.
- (void)scheduleWatcherRefresh {
    [self.watcherRefreshTimer invalidate];
    self.watcherRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:8
                                                                target:self
                                                              selector:@selector(watcherRefreshFired:)
                                                              userInfo:nil
                                                               repeats:NO];
}

- (void)watcherRefreshFired:(NSTimer *)timer {
    self.watcherRefreshTimer = nil;
    if (self.refreshing) {
        [self scheduleWatcherRefresh];
        return;
    }
    [self refresh:nil];
}

- (NSString *)markdownEscaped:(NSString *)value {
    NSString *text = value ?: @"";
    text = [text stringByReplacingOccurrencesOfString:@"|" withString:@"\\|"];
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return text;
}

- (void)saveMarkdownReport {
    NSUInteger outdated = [self countWithStatus:StatusOutdated];
    NSUInteger unknown = [self countWithStatus:StatusUnknown];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;

    NSMutableString *markdown = [NSMutableString string];
    [markdown appendString:@"# CLI Report\n\n"];
    [markdown appendFormat:@"Generated: %@\n\n", [formatter stringFromDate:[NSDate date]]];
    [markdown appendFormat:@"- Total CLIs: %lu\n", self.items.count];
    [markdown appendFormat:@"- Outdated: %lu\n", outdated];
    [markdown appendFormat:@"- Unknown/manual: %lu\n\n", unknown];

    NSArray *agents = [self agentTools];
    if (agents.count > 0) {
        [markdown appendString:@"## Agent Tools\n\n"];
        [markdown appendString:@"| Tool | Status | Current | Latest | Source |\n"];
        [markdown appendString:@"| --- | --- | --- | --- | --- |\n"];
        for (NSDictionary *item in agents) {
            NSString *name = [self friendlyAgentName:[self displayNameForItem:item]];
            [markdown appendFormat:@"| %@ | %@ | %@ | %@ | %@ |\n",
                [self markdownEscaped:name],
                [self markdownEscaped:item[@"status"]],
                [self markdownEscaped:item[@"currentVersion"] ?: @""],
                [self markdownEscaped:item[@"latestVersion"] ?: @""],
                [self markdownEscaped:item[@"source"] ?: @""]
            ];
        }
        [markdown appendString:@"\n"];
    }

    NSArray *updates = [self notableUpdateItems:50];
    if (updates.count > 0) {
        [markdown appendString:@"## Notable Updates\n\n"];
        [markdown appendString:@"| CLI | Current | Latest | Source |\n"];
        [markdown appendString:@"| --- | --- | --- | --- |\n"];
        for (NSDictionary *item in updates) {
            [markdown appendFormat:@"| %@ | %@ | %@ | %@ |\n",
                [self markdownEscaped:item[@"name"] ?: @""],
                [self markdownEscaped:item[@"currentVersion"] ?: @""],
                [self markdownEscaped:item[@"latestVersion"] ?: @""],
                [self markdownEscaped:item[@"source"] ?: @""]
            ];
        }
        [markdown appendString:@"\n"];
    }

    NSArray *recentChanges = [self prunedChanges:self.recentChanges];
    if (recentChanges.count > 0) {
        [markdown appendString:@"## Recently Updated\n\n"];
        [markdown appendString:@"| CLI | Change | Previous | Current | Source |\n"];
        [markdown appendString:@"| --- | --- | --- | --- | --- |\n"];
        for (NSDictionary *change in recentChanges) {
            [markdown appendFormat:@"| %@ | %@ | %@ | %@ | %@ |\n",
                [self markdownEscaped:change[@"name"] ?: @""],
                [self markdownEscaped:change[@"kind"] ?: @""],
                [self markdownEscaped:change[@"previousVersion"] ?: @""],
                [self markdownEscaped:change[@"currentVersion"] ?: @""],
                [self markdownEscaped:change[@"source"] ?: @""]
            ];
        }
        [markdown appendString:@"\n"];
    }

    [markdown appendString:@"## Full Inventory\n\n"];
    [markdown appendString:@"| CLI | Status | Current | Latest | Source | Path |\n"];
    [markdown appendString:@"| --- | --- | --- | --- | --- | --- |\n"];
    for (NSDictionary *item in self.items) {
        [markdown appendFormat:@"| %@ | %@ | %@ | %@ | %@ | %@ |\n",
            [self markdownEscaped:item[@"name"] ?: @""],
            [self markdownEscaped:item[@"status"] ?: @""],
            [self markdownEscaped:item[@"currentVersion"] ?: @""],
            [self markdownEscaped:item[@"latestVersion"] ?: @""],
            [self markdownEscaped:item[@"source"] ?: @""],
            [self markdownEscaped:item[@"path"] ?: @""]
        ];
    }

    [markdown writeToURL:self.markdownReportURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSUInteger)countWithStatus:(NSString *)status {
    NSUInteger count = 0;
    for (NSDictionary *item in self.items) {
        if ([item[@"status"] isEqualToString:status]) count++;
    }
    return count;
}

- (NSString *)summaryTitle {
    if (self.items.count == 0) return @"No scan yet";
    return [NSString stringWithFormat:@"%lu CLIs scanned, %lu outdated, %lu unknown",
        self.items.count, [self countWithStatus:StatusOutdated], [self countWithStatus:StatusUnknown]];
}

- (NSString *)friendlyUpdateTitle:(NSDictionary *)item {
    NSString *name = [self titleNameForItem:item];
    if (name.length == 0) name = @"Unknown CLI";
    NSString *source = item[@"source"] ?: @"";
    NSString *current = item[@"currentVersion"] ?: @"installed";
    NSString *latest = item[@"latestVersion"];

    if ([item[@"status"] isEqualToString:StatusOutdated] && latest.length > 0) {
        return [NSString stringWithFormat:@"%@  %@ → %@  (%@)", name, current, latest, source];
    }
    if ([item[@"status"] isEqualToString:StatusCurrent]) {
        return [NSString stringWithFormat:@"%@  %@  (%@)", name, current, source];
    }
    return [NSString stringWithFormat:@"%@  installed  (%@)", name, source];
}

- (NSArray<NSDictionary *> *)searchItemsMatching:(NSString *)query limit:(NSUInteger)limit {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @[];

    NSMutableArray<NSString *> *terms = [NSMutableArray array];
    for (NSString *term in [[trimmed lowercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (term.length > 0) [terms addObject:term];
    }

    NSMutableArray<NSDictionary *> *scoredMatches = [NSMutableArray array];
    for (NSDictionary *item in self.items) {
        NSInteger score = 0;
        for (NSString *term in terms) {
            NSInteger termScore = [self searchScoreForItem:item term:term];
            if (termScore == 0) {
                score = 0;
                break;
            }
            score += termScore;
        }
        if (score == 0) continue;
        [scoredMatches addObject:@{@"item": item, @"score": @(score)}];
    }

    NSArray<NSDictionary *> *sorted = [scoredMatches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger scoreA = [a[@"score"] integerValue];
        NSInteger scoreB = [b[@"score"] integerValue];
        if (scoreA > scoreB) return NSOrderedAscending;
        if (scoreA < scoreB) return NSOrderedDescending;
        return [a[@"item"][@"name"] localizedCaseInsensitiveCompare:b[@"item"][@"name"]];
    }];

    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *match in sorted) {
        [matches addObject:match[@"item"]];
        if (matches.count >= limit) break;
    }
    return matches;
}

- (NSArray<NSString *> *)searchTokensForString:(NSString *)value {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @[];
    NSArray<NSString *> *parts = [[value lowercaseString] componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [tokens addObject:part];
    }
    return tokens;
}

- (NSInteger)searchScoreForItem:(NSDictionary *)item term:(NSString *)term {
    NSString *name = [item[@"name"] isKindOfClass:[NSString class]] ? [item[@"name"] lowercaseString] : @"";
    NSString *displayName = [[self displayNameForItem:item] lowercaseString];
    NSString *source = [item[@"source"] isKindOfClass:[NSString class]] ? [item[@"source"] lowercaseString] : @"";
    NSString *path = [item[@"path"] isKindOfClass:[NSString class]] ? [item[@"path"] lowercaseString] : @"";
    NSString *pathName = path.lastPathComponent ?: @"";

    if ([displayName isEqualToString:term]) return 1000;
    if ([name isEqualToString:term]) return 950;
    if ([pathName isEqualToString:term]) return 900;

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    [tokens addObjectsFromArray:[self searchTokensForString:name]];
    [tokens addObjectsFromArray:[self searchTokensForString:displayName]];
    [tokens addObjectsFromArray:[self searchTokensForString:pathName]];
    if ([tokens containsObject:term]) return 800;

    if (term.length <= 2) return 0;

    for (NSString *token in tokens) {
        if ([token hasPrefix:term]) return 520;
    }
    if ([name rangeOfString:term].location != NSNotFound) return 300;
    if ([pathName rangeOfString:term].location != NSNotFound) return 260;
    if ([source rangeOfString:term].location != NSNotFound) return 180;
    return 0;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.searchResultsTableView) return self.searchResultItems.count;
    return self.allUpdateItems.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray<NSDictionary *> *items = tableView == self.searchResultsTableView ? self.searchResultItems : self.allUpdateItems;
    if (row < 0 || row >= (NSInteger)items.count) return @"";
    NSDictionary *item = items[row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:@"tool"]) return [self titleNameForItem:item];
    if ([identifier isEqualToString:@"version"]) return [self versionSummaryForItem:item];
    if ([identifier isEqualToString:@"current"]) return item[@"currentVersion"] ?: @"installed";
    if ([identifier isEqualToString:@"latest"]) return item[@"latestVersion"] ?: @"";
    if ([identifier isEqualToString:@"source"]) return item[@"source"] ?: @"";
    if ([identifier isEqualToString:@"command"]) {
        if (tableView == self.searchResultsTableView) return [self invocationForCLIItem:item];
        return [self updateCommandForItem:item] ?: @"Manual update required";
    }
    return @"";
}

- (NSTableColumn *)updateTableColumnWithIdentifier:(NSString *)identifier title:(NSString *)title width:(CGFloat)width {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    column.minWidth = width;
    return column;
}

- (void)runUpdateForItem:(NSDictionary *)item confirm:(BOOL)confirm {
    NSString *command = [self updateCommandForItem:item];
    if (command.length == 0) {
        NSAlert *unsupported = [[NSAlert alloc] init];
        unsupported.messageText = @"Update Not Supported";
        unsupported.informativeText = @"CLI can apply Homebrew and global npm updates from the menu. Use the package manager directly for this source.";
        [unsupported addButtonWithTitle:@"OK"];
        [unsupported runModal];
        return;
    }

    if (confirm) {
        NSAlert *confirmAlert = [[NSAlert alloc] init];
        confirmAlert.messageText = [NSString stringWithFormat:@"Update %@?", item[@"name"] ?: @"this CLI"];
        confirmAlert.informativeText = [NSString stringWithFormat:@"CLI will open %@ and run:\n\n%@", self.preferredTerminal ?: DefaultTerminalName(), command];
        [confirmAlert addButtonWithTitle:@"Update"];
        [confirmAlert addButtonWithTitle:@"Cancel"];
        if ([confirmAlert runModal] != NSAlertFirstButtonReturn) return;
    }

    NSString *terminalCommand = [self updateTerminalCommandForItem:item];
    [self runShellCommand:terminalCommand inTerminal:self.preferredTerminal ?: DefaultTerminalName()];
}

- (void)reloadAllUpdatesDialog {
    if (!self.allUpdatesTableView) return;

    NSArray<NSDictionary *> *updates = [self notableUpdateItems:NSUIntegerMax];
    self.allUpdateItems = updates;
    [self.allUpdatesTableView reloadData];
    self.allUpdatesAlert.messageText = [NSString stringWithFormat:@"All Updates Available (%lu)", updates.count];
    self.allUpdatesAlert.informativeText = updates.count > 0
        ? [NSString stringWithFormat:@"Double-click an update to run it in %@.", self.preferredTerminal ?: DefaultTerminalName()]
        : @"All visible updates are current.";
}

- (NSString *)updateCommandForItem:(NSDictionary *)item {
    NSString *source = item[@"source"] ?: @"";
    NSString *name = item[@"name"] ?: @"";
    NSString *displayName = [self displayNameForItem:item];
    if (name.length == 0) return nil;

    if ([displayName isEqualToString:@"cora"]) {
        return @"curl -fsSL https://cora.computer/install | bash";
    }
    if ([displayName isEqualToString:@"antigravity"]) {
        return @"curl -fsSL https://antigravity.google/cli/install.sh | bash";
    }
    if ([source isEqualToString:@"Homebrew"]) {
        return [NSString stringWithFormat:@"brew upgrade %@", name];
    }
    if ([source isEqualToString:@"Homebrew Cask"]) {
        return [NSString stringWithFormat:@"brew upgrade --cask %@", name];
    }
    if ([source isEqualToString:@"npm global"]) {
        return [NSString stringWithFormat:@"npm install -g %@", name];
    }
    return nil;
}

- (NSString *)updateTerminalCommandForItem:(NSDictionary *)item {
    NSString *command = [self updateCommandForItem:item];
    if (command.length == 0) return nil;

    NSString *title = [NSString stringWithFormat:@"CLI - Update %@", item[@"name"] ?: @"CLI"];
    NSString *markerPath = self.updateRefreshRequestURL.path ?: @"";
    NSString *markerDir = markerPath.stringByDeletingLastPathComponent;
    NSString *escapedCommand = ShellSingleQuoteEscaped(command);
    NSString *escapedTitle = ShellSingleQuoteEscaped(title);
    NSString *escapedMarkerDir = ShellSingleQuoteEscaped(markerDir);
    NSString *escapedMarkerPath = ShellSingleQuoteEscaped(markerPath);
    return [NSString stringWithFormat:@"printf '\\033]0;%@\\007'; echo 'Running %@'; echo; %@; status=$?; if [ $status -eq 0 ]; then mkdir -p '%@'; touch '%@'; fi; echo; echo \"Update finished with exit code $status.\"; echo 'CLI will refresh Updates Available automatically after successful updates.'; echo 'Press Return to close this session.'; read _; exec ${SHELL:-/bin/zsh} -l", escapedTitle, escapedCommand, command, escapedMarkerDir, escapedMarkerPath];
}

// Unique update commands for every outdated tool that supports in-app updates.
- (NSArray<NSString *> *)allUpdateCommands {
    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *item in [self notableUpdateItems:NSUIntegerMax]) {
        NSString *command = [self updateCommandForItem:item];
        if (command.length == 0 || [seen containsObject:command]) continue;
        [seen addObject:command];
        [commands addObject:command];
    }
    return commands;
}

- (NSString *)updateAllTerminalCommandWithCommands:(NSArray<NSString *> *)commands {
    NSString *markerPath = self.updateRefreshRequestURL.path ?: @"";
    NSString *markerDir = markerPath.stringByDeletingLastPathComponent;

    NSMutableString *script = [NSMutableString string];
    [script appendFormat:@"printf '\\033]0;CLI - Update All\\007'; echo 'Running %lu updates'; echo; failed=0; ", commands.count];
    for (NSString *command in commands) {
        [script appendFormat:@"echo '==> %@'; %@ || failed=$((failed+1)); echo; ", ShellSingleQuoteEscaped(command), command];
    }
    // Touch the marker even on partial failure so the app rescans and removes
    // whichever tools did update from the Updates Available list.
    [script appendFormat:@"mkdir -p '%@'; touch '%@'; ", ShellSingleQuoteEscaped(markerDir), ShellSingleQuoteEscaped(markerPath)];
    [script appendFormat:@"if [ $failed -eq 0 ]; then echo 'All %lu updates finished successfully.'; else echo \"$failed of %lu updates failed.\"; fi; ", commands.count, commands.count];
    [script appendString:@"echo 'CLI will remove updated tools from Updates Available automatically.'; echo 'Press Return to close this session.'; read _; exec ${SHELL:-/bin/zsh} -l"];
    return script;
}

- (void)updateAll:(id)sender {
    NSArray<NSString *> *commands = [self allUpdateCommands];
    if (commands.count == 0) {
        NSAlert *unsupported = [[NSAlert alloc] init];
        unsupported.messageText = @"No Updatable CLIs";
        unsupported.informativeText = @"None of the outdated tools support in-app updates. Use the package manager directly for these sources.";
        [unsupported addButtonWithTitle:@"OK"];
        [unsupported runModal];
        return;
    }

    NSAlert *confirmAlert = [[NSAlert alloc] init];
    confirmAlert.messageText = [NSString stringWithFormat:@"Update all %lu CLIs?", commands.count];
    confirmAlert.informativeText = [NSString stringWithFormat:@"CLI will open %@ and run:\n\n%@", self.preferredTerminal ?: DefaultTerminalName(), [commands componentsJoinedByString:@"\n"]];
    [confirmAlert addButtonWithTitle:@"Update All"];
    [confirmAlert addButtonWithTitle:@"Cancel"];
    if ([confirmAlert runModal] != NSAlertFirstButtonReturn) return;

    NSString *terminalCommand = [self updateAllTerminalCommandWithCommands:commands];
    [self runShellCommand:terminalCommand inTerminal:self.preferredTerminal ?: DefaultTerminalName()];
}

- (NSString *)displayNameForItem:(NSDictionary *)item {
    NSString *name = item[@"name"] ?: @"";
    return PackageAliases()[name] ?: name;
}

- (NSString *)titleNameForItem:(NSDictionary *)item {
    NSString *displayName = [self displayNameForItem:item];
    if ([AgentToolNames() containsObject:displayName]) return [self friendlyAgentName:displayName];
    return item[@"name"] ?: @"";
}

- (NSString *)versionSummaryForItem:(NSDictionary *)item {
    NSString *current = item[@"currentVersion"] ?: @"installed";
    NSString *latest = item[@"latestVersion"];
    if ([item[@"status"] isEqualToString:StatusOutdated] && latest.length > 0) {
        return [NSString stringWithFormat:@"%@ → %@", current, latest];
    }
    return current;
}

- (NSString *)friendlyAgentName:(NSString *)canonicalName {
    NSDictionary *meta = AgentBrandMetadata()[canonicalName];
    return meta[@"label"] ?: canonicalName;
}

- (NSInteger)sourcePriorityForItem:(NSDictionary *)item canonicalName:(NSString *)canonicalName {
    NSString *source = item[@"source"] ?: @"";
    NSString *name = item[@"name"] ?: @"";

    if ([canonicalName isEqualToString:@"claude"] && [name isEqualToString:@"@anthropic-ai/claude-code"]) return 120;
    if ([canonicalName isEqualToString:@"antigravity"] && [name isEqualToString:@"agy"]) return 120;
    if ([canonicalName isEqualToString:@"amp"] && [name isEqualToString:@"@sourcegraph/amp"]) return 120;
    if ([canonicalName isEqualToString:@"cora"] && [name isEqualToString:@"cora"]) return 120;
    if ([canonicalName isEqualToString:@"pi"] && [name isEqualToString:@"@mariozechner/pi-coding-agent"]) return 120;
    if ([canonicalName isEqualToString:@"notion"] && [name isEqualToString:@"notionctl"]) return 120;
    if ([canonicalName isEqualToString:@"notion"] && [name isEqualToString:@"ntn"]) return 120;
    if ([canonicalName isEqualToString:@"notion"] && [name isEqualToString:@"notion"]) return 110;
    if ([canonicalName isEqualToString:@"goose"] && [name isEqualToString:@"block-goose-cli"]) return 115;
    if ([canonicalName isEqualToString:@"kisuke"] && [name isEqualToString:@"kisuke-cli-dev"]) return 115;

    if ([source isEqualToString:@"Homebrew Cask"]) return 105;
    if ([source isEqualToString:@"Homebrew"]) return 100;
    if ([source isEqualToString:@"npm global"]) return 90;
    if ([source isEqualToString:@"Bun global"]) return 70;
    if ([source isEqualToString:@"uv tool"]) return 65;
    if ([source isEqualToString:@"PATH"]) return 20;
    return 40;
}

- (NSInteger)agentScoreForItem:(NSDictionary *)item canonicalName:(NSString *)canonicalName {
    NSInteger score = [self sourcePriorityForItem:item canonicalName:canonicalName];
    if (item[@"currentVersion"]) score += 20;
    if (item[@"latestVersion"]) score += 10;
    if ([item[@"status"] isEqualToString:StatusOutdated]) score += 8;
    return score;
}

- (NSArray<NSDictionary *> *)agentTools {
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *item in self.items) {
        NSString *displayName = [self displayNameForItem:item];
        if (![AgentToolNames() containsObject:displayName]) continue;

        NSDictionary *existing = byName[displayName];
        if (!existing) {
            byName[displayName] = item;
            continue;
        }

        NSInteger itemScore = [self agentScoreForItem:item canonicalName:displayName];
        NSInteger existingScore = [self agentScoreForItem:existing canonicalName:displayName];
        if (itemScore > existingScore) {
            byName[displayName] = item;
        }
    }

    NSMutableArray *ordered = [NSMutableArray array];
    for (NSString *name in PreferredAgentOrder()) {
        NSDictionary *item = byName[name];
        if (item) [ordered addObject:item];
    }
    return ordered;
}

- (NSString *)agentRowTitle:(NSDictionary *)item {
    NSString *label = [self friendlyAgentName:[self displayNameForItem:item]];
    return [NSString stringWithFormat:@"%@  %@", label, [self versionSummaryForItem:item]];
}

- (NSMenuItem *)agentMenuItemForItem:(NSDictionary *)item {
    NSString *canonicalName = [self displayNameForItem:item];
    NSMenuItem *row = [[NSMenuItem alloc] initWithTitle:[self agentRowTitle:item] action:@selector(openAgentTool:) keyEquivalent:@""];
    row.target = self;
    row.representedObject = item;
    row.toolTip = item[@"path"];
    row.image = AgentIcon(canonicalName);
    return row;
}

- (NSString *)commandForAgentItem:(NSDictionary *)item {
    NSString *canonicalName = [self displayNameForItem:item];
    NSString *path = item[@"path"];
    if (path.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;

    NSString *command = AgentInvocationName(canonicalName);
    NSString *resolved = CommandPath(command);
    if (resolved.length > 0) return resolved;

    NSArray *fallbackDirs = @[
        @"/opt/homebrew/bin",
        @"/usr/local/bin",
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".npm-global/bin"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".bun/bin"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".claude/local/bin"]
    ];
    for (NSString *dir in fallbackDirs) {
        NSString *candidate = [dir stringByAppendingPathComponent:command];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) return candidate;
    }

    return command;
}

- (NSString *)launchCommandWithLabel:(NSString *)label executable:(NSString *)command {
    NSString *escapedCommand = ShellSingleQuoteEscaped(command);
    NSString *escapedLabel = ShellSingleQuoteEscaped(label);
    return [NSString stringWithFormat:@"printf '\\033]0;CLI - %@\\007'; echo 'Launching %@'; echo; '%@'; echo; echo 'Session finished. Close this window or continue using the shell.'; exec ${SHELL:-/bin/zsh} -l", escapedLabel, escapedLabel, escapedCommand];
}

- (NSString *)launchCommandForAgentItem:(NSDictionary *)item {
    NSString *label = [self friendlyAgentName:[self displayNameForItem:item]];
    return [self launchCommandWithLabel:label executable:[self commandForAgentItem:item]];
}

- (NSString *)invocationForCLIItem:(NSDictionary *)item {
    NSString *displayName = [self displayNameForItem:item];
    if ([AgentToolNames() containsObject:displayName]) return AgentInvocationName(displayName);

    NSString *name = item[@"name"] ?: @"";
    NSString *path = item[@"path"];
    return name.length > 0 ? name : path.lastPathComponent;
}

- (NSString *)launchCommandForCLIItem:(NSDictionary *)item {
    NSString *label = [self friendlyAgentName:[self displayNameForItem:item]];
    if (label.length == 0) label = item[@"name"] ?: @"CLI";
    return [self launchCommandWithLabel:label executable:[self invocationForCLIItem:item]];
}

- (NSArray<NSString *> *)availableTerminals {
    NSMutableArray *terminals = [NSMutableArray arrayWithObject:@"Terminal"];
    for (NSDictionary *terminal in TerminalCandidates()) {
        if (FindApplicationPath(terminal[@"apps"])) [terminals addObject:terminal[@"name"]];
    }
    return terminals;
}

- (void)runShellCommand:(NSString *)command inTerminal:(NSString *)terminal {
    NSString *ghosttyPath = FindApplicationPath(@[@"Ghostty.app"]);
    if ([terminal isEqualToString:@"Ghostty"] && ghosttyPath.length > 0) {
        RunCommand(@"/usr/bin/osascript", @[
            @"-e", @"on run argv",
            @"-e", @"tell application \"Ghostty\"",
            @"-e", @"activate",
            @"-e", @"set cliTickerConfig to new surface configuration",
            @"-e", @"set initial input of cliTickerConfig to item 1 of argv & return",
            @"-e", @"new window with configuration cliTickerConfig",
            @"-e", @"end tell",
            @"-e", @"end run",
            @"--",
            command
        ]);
        return;
    }

    if ([terminal isEqualToString:@"iTerm"] && FindApplicationPath(@[@"iTerm.app", @"iTerm2.app"])) {
        NSString *script = [NSString stringWithFormat:
            @"tell application \"iTerm\"\n"
             "activate\n"
             "create window with default profile command \"%@\"\n"
             "end tell",
            EscapedAppleScriptString(command)
        ];
        RunCommand(@"/usr/bin/osascript", @[@"-e", script]);
        return;
    }

    if ([terminal isEqualToString:@"Warp"] && FindApplicationPath(@[@"Warp.app"])) {
        RunCommand(@"/usr/bin/open", @[@"-a", @"Warp"]);
        NSString *script = [NSString stringWithFormat:
            @"tell application \"System Events\"\n"
             "keystroke \"%@\"\n"
             "key code 36\n"
             "end tell",
            EscapedAppleScriptString(command)
        ];
        RunCommand(@"/usr/bin/osascript", @[@"-e", script]);
        return;
    }

    NSString *script = [NSString stringWithFormat:
        @"tell application \"Terminal\"\n"
         "activate\n"
         "do script \"%@\"\n"
         "end tell",
        EscapedAppleScriptString(command)
    ];
    RunCommand(@"/usr/bin/osascript", @[@"-e", script]);
}

- (NSMenuItem *)summaryMenuItem {
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    if (@available(macOS 26.0, *)) {
        NSUInteger outdated = [self countWithStatus:StatusOutdated];

        NSRect frame = NSMakeRect(0, 0, 330, 82);
        NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:frame];
        glass.style = NSGlassEffectViewStyleRegular;
        glass.cornerRadius = 18;
        glass.tintColor = [NSColor colorWithCalibratedRed:0.06 green:0.12 blue:0.28 alpha:0.34];
        glass.wantsLayer = YES;
        glass.layer.borderWidth = 1.0;
        glass.layer.borderColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.18] CGColor];
        glass.layer.shadowColor = [[NSColor blackColor] CGColor];
        glass.layer.shadowOpacity = 0.22;
        glass.layer.shadowRadius = 14.0;
        glass.layer.shadowOffset = NSMakeSize(0, -5);

        NSView *content = [[NSView alloc] initWithFrame:frame];
        content.wantsLayer = YES;
        content.layer.cornerRadius = 18;
        content.layer.masksToBounds = YES;
        content.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.03 green:0.07 blue:0.16 alpha:0.24] CGColor];
        glass.contentView = content;

        NSView *topSheen = [[NSView alloc] initWithFrame:NSMakeRect(1, 40, 328, 41)];
        topSheen.wantsLayer = YES;
        topSheen.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:1.0 alpha:0.09] CGColor];
        topSheen.layer.cornerRadius = 17;
        [content addSubview:topSheen];

        NSView *bottomDepth = [[NSView alloc] initWithFrame:NSMakeRect(1, 1, 328, 31)];
        bottomDepth.wantsLayer = YES;
        bottomDepth.layer.backgroundColor = [[NSColor colorWithCalibratedRed:0.0 green:0.02 blue:0.07 alpha:0.12] CGColor];
        bottomDepth.layer.cornerRadius = 17;
        [content addSubview:bottomDepth];

        NSString *state = self.refreshing ? @"Refreshing inventory…" : @"Local CLI inventory";
        NSColor *primaryText = [NSColor colorWithCalibratedWhite:0.96 alpha:1.0];
        NSColor *secondaryText = [NSColor colorWithCalibratedWhite:0.76 alpha:1.0];
        [content addSubview:GlassLabel(@"CLI", NSMakeRect(18, 49, 185, 22), [NSFont boldSystemFontOfSize:17], primaryText, NSTextAlignmentLeft)];
        [content addSubview:GlassLabel(state, NSMakeRect(18, 30, 185, 18), [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], secondaryText, NSTextAlignmentLeft)];
        [content addSubview:GlassLabel([NSString stringWithFormat:@"%lu CLIs", self.items.count], NSMakeRect(218, 51, 92, 16), [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold], primaryText, NSTextAlignmentRight)];
        NSColor *updateText = outdated > 0 ? [NSColor colorWithCalibratedRed:1.0 green:0.58 blue:0.20 alpha:1.0] : secondaryText;
        [content addSubview:GlassLabel([NSString stringWithFormat:@"%lu updates", outdated], NSMakeRect(218, 32, 92, 16), [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular], updateText, NSTextAlignmentRight)];

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        item.view = glass;
        return item;
    }
#endif

    NSMenuItem *summary = [[NSMenuItem alloc] initWithTitle:[self summaryTitle] action:nil keyEquivalent:@""];
    summary.enabled = NO;
    return summary;
}

- (NSArray<NSDictionary *> *)notableUpdateItems:(NSUInteger)limit {
    NSMutableArray *updates = [NSMutableArray array];
    for (NSDictionary *item in self.items) {
        if (![item[@"status"] isEqualToString:StatusOutdated]) continue;
        [updates addObject:item];
        if (updates.count >= limit) break;
    }
    return updates;
}

- (NSMenuItem *)notableUpdateMenuItemForItem:(NSDictionary *)item {
    NSMenuItem *row = [[NSMenuItem alloc] initWithTitle:[self friendlyUpdateTitle:item] action:@selector(applyUpdate:) keyEquivalent:@""];
    row.target = self;
    row.representedObject = item;
    row.toolTip = item[@"path"];
    row.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:@"Update available"];
    return row;
}

- (NSMenuItem *)recentChangeMenuItemForChange:(NSDictionary *)change {
    NSMenuItem *row = [[NSMenuItem alloc] initWithTitle:[self recentChangeTitle:change] action:@selector(openRecentChange:) keyEquivalent:@""];
    NSDictionary *item = [self inventoryItemForChange:change];
    row.target = item ? self : nil;
    row.enabled = item != nil;
    row.representedObject = item;
    row.toolTip = item[@"path"];
    row.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle" accessibilityDescription:@"Recently updated"];
    return row;
}

- (NSMenuItem *)terminalPreferenceMenuItem {
    NSMenuItem *folder = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Preferred Terminal: %@", self.preferredTerminal] action:nil keyEquivalent:@""];
    folder.image = [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:@"Preferred Terminal"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Preferred Terminal"];

    for (NSString *terminal in [self availableTerminals]) {
        NSString *title = [terminal isEqualToString:self.preferredTerminal] ? [NSString stringWithFormat:@"%@ selected", terminal] : terminal;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectTerminal:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = terminal;
        item.state = [terminal isEqualToString:self.preferredTerminal] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }

    folder.submenu = menu;
    return folder;
}

- (NSMenuItem *)reportMenuItem {
    NSMenuItem *folder = [[NSMenuItem alloc] initWithTitle:@"Open Report" action:nil keyEquivalent:@""];
    folder.image = [NSImage imageWithSystemSymbolName:@"doc.text" accessibilityDescription:@"Open Report"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Open Report"];

    NSMenuItem *json = [[NSMenuItem alloc] initWithTitle:@"JSON Report" action:@selector(openJSONReport:) keyEquivalent:@"j"];
    json.target = self;
    json.image = [NSImage imageWithSystemSymbolName:@"curlybraces" accessibilityDescription:@"JSON Report"];
    [menu addItem:json];

    NSMenuItem *markdown = [[NSMenuItem alloc] initWithTitle:@"Markdown Report" action:@selector(openMarkdownReport:) keyEquivalent:@"m"];
    markdown.target = self;
    markdown.image = [NSImage imageWithSystemSymbolName:@"doc.plaintext" accessibilityDescription:@"Markdown Report"];
    [menu addItem:markdown];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *note = [[NSMenuItem alloc] initWithTitle:@"Markdown is generated from the latest scan" action:nil keyEquivalent:@""];
    note.enabled = NO;
    [menu addItem:note];

    folder.submenu = menu;
    return folder;
}

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItem:[self summaryMenuItem]];
    [menu addItem:[NSMenuItem separatorItem]];

    NSArray *agents = [self agentTools];
    if (agents.count > 0) {
        NSMenuItem *agentFolder = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Agent Tools  %lu", agents.count] action:nil keyEquivalent:@""];
        agentFolder.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:@"Agent Tools"];
        NSMenu *agentMenu = [[NSMenu alloc] initWithTitle:@"Agent Tools"];
        NSMenuItem *folderSummary = [[NSMenuItem alloc] initWithTitle:@"Installed agent CLIs" action:nil keyEquivalent:@""];
        folderSummary.enabled = NO;
        [agentMenu addItem:folderSummary];
        [agentMenu addItem:[NSMenuItem separatorItem]];
        for (NSDictionary *item in agents) {
            [agentMenu addItem:[self agentMenuItemForItem:item]];
        }
        [agentMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *agentNote = [[NSMenuItem alloc] initWithTitle:@"Full details are saved in the JSON report" action:nil keyEquivalent:@""];
        agentNote.enabled = NO;
        [agentMenu addItem:agentNote];
        agentFolder.submenu = agentMenu;
        [menu addItem:agentFolder];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    // The Updates Available section is always visible so Update All is always
    // discoverable; rows and actions adapt to whether anything is outdated.
    NSArray *notableUpdates = [self notableUpdateItems:14];
    NSUInteger totalUpdates = [self countWithStatus:StatusOutdated];
    {
        NSString *folderTitle = totalUpdates > 0
            ? [NSString stringWithFormat:@"Updates Available  %lu", totalUpdates]
            : @"Updates Available";
        NSMenuItem *updatesFolder = [[NSMenuItem alloc] initWithTitle:folderTitle action:nil keyEquivalent:@""];
        updatesFolder.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle" accessibilityDescription:@"Notable Updates"];
        NSMenu *updatesMenu = [[NSMenu alloc] initWithTitle:@"Notable Updates"];
        NSString *summaryText = totalUpdates > 0 ? @"Newest versions found" : @"All scanned CLIs are up to date";
        NSMenuItem *updatesSummary = [[NSMenuItem alloc] initWithTitle:summaryText action:nil keyEquivalent:@""];
        updatesSummary.enabled = NO;
        [updatesMenu addItem:updatesSummary];
        [updatesMenu addItem:[NSMenuItem separatorItem]];

        NSString *updateAllTitle = totalUpdates > 0
            ? [NSString stringWithFormat:@"Update All %lu…", totalUpdates]
            : @"Update All…";
        NSMenuItem *updateAll = [[NSMenuItem alloc] initWithTitle:updateAllTitle action:@selector(updateAll:) keyEquivalent:@"u"];
        updateAll.target = totalUpdates > 0 ? self : nil;
        updateAll.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle.fill" accessibilityDescription:@"Update All"];
        [updatesMenu addItem:updateAll];

        if (notableUpdates.count > 0) {
            [updatesMenu addItem:[NSMenuItem separatorItem]];
            for (NSDictionary *item in notableUpdates) {
                [updatesMenu addItem:[self notableUpdateMenuItemForItem:item]];
            }
            [updatesMenu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *showAll = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Show All %lu Updates…", totalUpdates] action:@selector(showAllUpdates:) keyEquivalent:@""];
            showAll.target = self;
            showAll.image = [NSImage imageWithSystemSymbolName:@"list.bullet.rectangle" accessibilityDescription:@"Show All Updates"];
            [updatesMenu addItem:showAll];
            NSString *noteText = totalUpdates > notableUpdates.count
                ? [NSString stringWithFormat:@"Showing %lu of %lu updates", notableUpdates.count, totalUpdates]
                : @"Click an update to apply it";
            NSMenuItem *updatesNote = [[NSMenuItem alloc] initWithTitle:noteText action:nil keyEquivalent:@""];
            updatesNote.enabled = NO;
            [updatesMenu addItem:updatesNote];
        }
        updatesFolder.submenu = updatesMenu;
        [menu addItem:updatesFolder];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSArray *recentChanges = [self prunedChanges:self.recentChanges];
    if (recentChanges.count > 0) {
        NSMenuItem *recentFolder = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Recently Updated  %lu", recentChanges.count] action:nil keyEquivalent:@""];
        recentFolder.image = [NSImage imageWithSystemSymbolName:@"clock.arrow.circlepath" accessibilityDescription:@"Recently Updated"];
        NSMenu *recentMenu = [[NSMenu alloc] initWithTitle:@"Recently Updated"];
        NSMenuItem *recentSummary = [[NSMenuItem alloc] initWithTitle:@"Installs and updates detected automatically" action:nil keyEquivalent:@""];
        recentSummary.enabled = NO;
        [recentMenu addItem:recentSummary];
        [recentMenu addItem:[NSMenuItem separatorItem]];
        for (NSDictionary *change in recentChanges) {
            [recentMenu addItem:[self recentChangeMenuItemForChange:change]];
        }
        recentFolder.submenu = recentMenu;
        [menu addItem:recentFolder];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSUInteger shown = agents.count + notableUpdates.count;
    if (self.items.count > shown) {
        NSMenuItem *overflow = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%lu more saved in report", self.items.count - shown] action:nil keyEquivalent:@""];
        overflow.enabled = NO;
        [menu addItem:overflow];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self terminalPreferenceMenuItem]];
    NSMenuItem *search = [[NSMenuItem alloc] initWithTitle:@"Search CLIs" action:@selector(searchCLIs:) keyEquivalent:@"f"];
    search.target = self;
    search.image = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:@"Search CLIs"];
    [menu addItem:search];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:self.refreshing ? @"Refreshing..." : @"Refresh Now" action:@selector(refresh:) keyEquivalent:@"r"];
    refresh.target = self;
    [menu addItem:refresh];
    [menu addItem:[self reportMenuItem]];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)refresh:(id)sender {
    if (self.refreshing) return;
    self.refreshing = YES;
    [self rebuildMenu];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *fresh = [self.service refresh];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordChangesFromItems:self.items toItems:fresh];
            self.items = fresh;
            [self saveReport];
            self.refreshing = NO;
            [self rebuildMenu];
            [self reloadAllUpdatesDialog];
        });
    });
}

- (void)checkForUpdateRefreshRequest:(id)sender {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.updateRefreshRequestURL.path error:nil];
    NSDate *modified = attributes[NSFileModificationDate];
    if (!modified) return;
    if (self.lastHandledUpdateRefreshDate && [modified compare:self.lastHandledUpdateRefreshDate] != NSOrderedDescending) return;
    if (self.refreshing) return;

    self.lastHandledUpdateRefreshDate = modified;
    [self refresh:nil];
}

- (void)selectTerminal:(NSMenuItem *)sender {
    NSString *terminal = sender.representedObject;
    if (terminal.length == 0) return;
    self.preferredTerminal = terminal;
    [[NSUserDefaults standardUserDefaults] setObject:terminal forKey:@"PreferredTerminal"];
    [self rebuildMenu];
}

- (void)openAgentTool:(NSMenuItem *)sender {
    NSDictionary *item = sender.representedObject;
    if (![item isKindOfClass:[NSDictionary class]]) return;
    NSString *command = [self launchCommandForAgentItem:item];
    [self runShellCommand:command inTerminal:self.preferredTerminal ?: DefaultTerminalName()];
}

- (void)openRecentChange:(NSMenuItem *)sender {
    NSDictionary *item = sender.representedObject;
    if (![item isKindOfClass:[NSDictionary class]]) return;
    NSString *command = [self launchCommandForCLIItem:item];
    [self runShellCommand:command inTerminal:self.preferredTerminal ?: DefaultTerminalName()];
}

- (NSDictionary *)selectedSearchResultFromTable:(NSTableView *)tableView {
    NSInteger row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)self.searchResultItems.count) return nil;
    return self.searchResultItems[row];
}

- (void)openSelectedSearchResult:(NSTableView *)sender {
    NSDictionary *item = [self selectedSearchResultFromTable:sender];
    if (!item) return;

    NSString *command = [self launchCommandForCLIItem:item];
    [self runShellCommand:command inTerminal:self.preferredTerminal ?: DefaultTerminalName()];
}

- (void)copyLaunchScriptForSearchResult:(NSDictionary *)item {
    if (!item) return;

    NSString *script = [self invocationForCLIItem:item];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:script forType:NSPasteboardTypeString];
}

- (void)searchCLIs:(id)sender {
    NSAlert *prompt = [[NSAlert alloc] init];
    prompt.messageText = @"Search CLIs";
    prompt.informativeText = @"Search installed command names, sources, versions, statuses, and paths.";
    [prompt addButtonWithTitle:@"Search"];
    [prompt addButtonWithTitle:@"Cancel"];

    NSSearchField *field = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 360, 26)];
    field.placeholderString = @"codex, npm, outdated, /opt/homebrew...";
    prompt.accessoryView = field;

    NSModalResponse response = [prompt runModal];
    if (response != NSAlertFirstButtonReturn) return;

    NSString *query = field.stringValue ?: @"";
    NSArray<NSDictionary *> *matches = [self searchItemsMatching:query limit:24];
    if (matches.count == 0) {
        NSAlert *empty = [[NSAlert alloc] init];
        empty.messageText = [NSString stringWithFormat:@"No CLIs Found for \"%@\"", query];
        empty.informativeText = @"Try searching by command name, package manager, version, status, or path.";
        [empty addButtonWithTitle:@"Done"];
        [empty runModal];
        return;
    }

    self.searchResultItems = matches;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 540, 190)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:scrollView.contentView.bounds];
    tableView.usesAlternatingRowBackgroundColors = YES;
    tableView.allowsMultipleSelection = NO;
    tableView.rowHeight = 22;
    tableView.target = self;
    tableView.doubleAction = @selector(openSelectedSearchResult:);
    tableView.dataSource = (id<NSTableViewDataSource>)self;
    tableView.delegate = (id<NSTableViewDelegate>)self;
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"tool" title:@"Tool" width:130]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"version" title:@"Version" width:78]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"source" title:@"Source" width:100]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"command" title:@"Command" width:220]];
    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    scrollView.documentView = tableView;
    self.searchResultsTableView = tableView;

    NSAlert *results = [[NSAlert alloc] init];
    results.messageText = [NSString stringWithFormat:@"Search Results for \"%@\"", query];
    results.informativeText = [NSString stringWithFormat:@"Double-click a CLI to open it in %@, or copy its bash launch script.", self.preferredTerminal ?: DefaultTerminalName()];
    results.accessoryView = scrollView;
    [results addButtonWithTitle:@"Done"];
    [results addButtonWithTitle:@"Copy Bash Script"];
    if ([results runModal] == NSAlertSecondButtonReturn) {
        [self copyLaunchScriptForSearchResult:[self selectedSearchResultFromTable:tableView]];
    }

    self.searchResultsTableView = nil;
    self.searchResultItems = nil;
}

- (void)showAllUpdates:(id)sender {
    NSArray<NSDictionary *> *updates = [self notableUpdateItems:NSUIntegerMax];
    if (updates.count == 0) return;
    self.allUpdateItems = updates;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 760, 320)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:scrollView.contentView.bounds];
    tableView.usesAlternatingRowBackgroundColors = YES;
    tableView.allowsMultipleSelection = NO;
    tableView.rowHeight = 24;
    tableView.target = self;
    tableView.doubleAction = @selector(updateSelectedFromAllUpdates:);
    tableView.dataSource = (id<NSTableViewDataSource>)self;
    tableView.delegate = (id<NSTableViewDelegate>)self;
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"tool" title:@"Tool" width:150]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"current" title:@"Current" width:95]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"latest" title:@"Latest" width:95]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"source" title:@"Source" width:120]];
    [tableView addTableColumn:[self updateTableColumnWithIdentifier:@"command" title:@"Command" width:285]];
    scrollView.documentView = tableView;
    self.allUpdatesTableView = tableView;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"All Updates Available (%lu)", updates.count];
    alert.informativeText = [NSString stringWithFormat:@"Double-click an update to run it in %@.", self.preferredTerminal ?: DefaultTerminalName()];
    alert.accessoryView = scrollView;
    self.allUpdatesAlert = alert;
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Update All…"];
    [alert addButtonWithTitle:@"Open Markdown Report"];
    NSModalResponse response = [alert runModal];
    self.allUpdatesAlert = nil;
    self.allUpdatesTableView = nil;
    self.allUpdateItems = nil;

    if (response == NSAlertSecondButtonReturn) {
        [self updateAll:nil];
    } else if (response == NSAlertThirdButtonReturn) {
        [self openMarkdownReport:nil];
    }
}

- (void)updateSelectedFromAllUpdates:(NSTableView *)sender {
    NSInteger row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow;
    if (row < 0 || row >= (NSInteger)self.allUpdateItems.count) return;

    NSDictionary *item = self.allUpdateItems[row];
    [self runUpdateForItem:item confirm:NO];
}

- (void)applyUpdate:(NSMenuItem *)sender {
    NSDictionary *item = sender.representedObject;
    if (![item isKindOfClass:[NSDictionary class]]) return;
    [self runUpdateForItem:item confirm:YES];
}

- (void)openJSONReport:(id)sender {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.reportURL]];
}

- (void)openMarkdownReport:(id)sender {
    [self saveMarkdownReport];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[self.markdownReportURL]];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property MenuController *menuController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.menuController = [[MenuController alloc] init];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
