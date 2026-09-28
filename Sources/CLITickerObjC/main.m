#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>
#import "CLIRegistry.h"
#import "PanelPreview.h"
#import "TickerPanel.h"

static NSString *const StatusCurrent = @"current";
static NSString *const StatusOutdated = @"outdated";
static NSString *const StatusUnknown = @"unknown";

static NSString *const ChangeKindInstalled = @"installed";
static NSString *const ChangeKindUpdated = @"updated";

// How long an install/update event stays visible in the Recently Updated bucket.
static const NSTimeInterval RecentChangeLifetime = 24 * 60 * 60;
static const NSUInteger RecentChangeCapacity = 20;

@interface CommandResult : NSObject
@property NSString *standardOutput;
@property NSString *standardError;
@property int terminationStatus;
@property BOOL timedOut;
@property NSString *launchError;
@end

@implementation CommandResult
@end

// After a timeout, how long the process group gets to exit on SIGTERM before SIGKILL.
static const NSTimeInterval CommandTerminateGracePeriod = 2;
// After the command exits, how long to keep reading while a background
// descendant still holds its stdout or stderr open.
static const NSTimeInterval CommandOutputDrainPeriod = 1;

static NSTimeInterval MonotonicNow(void) {
    return [NSProcessInfo processInfo].systemUptime;
}

static char **CStringArray(NSArray<NSString *> *strings) {
    char **array = calloc(strings.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < strings.count; i++) {
        array[i] = strdup(strings[i].UTF8String ?: "");
    }
    return array;
}

static void FreeCStringArray(char **array) {
    for (char **entry = array; *entry; entry++) free(*entry);
    free(array);
}

static BOOL ReapChild(pid_t pid, int *status) {
    pid_t reaped;
    do {
        reaped = waitpid(pid, status, WNOHANG);
    } while (reaped == -1 && errno == EINTR);
    return reaped == pid || (reaped == -1 && errno == ECHILD);
}

// Reads everything currently available from a non-blocking descriptor and
// closes it at EOF or on error.
static void DrainDescriptor(int *fd, NSMutableData *data) {
    if (*fd < 0) return;
    uint8_t buffer[16384];
    while (YES) {
        ssize_t count = read(*fd, buffer, sizeof(buffer));
        if (count > 0) {
            [data appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && errno == EAGAIN) return;
        close(*fd);
        *fd = -1;
        return;
    }
}

static CommandResult *RunCommandWithTimeout(NSString *launchPath, NSArray<NSString *> *arguments, NSTimeInterval timeout) {
    CommandResult *result = [[CommandResult alloc] init];
    result.standardOutput = @"";
    result.standardError = @"";
    result.terminationStatus = -1;
    if (launchPath.length == 0) {
        result.launchError = @"No executable path";
        return result;
    }

    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"HOMEBREW_NO_AUTO_UPDATE"] = @"1";
    environment[@"HOMEBREW_NO_ANALYTICS"] = @"1";
    environment[@"HOMEBREW_NO_INSTALL_CLEANUP"] = @"1";
    NSMutableArray<NSString *> *environmentStrings = [NSMutableArray array];
    [environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [environmentStrings addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }];
    NSMutableArray<NSString *> *argumentStrings = [NSMutableArray arrayWithObject:launchPath];
    [argumentStrings addObjectsFromArray:arguments ?: @[]];

    int stdoutPipe[2];
    int stderrPipe[2];
    if (pipe(stdoutPipe) != 0) {
        result.launchError = @(strerror(errno));
        return result;
    }
    if (pipe(stderrPipe) != 0) {
        result.launchError = @(strerror(errno));
        close(stdoutPipe[0]);
        close(stdoutPipe[1]);
        return result;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO);

    // The child leads its own process group so a timeout can signal every
    // descendant, and inherits only stdin/stdout/stderr so pipes from
    // concurrent commands cannot leak into it and delay their EOF.
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, (short)(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT));
    posix_spawnattr_setpgroup(&attributes, 0);
    sigset_t signals;
    sigemptyset(&signals);
    posix_spawnattr_setsigmask(&attributes, &signals);
    sigaddset(&signals, SIGPIPE);
    sigaddset(&signals, SIGHUP);
    sigaddset(&signals, SIGINT);
    sigaddset(&signals, SIGQUIT);
    sigaddset(&signals, SIGTERM);
    posix_spawnattr_setsigdefault(&attributes, &signals);

    char **argv = CStringArray(argumentStrings);
    char **envp = CStringArray(environmentStrings);
    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, launchPath.fileSystemRepresentation, &actions, &attributes, argv, envp);
    FreeCStringArray(argv);
    FreeCStringArray(envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(stdoutPipe[1]);
    close(stderrPipe[1]);

    if (spawnError != 0) {
        result.launchError = @(strerror(spawnError));
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        return result;
    }

    int fds[2] = {stdoutPipe[0], stderrPipe[0]};
    NSMutableData *outputs[2] = {[NSMutableData data], [NSMutableData data]};
    for (int i = 0; i < 2; i++) {
        int flags = fcntl(fds[i], F_GETFL);
        if (flags != -1) fcntl(fds[i], F_SETFL, flags | O_NONBLOCK);
    }

    NSTimeInterval deadline = MonotonicNow() + timeout;
    NSTimeInterval exitedAt = 0;
    int status = 0;
    BOOL exited = NO;
    while (YES) {
        if (!exited && ReapChild(pid, &status)) {
            exited = YES;
            exitedAt = MonotonicNow();
        }
        NSTimeInterval now = MonotonicNow();
        if (exited && ((fds[0] < 0 && fds[1] < 0) || now - exitedAt >= CommandOutputDrainPeriod)) break;
        if (!exited && now >= deadline) {
            result.timedOut = YES;
            break;
        }

        struct pollfd pollfds[2];
        nfds_t pollCount = 0;
        for (int i = 0; i < 2; i++) {
            if (fds[i] < 0) continue;
            pollfds[pollCount].fd = fds[i];
            pollfds[pollCount].events = POLLIN;
            pollfds[pollCount].revents = 0;
            pollCount++;
        }
        if (poll(pollfds, pollCount, 20) > 0) {
            for (int i = 0; i < 2; i++) DrainDescriptor(&fds[i], outputs[i]);
        }
    }

    if (result.timedOut) {
        kill(-pid, SIGTERM);
        NSTimeInterval killAt = MonotonicNow() + CommandTerminateGracePeriod;
        while (!(exited = ReapChild(pid, &status)) && MonotonicNow() < killAt) {
            for (int i = 0; i < 2; i++) DrainDescriptor(&fds[i], outputs[i]);
            usleep(20000);
        }
        // The group ID cannot be reused while any member is alive, so this
        // only reaches descendants that outlived or ignored SIGTERM.
        kill(-pid, SIGKILL);
        if (!exited) {
            while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}
        }
    }

    for (int i = 0; i < 2; i++) {
        DrainDescriptor(&fds[i], outputs[i]);
        if (fds[i] >= 0) close(fds[i]);
    }
    result.standardOutput = [[NSString alloc] initWithData:outputs[0] encoding:NSUTF8StringEncoding] ?: @"";
    result.standardError = [[NSString alloc] initWithData:outputs[1] encoding:NSUTF8StringEncoding] ?: @"";
    if (WIFEXITED(status)) {
        result.terminationStatus = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        result.terminationStatus = WTERMSIG(status);
    }
    return result;
}

static NSString *RunCommand(NSString *launchPath, NSArray<NSString *> *arguments) {
    CommandResult *result = RunCommandWithTimeout(launchPath, arguments, 120);
    if (result.timedOut) {
        NSLog(@"Command timed out: %@", launchPath.lastPathComponent);
    } else if (result.launchError.length > 0) {
        NSLog(@"Command failed to launch: %@", launchPath.lastPathComponent);
    }
    return result.standardOutput;
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

static NSArray<NSString *> *PreferredAgentOrder(void) {
    return @[
        @"codex",
        @"notion",
        @"antigravity",
        @"claude",
        @"gemini",
        @"amp",
        @"cora",
        @"cursor",
        @"cursor-agent",
        @"goose",
        @"opencode",
        @"aider",
        @"qwen",
        @"crush",
        @"copilot",
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

// Canonical agent names; installed names are mapped here via PackageAliases().
static NSSet<NSString *> *AgentToolNames(void) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:PreferredAgentOrder()];
    });
    return names;
}

static NSDictionary<NSString *, NSString *> *PackageAliases(void) {
    static NSDictionary<NSString *, NSString *> *aliases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aliases = @{
            @"agy": @"antigravity",
            @"@anthropic-ai/claude-code": @"claude",
            @"@openai/codex": @"codex",
            @"@google/gemini-cli": @"gemini",
            @"gemini-cli": @"gemini",
            @"aider-chat": @"aider",
            @"aider-install": @"aider",
            @"opencode-ai": @"opencode",
            @"@qwen-code/qwen-code": @"qwen",
            @"@charmland/crush": @"crush",
            @"@github/copilot": @"copilot",
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
            @"gemini": @{@"label": @"Gemini", @"mark": @"GE", @"color": [NSColor colorWithCalibratedRed:0.26 green:0.45 blue:0.93 alpha:1.0]},
            @"aider": @{@"label": @"Aider", @"mark": @"AI", @"color": [NSColor colorWithCalibratedRed:0.20 green:0.60 blue:0.36 alpha:1.0]},
            @"qwen": @{@"label": @"Qwen Code", @"mark": @"QW", @"color": [NSColor colorWithCalibratedRed:0.38 green:0.30 blue:0.86 alpha:1.0]},
            @"crush": @{@"label": @"Crush", @"mark": @"CR", @"color": [NSColor colorWithCalibratedRed:0.86 green:0.30 blue:0.56 alpha:1.0]},
            @"copilot": @{@"label": @"Copilot", @"mark": @"GH", @"color": [NSColor colorWithCalibratedWhite:0.20 alpha:1.0]},
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

// Leaves plain words such as `brew`, `--cask` or `@scope/pkg@1.2` readable.
// The safe set excludes `=`, `~` and glob characters because zsh expands them.
static NSString *ShellQuotedArgument(NSString *argument) {
    static NSCharacterSet *unsafeCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsafeCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@+:,./_-"] invertedSet];
    });
    if (argument.length > 0 && [argument rangeOfCharacterFromSet:unsafeCharacters].location == NSNotFound) return argument;
    return [NSString stringWithFormat:@"'%@'", ShellSingleQuoteEscaped(argument ?: @"")];
}

static NSDictionary *UpdateActionForItem(NSDictionary *item, NSString *displayName) {
    NSString *source = item[@"source"] ?: @"";
    NSString *name = item[@"name"] ?: @"";
    if (name.length == 0) return nil;

    // These fixed vendor installers intentionally require shell pipelines. No
    // inventory-derived value is interpolated into either script.
    if ([displayName isEqualToString:@"cora"]) {
        return @{@"script": @"curl -fsSL https://cora.computer/install | bash"};
    }
    if ([displayName isEqualToString:@"antigravity"]) {
        return @{@"script": @"curl -fsSL https://antigravity.google/cli/install.sh | bash"};
    }
    if ([source isEqualToString:@"Homebrew"]) {
        return @{@"executable": @"brew", @"arguments": @[@"upgrade", name]};
    }
    if ([source isEqualToString:@"Homebrew Cask"]) {
        return @{@"executable": @"brew", @"arguments": @[@"upgrade", @"--cask", name]};
    }
    if ([source isEqualToString:@"npm global"]) {
        return @{@"executable": @"npm", @"arguments": @[@"install", @"-g", name]};
    }
    return nil;
}

static NSString *ShellCommandForUpdateAction(NSDictionary *action) {
    NSString *script = action[@"script"];
    if (script.length > 0) return script;

    NSString *executable = action[@"executable"];
    NSArray<NSString *> *arguments = action[@"arguments"];
    if (executable.length == 0 || ![arguments isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithObject:ShellQuotedArgument(executable)];
    for (NSString *argument in arguments) {
        [words addObject:ShellQuotedArgument(argument)];
    }
    return [words componentsJoinedByString:@" "];
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

static BOOL ApplicationInstalled(NSArray<NSString *> *appNames) {
    NSArray<NSString *> *roots = @[
        @"/Applications",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]
    ];
    for (NSString *root in roots) {
        for (NSString *name in appNames) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:name]]) return YES;
        }
    }
    return NO;
}

// Optional terminals in preference order; Terminal.app is always available as the fallback.
static NSArray<NSDictionary *> *TerminalCandidates(void) {
    return @[
        @{@"name": @"Ghostty", @"apps": @[@"Ghostty.app"]},
        @{@"name": @"iTerm", @"apps": @[@"iTerm.app", @"iTerm2.app"]},
        @{@"name": @"Warp", @"apps": @[@"Warp.app"]}
    ];
}

static BOOL TerminalInstalled(NSString *terminalName) {
    for (NSDictionary *terminal in TerminalCandidates()) {
        if ([terminal[@"name"] isEqualToString:terminalName]) return ApplicationInstalled(terminal[@"apps"]);
    }
    return NO;
}

static NSString *DefaultTerminalName(void) {
    for (NSDictionary *terminal in TerminalCandidates()) {
        if (ApplicationInstalled(terminal[@"apps"])) return terminal[@"name"];
    }
    return @"Terminal";
}

// Common per-user and Homebrew bin directories where CLIs get installed.
static NSArray<NSString *> *CommonBinDirectories(void) {
    NSString *home = NSHomeDirectory();
    return @[
        @"/opt/homebrew/bin",
        @"/usr/local/bin",
        [home stringByAppendingPathComponent:@".local/bin"],
        [home stringByAppendingPathComponent:@".npm-global/bin"],
        [home stringByAppendingPathComponent:@".bun/bin"],
        [home stringByAppendingPathComponent:@".claude/local/bin"]
    ];
}

static void ShowInfoAlert(NSString *title, NSString *message, NSString *buttonTitle) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:buttonTitle];
    [alert runModal];
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

static NSString *const SourceLocalBin = @"~/.local/bin";
static NSString *const SourceAppBundle = @"App bundle";

// Executables found by listing a directory rather than asking a package manager. They are
// dropped when the PATH scan already found the same file, so each tool is listed once.
static NSSet<NSString *> *DirectorySources(void) {
    return [NSSet setWithArray:@[SourceLocalBin, SourceAppBundle, @"go"]];
}

// Unlisted executables whose name marks them as an AI agent (`acme-agent`, `llm`, `gpt-cli`).
static BOOL LooksLikeAgentName(NSString *name) {
    static NSSet<NSString *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSSet setWithArray:@[@"agent", @"agents", @"ai", @"llm", @"gpt", @"copilot", @"coder", @"claude", @"codex", @"gemini"]];
    });
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"-_./@"];
    for (NSString *token in [name.lowercaseString componentsSeparatedByCharactersInSet:separators]) {
        if ([tokens containsObject:token]) return YES;
    }
    return NO;
}

static NSArray<NSString *> *ExecutablesInDirectory(NSString *directory) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *name in [[fileManager contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) continue;
        if ([fileManager isExecutableFileAtPath:path]) [paths addObject:path];
    }
    return paths;
}

// Command-line tools shipped inside app bundles (Cursor, VS Code, Docker Desktop, ...).
static NSArray<NSString *> *AppBundleBinDirectories(NSArray<NSString *> *applicationRoots) {
    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    for (NSString *root in applicationRoots) {
        for (NSString *name in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![name.pathExtension isEqualToString:@"app"]) continue;
            NSString *contents = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Contents"];
            for (NSString *relative in @[@"Resources/app/bin", @"Resources/bin", @"SharedSupport/bin"]) {
                NSString *candidate = [contents stringByAppendingPathComponent:relative];
                BOOL isDirectory = NO;
                if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory] && isDirectory) [directories addObject:candidate];
            }
        }
    }
    return directories;
}

// `cargo install --list` prints "name v1.2.3:" followed by indented binary names.
static NSArray<NSMutableDictionary *> *ParseCargoInstallList(NSString *output, NSString *binDirectory) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        if (![line hasPrefix:@" "] && ![line hasPrefix:@"\t"]) {
            NSArray<NSString *> *parts = [[trimmed stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]] componentsSeparatedByString:@" "];
            if (parts.count < 2 || ![parts[1] hasPrefix:@"v"]) { current = nil; continue; }
            current = Item(parts[0], [parts[1] substringFromIndex:1], nil, @"cargo", nil, StatusUnknown);
            [items addObject:current];
        } else if (current && !current[@"path"]) {
            current[@"path"] = [binDirectory stringByAppendingPathComponent:trimmed];
        }
    }
    return items;
}

// `pipx list --json` → venvs.<name>.metadata.main_package.{package_version, apps}.
static NSArray<NSMutableDictionary *> *ParsePipxListJSON(NSString *output, NSString *binDirectory) {
    NSData *data = [output dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *venvs = [json isKindOfClass:[NSDictionary class]] ? json[@"venvs"] : nil;
    if (![venvs isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in [venvs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *venv = venvs[name];
        NSDictionary *package = [venv isKindOfClass:[NSDictionary class]] ? venv[@"metadata"][@"main_package"] : nil;
        if (![package isKindOfClass:[NSDictionary class]]) package = @{};
        NSString *version = [package[@"package_version"] isKindOfClass:[NSString class]] ? package[@"package_version"] : nil;
        NSArray *apps = [package[@"apps"] isKindOfClass:[NSArray class]] ? package[@"apps"] : @[];
        NSString *app = [apps.firstObject isKindOfClass:[NSString class]] ? apps.firstObject : nil;
        [items addObject:Item(name, version, nil, @"pipx", app ? [binDirectory stringByAppendingPathComponent:app] : nil, StatusUnknown)];
    }
    return items;
}

// Drops directory-scan items whose file the PATH scan already reported (symlinks resolved).
static NSArray<NSMutableDictionary *> *WithoutPathDuplicates(NSArray<NSMutableDictionary *> *items) {
    NSMutableSet<NSString *> *onPath = [NSMutableSet set];
    for (NSDictionary *item in items) {
        if ([item[@"source"] isEqualToString:@"PATH"] && item[@"path"]) [onPath addObject:[item[@"path"] stringByResolvingSymlinksInPath]];
    }
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (NSMutableDictionary *item in items) {
        if ([DirectorySources() containsObject:item[@"source"] ?: @""] && item[@"path"] && [onPath containsObject:[item[@"path"] stringByResolvingSymlinksInPath]]) continue;
        [kept addObject:item];
    }
    return kept;
}

@interface InventoryService : NSObject
// Called on the main queue as each install source finishes: (label, items found).
@property (copy) void (^progressHandler)(NSString *label, NSUInteger count);
+ (NSArray<NSString *> *)scanLabels;
- (NSArray<NSMutableDictionary *> *)refresh;
@end

@implementation InventoryService

- (NSArray<NSMutableDictionary *> *)refresh {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *merged = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableDictionary *> *all = [NSMutableArray array];
    NSLock *allLock = [[NSLock alloc] init];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);

    void (^progress)(NSString *, NSUInteger) = self.progressHandler;
    void (^addScanner)(NSString *, NSArray<NSMutableDictionary *> *(^)(void)) = ^(NSString *label, NSArray<NSMutableDictionary *> *(^scanner)(void)) {
        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            NSArray<NSMutableDictionary *> *items = scanner() ?: @[];
            [allLock lock];
            [all addObjectsFromArray:items];
            [allLock unlock];
            if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(label, items.count); });
            dispatch_group_leave(group);
        });
    };

    NSArray<NSString *> *labels = [InventoryService scanLabels];
    addScanner(labels[0], ^NSArray<NSMutableDictionary *> *{ return [self pathBinaries]; });
    addScanner(labels[1], ^NSArray<NSMutableDictionary *> *{ return [self brewItemsWithCasks:NO]; });
    addScanner(labels[2], ^NSArray<NSMutableDictionary *> *{ return [self brewItemsWithCasks:YES]; });
    addScanner(labels[3], ^NSArray<NSMutableDictionary *> *{ return [self npmGlobals]; });
    addScanner(labels[4], ^NSArray<NSMutableDictionary *> *{ return [self bunGlobals]; });
    addScanner(labels[5], ^NSArray<NSMutableDictionary *> *{ return [self uvTools]; });
    addScanner(labels[6], ^NSArray<NSMutableDictionary *> *{ return [self pipxApps]; });
    addScanner(labels[7], ^NSArray<NSMutableDictionary *> *{ return [self cargoInstalls]; });
    addScanner(labels[8], ^NSArray<NSMutableDictionary *> *{ return [self goBinaries]; });
    addScanner(labels[9], ^NSArray<NSMutableDictionary *> *{ return [self localBinaries]; });
    addScanner(labels[10], ^NSArray<NSMutableDictionary *> *{ return [self appBundleBinaries]; });
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    for (NSMutableDictionary *item in WithoutPathDuplicates(all)) {
        NSString *key = InventoryKey(item);
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
        // Verbose output is "name (installed) < latest" for formulae and "name (installed) != latest" for casks.
        NSRange range = [line rangeOfString:@" < "];
        if (range.location == NSNotFound) range = [line rangeOfString:@" != "];
        if (range.location == NSNotFound) continue;
        NSString *left = [[line substringToIndex:range.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *latest = [[line substringFromIndex:NSMaxRange(range)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
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
        NSString *version = [parts[1] hasPrefix:@"v"] ? [parts[1] substringFromIndex:1] : parts[1];
        [items addObject:Item(parts[0], version, nil, @"uv tool", nil, StatusUnknown)];
    }
    return items;
}

+ (NSArray<NSString *> *)scanLabels {
    return @[@"PATH", @"Homebrew", @"casks", @"npm -g", @"bun", @"uv", @"pipx", @"cargo", @"go", @"~/.local/bin", @"/Applications"];
}

- (NSString *)userBinDirectory {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"];
}

- (NSArray<NSMutableDictionary *> *)pipxApps {
    NSString *pipx = CommandPath(@"pipx");
    if (!pipx) return @[];
    NSString *binDirectory = [RunCommand(@"/usr/bin/env", @[@"zsh", @"-lc", @"print -r -- ${PIPX_BIN_DIR:-$HOME/.local/bin}"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ParsePipxListJSON(RunCommand(pipx, @[@"list", @"--json"]), binDirectory.length > 0 ? binDirectory : [self userBinDirectory]);
}

- (NSArray<NSMutableDictionary *> *)cargoInstalls {
    NSString *cargo = CommandPath(@"cargo");
    NSString *binDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@".cargo/bin"];
    if (!cargo && [[NSFileManager defaultManager] isExecutableFileAtPath:[binDirectory stringByAppendingPathComponent:@"cargo"]]) {
        cargo = [binDirectory stringByAppendingPathComponent:@"cargo"];
    }
    if (!cargo) return @[];
    return ParseCargoInstallList(RunCommand(cargo, @[@"install", @"--list"]), binDirectory);
}

- (NSArray<NSMutableDictionary *> *)goBinaries {
    NSString *go = CommandPath(@"go");
    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];
    if (go) {
        NSString *output = RunCommand(go, @[@"env", @"GOBIN", @"GOPATH"]);
        NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSString *gobin = lines.count > 0 ? [lines[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        NSString *gopath = lines.count > 1 ? [[lines[1] componentsSeparatedByString:@":"].firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (gobin.length > 0) [directories addObject:gobin];
        if (gopath.length > 0) [directories addObject:[gopath stringByAppendingPathComponent:@"bin"]];
    }
    [directories addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"go/bin"]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *directory in directories) {
        for (NSString *path in ExecutablesInDirectory(directory)) [items addObject:Item(path.lastPathComponent, nil, nil, @"go", path, StatusUnknown)];
    }
    return items;
}

// Listed directly so tools there show up even when ~/.local/bin is not on the login PATH.
- (NSArray<NSMutableDictionary *> *)localBinaries {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *path in ExecutablesInDirectory([self userBinDirectory])) [items addObject:Item(path.lastPathComponent, nil, nil, SourceLocalBin, path, StatusUnknown)];
    return items;
}

- (NSArray<NSMutableDictionary *> *)appBundleBinaries {
    NSArray *roots = @[@"/Applications", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *directory in AppBundleBinDirectories(roots)) {
        for (NSString *path in ExecutablesInDirectory(directory)) [items addObject:Item(path.lastPathComponent, nil, nil, SourceAppBundle, path, StatusUnknown)];
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
@property TickerPanelController *panel;
@property CLIRegistryService *registry;
@property NSMenu *classicMenu;
// YES from a first launch (no saved inventory) until the first scan and version check finish.
@property BOOL firstRunScanning;
@property BOOL completedFirstScan;
@property NSMutableDictionary<NSString *, NSNumber *> *scanProgress;
- (NSArray<NSDictionary *> *)panelAgentRows;
- (NSArray<NSDictionary *> *)panelOtherCLIRows;
- (NSArray<NSDictionary *> *)panelSourceCounts;
- (void)updateFirstRunState;
- (void)scheduleWatcherRefresh;
- (void)setUpPanel;
- (void)reloadPanel;
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
    self.firstRunScanning = ![[NSFileManager defaultManager] fileExistsAtPath:self.reportURL.path];
    self.scanProgress = [NSMutableDictionary dictionary];
    __weak typeof(self) weakSelf = self;
    self.service.progressHandler = ^(NSString *label, NSUInteger count) {
        weakSelf.scanProgress[label] = @(count);
        [weakSelf reloadPanel];
    };
    [self loadReport];
    [self loadRecentChanges];
    [self setUpPanel];
    [self rebuildMenu];
    [self refresh:nil];
    [self startInstallWatcher];
    if (self.firstRunScanning && ![self launchedForAutomation]) {
        // The installer opens the app; show the scan so a new user sees it start.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf.statusItem.button.window) [weakSelf.panel showRelativeToStatusButton:weakSelf.statusItem.button];
        });
    }

    [NSTimer scheduledTimerWithTimeInterval:15 * 60 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(checkForUpdateRefreshRequest:) userInfo:nil repeats:YES];
    return self;
}

- (void)dealloc {
    [self stopInstallWatcher];
}

- (BOOL)launchedForAutomation {
    for (NSString *argument in [[NSProcessInfo processInfo] arguments]) {
        if ([argument hasPrefix:@"--"]) return YES;
    }
    return NO;
}

- (void)updateFirstRunState {
    if (self.firstRunScanning && self.completedFirstScan && !self.refreshing && !self.registry.isChecking) self.firstRunScanning = NO;
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
    NSArray<NSString *> *candidates = [CommonBinDirectories() arrayByAddingObjectsFromArray:@[
        @"/opt/homebrew/Cellar",
        @"/opt/homebrew/Caskroom",
        @"/usr/local/Cellar",
        @"/usr/local/Caskroom"
    ]];

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

// Builds a scrollable single-selection table backed by this controller's data source.
// `columns` holds @[identifier, title, width] triples.
- (NSScrollView *)resultsScrollViewWithSize:(NSSize)size rowHeight:(CGFloat)rowHeight doubleAction:(SEL)doubleAction columns:(NSArray<NSArray *> *)columns {
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.borderType = NSBezelBorder;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:scrollView.contentView.bounds];
    tableView.usesAlternatingRowBackgroundColors = YES;
    tableView.allowsMultipleSelection = NO;
    tableView.rowHeight = rowHeight;
    tableView.target = self;
    tableView.doubleAction = doubleAction;
    tableView.dataSource = (id<NSTableViewDataSource>)self;
    tableView.delegate = (id<NSTableViewDelegate>)self;
    for (NSArray *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = column.width;
        [tableView addTableColumn:column];
    }
    scrollView.documentView = tableView;
    return scrollView;
}

- (void)runUpdateForItem:(NSDictionary *)item confirm:(BOOL)confirm {
    NSString *command = [self updateCommandForItem:item];
    if (command.length == 0) {
        ShowInfoAlert(@"Update Not Supported",
                      @"CLI can apply Homebrew and global npm updates from the menu. Use the package manager directly for this source.",
                      @"OK");
        return;
    }

    if (confirm) {
        NSAlert *confirmAlert = [[NSAlert alloc] init];
        confirmAlert.messageText = [NSString stringWithFormat:@"Update %@?", item[@"name"] ?: @"this CLI"];
        confirmAlert.informativeText = [NSString stringWithFormat:@"CLI will open %@ and run:\n\n%@", self.preferredTerminal, command];
        [confirmAlert addButtonWithTitle:@"Update"];
        [confirmAlert addButtonWithTitle:@"Cancel"];
        if ([confirmAlert runModal] != NSAlertFirstButtonReturn) return;
    }

    NSString *terminalCommand = [self updateTerminalCommandForItem:item];
    [self runInPreferredTerminal:terminalCommand];
}

- (void)reloadAllUpdatesDialog {
    if (!self.allUpdatesTableView) return;

    NSArray<NSDictionary *> *updates = [self notableUpdateItems:NSUIntegerMax];
    self.allUpdateItems = updates;
    [self.allUpdatesTableView reloadData];
    self.allUpdatesAlert.messageText = [NSString stringWithFormat:@"All Updates Available (%lu)", updates.count];
    self.allUpdatesAlert.informativeText = updates.count > 0
        ? [NSString stringWithFormat:@"Double-click an update to run it in %@.", self.preferredTerminal]
        : @"All visible updates are current.";
}

- (NSString *)updateCommandForItem:(NSDictionary *)item {
    NSString *displayName = [self displayNameForItem:item];
    return ShellCommandForUpdateAction(UpdateActionForItem(item, displayName));
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

// Outdated items that have an in-app update action. Several items can share
// one command, so this can exceed allUpdateCommands.count.
- (NSUInteger)supportedUpdateItemCount {
    NSUInteger count = 0;
    for (NSDictionary *item in [self notableUpdateItems:NSUIntegerMax]) {
        if ([self updateCommandForItem:item].length > 0) count++;
    }
    return count;
}

- (void)updateAll:(id)sender {
    NSArray<NSString *> *commands = [self allUpdateCommands];
    if (commands.count == 0) {
        ShowInfoAlert(@"No Supported Updates",
                      @"None of the outdated tools support in-app updates. Use the package manager directly for these sources.",
                      @"OK");
        return;
    }

    NSUInteger supportedUpdates = [self supportedUpdateItemCount];
    NSAlert *confirmAlert = [[NSAlert alloc] init];
    confirmAlert.messageText = [NSString stringWithFormat:@"Update %lu Supported %@?", supportedUpdates, supportedUpdates == 1 ? @"Tool" : @"Tools"];
    confirmAlert.informativeText = [NSString stringWithFormat:@"CLI will open %@ and run:\n\n%@", self.preferredTerminal, [commands componentsJoinedByString:@"\n"]];
    [confirmAlert addButtonWithTitle:@"Update"];
    [confirmAlert addButtonWithTitle:@"Cancel"];
    if ([confirmAlert runModal] != NSAlertFirstButtonReturn) return;

    NSString *terminalCommand = [self updateAllTerminalCommandWithCommands:commands];
    [self runInPreferredTerminal:terminalCommand];
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
    [ordered addObjectsFromArray:[self unlistedAgentTools]];
    return ordered;
}

// Executables that look like agents but are not in the curated list; shown with a generic icon.
- (NSArray<NSDictionary *> *)unlistedAgentTools {
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *item in self.items) {
        NSString *path = item[@"path"];
        if (path.length == 0) continue;
        NSString *name = path.lastPathComponent;
        if ([AgentToolNames() containsObject:[self displayNameForItem:item]] || [AgentToolNames() containsObject:PackageAliases()[name] ?: name]) continue;
        if (!LooksLikeAgentName(name) || byName[name]) continue;
        NSMutableDictionary *generic = [item mutableCopy];
        generic[@"genericAgent"] = @YES;
        byName[name] = generic;
    }
    return [byName.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a[@"path"] lastPathComponent] localizedCaseInsensitiveCompare:[b[@"path"] lastPathComponent]];
    }];
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

    for (NSString *dir in CommonBinDirectories()) {
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
        if (ApplicationInstalled(terminal[@"apps"])) [terminals addObject:terminal[@"name"]];
    }
    return terminals;
}

- (void)runInPreferredTerminal:(NSString *)command {
    [self runShellCommand:command inTerminal:self.preferredTerminal];
}

- (void)runShellCommand:(NSString *)command inTerminal:(NSString *)terminal {
    if ([terminal isEqualToString:@"Ghostty"] && TerminalInstalled(terminal)) {
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

    if ([terminal isEqualToString:@"iTerm"] && TerminalInstalled(terminal)) {
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

    if ([terminal isEqualToString:@"Warp"] && TerminalInstalled(terminal)) {
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

    NSArray *notableUpdates = [self notableUpdateItems:14];
    if (notableUpdates.count > 0) {
        NSUInteger totalUpdates = [self countWithStatus:StatusOutdated];
        NSUInteger supportedUpdates = [self supportedUpdateItemCount];
        NSUInteger manualUpdates = totalUpdates > supportedUpdates ? totalUpdates - supportedUpdates : 0;
        NSMenuItem *updatesFolder = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Updates Available  %lu", totalUpdates] action:nil keyEquivalent:@""];
        updatesFolder.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle" accessibilityDescription:@"Notable Updates"];
        NSMenu *updatesMenu = [[NSMenu alloc] initWithTitle:@"Notable Updates"];
        NSMenuItem *updatesSummary = [[NSMenuItem alloc] initWithTitle:@"Newest versions found" action:nil keyEquivalent:@""];
        updatesSummary.enabled = NO;
        [updatesMenu addItem:updatesSummary];
        [updatesMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *updateAll = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Update %lu Supported %@…", supportedUpdates, supportedUpdates == 1 ? @"Tool" : @"Tools"] action:@selector(updateAll:) keyEquivalent:@"u"];
        updateAll.target = self;
        updateAll.enabled = supportedUpdates > 0;
        updateAll.image = [NSImage imageWithSystemSymbolName:@"arrow.down.circle.fill" accessibilityDescription:@"Update All"];
        [updatesMenu addItem:updateAll];
        [updatesMenu addItem:[NSMenuItem separatorItem]];
        for (NSDictionary *item in notableUpdates) {
            [updatesMenu addItem:[self notableUpdateMenuItemForItem:item]];
        }
        [updatesMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *showAll = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Show All %lu Updates…", totalUpdates] action:@selector(showAllUpdates:) keyEquivalent:@""];
        showAll.target = self;
        showAll.image = [NSImage imageWithSystemSymbolName:@"list.bullet.rectangle" accessibilityDescription:@"Show All Updates"];
        [updatesMenu addItem:showAll];
        NSString *noteText;
        if (manualUpdates > 0) {
            noteText = manualUpdates == 1
                ? @"1 tool needs a manual update"
                : [NSString stringWithFormat:@"%lu tools need a manual update", manualUpdates];
        } else if (totalUpdates > notableUpdates.count) {
            noteText = [NSString stringWithFormat:@"Showing %lu of %lu updates", notableUpdates.count, totalUpdates];
        } else {
            noteText = @"Click an update to apply it";
        }
        NSMenuItem *updatesNote = [[NSMenuItem alloc] initWithTitle:noteText action:nil keyEquivalent:@""];
        updatesNote.enabled = NO;
        [updatesMenu addItem:updatesNote];
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

    self.classicMenu = menu;
    [self reloadPanel];
}

- (void)refresh:(id)sender {
    if (self.refreshing) return;
    self.refreshing = YES;
    [self.scanProgress removeAllObjects];
    [self rebuildMenu];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *fresh = [self.service refresh];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recordChangesFromItems:self.items toItems:fresh];
            self.items = fresh;
            [self saveReport];
            self.refreshing = NO;
            self.completedFirstScan = YES;
            [self.registry refreshWithInventory:fresh force:NO];
            [self updateFirstRunState];
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
    [self runInPreferredTerminal:command];
}

- (void)openRecentChange:(NSMenuItem *)sender {
    NSDictionary *item = sender.representedObject;
    if (![item isKindOfClass:[NSDictionary class]]) return;
    NSString *command = [self launchCommandForCLIItem:item];
    [self runInPreferredTerminal:command];
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
    [self runInPreferredTerminal:command];
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
    prompt.informativeText = @"Search installed command names and sources.";
    [prompt addButtonWithTitle:@"Search"];
    [prompt addButtonWithTitle:@"Cancel"];

    NSSearchField *field = [[NSSearchField alloc] initWithFrame:NSMakeRect(0, 0, 360, 26)];
    field.placeholderString = @"codex, npm, homebrew...";
    prompt.accessoryView = field;

    NSModalResponse response = [prompt runModal];
    if (response != NSAlertFirstButtonReturn) return;

    NSString *query = field.stringValue ?: @"";
    NSArray<NSDictionary *> *matches = [self searchItemsMatching:query limit:24];
    if (matches.count == 0) {
        ShowInfoAlert([NSString stringWithFormat:@"No CLIs Found for \"%@\"", query],
                      @"Try searching by command name or package manager.",
                      @"Done");
        return;
    }

    self.searchResultItems = matches;

    NSScrollView *scrollView = [self resultsScrollViewWithSize:NSMakeSize(540, 190)
                                                     rowHeight:22
                                                  doubleAction:@selector(openSelectedSearchResult:)
                                                       columns:@[
        @[@"tool", @"Tool", @130],
        @[@"version", @"Version", @78],
        @[@"source", @"Source", @100],
        @[@"command", @"Command", @220]
    ]];
    NSTableView *tableView = scrollView.documentView;
    self.searchResultsTableView = tableView;
    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];

    NSAlert *results = [[NSAlert alloc] init];
    results.messageText = [NSString stringWithFormat:@"Search Results for \"%@\"", query];
    results.informativeText = [NSString stringWithFormat:@"Double-click a CLI to open it in %@, or copy its bash launch script.", self.preferredTerminal];
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

    NSScrollView *scrollView = [self resultsScrollViewWithSize:NSMakeSize(760, 320)
                                                     rowHeight:24
                                                  doubleAction:@selector(updateSelectedFromAllUpdates:)
                                                       columns:@[
        @[@"tool", @"Tool", @150],
        @[@"current", @"Current", @95],
        @[@"latest", @"Latest", @95],
        @[@"source", @"Source", @120],
        @[@"command", @"Command", @285]
    ]];
    self.allUpdatesTableView = scrollView.documentView;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"All Updates Available (%lu)", updates.count];
    alert.informativeText = [NSString stringWithFormat:@"Double-click an update to run it in %@.", self.preferredTerminal];
    alert.accessoryView = scrollView;
    self.allUpdatesAlert = alert;
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Update Supported…"];
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

#pragma mark - Menu bar panel

// Left click opens the panel; right click (or control-click) shows the classic menu.
- (void)setUpPanel {
    self.panel = [[TickerPanelController alloc] init];
    self.panel.delegate = (id<TickerPanelDelegate>)self;
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];

    NSString *registryPath = [[NSBundle mainBundle] pathForResource:@"registry" ofType:@"json" inDirectory:@"CLIRegistry"];
    NSString *iconDirectory = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"CLIRegistry/icons"];
    NSURL *cacheDirectory = self.reportURL.URLByDeletingLastPathComponent;
    self.registry = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:registryPath ?: @""] iconDirectory:iconDirectory cacheDirectory:cacheDirectory];
    self.registry.commandRunner = ^NSString *(NSString *launchPath, NSArray<NSString *> *arguments) {
        return RunCommand(launchPath, arguments);
    };
    __weak typeof(self) weakSelf = self;
    self.registry.inventoryUpdateAction = ^NSDictionary *(NSDictionary *item) {
        return UpdateActionForItem(item, [weakSelf displayNameForItem:item]);
    };
    self.registry.shellCommandForAction = ^NSString *(NSDictionary *action) {
        return ShellCommandForUpdateAction(action);
    };
    self.registry.changeHandler = ^{
        [weakSelf updateFirstRunState];
        [weakSelf reloadPanel];
    };
    self.registry.updateFinishedHandler = ^(NSDictionary *status, BOOL succeeded) {
        if (succeeded) [weakSelf refresh:nil];
    };
    [self.registry refreshWithInventory:self.items force:NO];
}

- (void)statusItemClicked:(NSStatusBarButton *)sender {
    NSEvent *event = NSApp.currentEvent;
    BOOL secondary = event.type == NSEventTypeRightMouseUp || (event.modifierFlags & NSEventModifierFlagControl);
    if (secondary) {
        [self showClassicMenu];
        return;
    }
    [self.panel toggleRelativeToStatusButton:sender];
}

- (void)showClassicMenu {
    [self.panel close];
    self.statusItem.menu = self.classicMenu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)reloadPanel {
    if (self.panel.isVisible) [self.panel reload];
}

- (NSString *)shortSourceName:(NSString *)source {
    NSDictionary *names = @{@"Homebrew": @"brew", @"Homebrew Cask": @"cask", @"npm global": @"npm", @"Bun global": @"bun", @"uv tool": @"uv", @"PATH": @"path",
                            SourceLocalBin: @"local", SourceAppBundle: @"app"};
    return names[source] ?: source.lowercaseString ?: @"";
}

- (NSDictionary *)panelRowForItem:(NSDictionary *)item kind:(NSString *)kind {
    NSString *status = item[@"status"];
    return @{
        @"kind": kind,
        @"item": item,
        @"title": [self titleNameForItem:item] ?: @"",
        @"detail": [self versionSummaryForItem:item] ?: @"",
        @"via": [self shortSourceName:item[@"source"] ?: @""],
        @"meta": [status isEqualToString:StatusOutdated] ? @"update ›" : ([status isEqualToString:StatusCurrent] ? @"current" : @"—"),
        @"emphasis": @([status isEqualToString:StatusOutdated]),
        @"icon": [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:nil],
        @"tooltip": item[@"path"] ?: item[@"source"] ?: @""
    };
}

- (NSArray<NSDictionary *> *)panelAgentRows {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *item in [self agentTools]) {
        NSMutableDictionary *row = [[self panelRowForItem:item kind:@"agent"] mutableCopy];
        if ([item[@"genericAgent"] boolValue]) {
            row[@"title"] = [item[@"path"] lastPathComponent];
            row[@"icon"] = TickerMonogramIcon([item[@"path"] lastPathComponent]);
        } else {
            row[@"title"] = [self friendlyAgentName:[self displayNameForItem:item]];
            row[@"icon"] = AgentIcon([self displayNameForItem:item]);
        }
        row[@"meta"] = [item[@"status"] isEqualToString:StatusOutdated] ? @"outdated" : @"open ›";
        [rows addObject:row];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)panelUpdateRows {
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger supported = [self allUpdateCommands].count;
    if (supported > 0) {
        [rows addObject:@{
            @"kind": @"updateAll",
            @"title": @"Update all",
            @"detail": [NSString stringWithFormat:@"%lu %@", supported, supported == 1 ? @"command" : @"commands"],
            @"meta": @"run ›",
            @"emphasis": @YES,
            @"icon": [NSImage imageWithSystemSymbolName:@"arrow.down.to.line" accessibilityDescription:nil]
        }];
    }
    for (NSDictionary *item in [self notableUpdateItems:NSUIntegerMax]) {
        NSMutableDictionary *row = [[self panelRowForItem:item kind:@"update"] mutableCopy];
        row[@"icon"] = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:nil];
        if ([self updateCommandForItem:item].length == 0) row[@"meta"] = @"manual";
        [rows addObject:row];
    }
    return rows;
}

- (NSArray<NSDictionary *> *)panelRecentRows {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *change in [self prunedChanges:self.recentChanges]) {
        NSDictionary *item = [self inventoryItemForChange:change];
        NSString *previous = change[@"previousVersion"];
        NSString *current = change[@"currentVersion"] ?: @"installed";
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"kind"] = @"recent";
        if (item) row[@"item"] = item;
        row[@"title"] = [self titleNameForItem:@{@"name": change[@"name"] ?: @""}] ?: @"";
        row[@"detail"] = previous.length > 0 ? [NSString stringWithFormat:@"%@ → %@", previous, current] : current;
        row[@"via"] = [self shortSourceName:change[@"source"] ?: @""];
        row[@"meta"] = [self relativeTimeForTimestamp:[change[@"date"] doubleValue]];
        row[@"icon"] = [NSImage imageWithSystemSymbolName:@"clock.arrow.circlepath" accessibilityDescription:nil];
        [rows addObject:row];
    }
    return rows;
}

// Installed CLIs the registry does not know, shown after the registry rows with a generic icon.
// Homebrew formulae count only when they put a same-named binary on PATH (skips libraries).
- (NSArray<NSDictionary *> *)panelOtherCLIRows {
    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (NSDictionary *entry in self.registry.entries) {
        for (NSString *key in @[@"id", @"bins", @"npm", @"brew", @"cask"]) {
            id value = entry[key];
            if ([value isKindOfClass:[NSString class]]) [known addObject:[value lastPathComponent]];
            if ([value isKindOfClass:[NSArray class]]) for (NSString *name in value) [known addObject:name.lastPathComponent];
        }
    }
    NSMutableSet<NSString *> *pathNames = [NSMutableSet set];
    for (NSDictionary *item in self.items) {
        if ([item[@"source"] isEqualToString:@"PATH"]) [pathNames addObject:item[@"name"] ?: @""];
    }
    NSSet *toolSources = [NSSet setWithArray:@[@"npm global", @"Bun global", @"uv tool", @"pipx", @"cargo", @"go", SourceLocalBin, SourceAppBundle]];
    NSMutableDictionary<NSString *, NSDictionary *> *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *item in self.items) {
        NSString *source = item[@"source"] ?: @"";
        NSString *name = item[@"name"] ?: @"";
        BOOL brewTool = [source isEqualToString:@"Homebrew"] && [pathNames containsObject:name];
        if (name.length == 0 || (!brewTool && ![toolSources containsObject:source])) continue;
        NSString *binary = [item[@"path"] lastPathComponent];
        if ([known containsObject:name] || [known containsObject:name.lastPathComponent] || (binary && [known containsObject:binary])) continue;
        NSString *key = (binary ?: name).lowercaseString;
        if (byName[key]) continue;
        NSMutableDictionary *row = [[self panelRowForItem:item kind:@"cli"] mutableCopy];
        row[@"icon"] = TickerMonogramIcon(binary ?: name.lastPathComponent);
        row[@"meta"] = [item[@"status"] isEqualToString:StatusOutdated] ? @"update ›" : @"detected";
        byName[key] = row;
    }
    return [byName.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
    }];
}

// First-launch progress: one step per install source, then the registry version check.
- (NSDictionary *)panelScanningState {
    if (!self.firstRunScanning) return nil;
    NSMutableArray *steps = [NSMutableArray array];
    for (NSString *label in [InventoryService scanLabels]) {
        NSNumber *count = self.scanProgress[label];
        [steps addObject:count ? @{@"label": label, @"done": @YES, @"count": count} : @{@"label": label, @"done": @NO}];
    }
    BOOL versionsDone = self.completedFirstScan && !self.registry.isChecking;
    [steps addObject:@{@"label": @"versions", @"done": @(versionsDone)}];
    return @{
        @"title": @"Scanning your machine…",
        @"detail": @"Looking for installed CLIs and AI agents. Only what you have will be listed. Nothing leaves this Mac.",
        @"steps": steps
    };
}

- (NSArray<NSDictionary *> *)panelAllRows {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:self.items.count];
    for (NSDictionary *item in self.items) [rows addObject:[self panelRowForItem:item kind:@"cli"]];
    return rows;
}

- (NSArray<NSDictionary *> *)panelSourceCounts {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSDictionary *item in self.items) {
        NSString *source = [self shortSourceName:item[@"source"] ?: @""];
        counts[source] = @(counts[source].integerValue + 1);
    }
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *source in counts) [entries addObject:@{@"label": source, @"count": counts[source]}];
    return [entries sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"count" ascending:NO]]];
}

- (NSString *)panelStatusLine {
    NSString *active = [self.registry activeUpdateSummary];
    if (active.length > 0) return active;
    if (self.firstRunScanning) return @"first launch · scanning your machine…";
    if (self.refreshing) return @"rescanning in background…";
    if (self.registry.isChecking) return @"checking versions…";
    NSDate *scanned = [[NSFileManager defaultManager] attributesOfItemAtPath:self.reportURL.path error:nil].fileModificationDate;
    NSString *when = scanned ? [self relativeTimeForTimestamp:scanned.timeIntervalSince1970] : @"never";
    return [NSString stringWithFormat:@"%lu outdated · scanned %@", [self countWithStatus:StatusOutdated], when];
}

- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel {
    NSDictionary *scanning = [self panelScanningState];
    NSArray *registryRows = self.registry.statuses;
    NSUInteger registryOutdated = 0;
    for (NSDictionary *row in registryRows) if ([row[@"state"] isEqualToString:@"outdated"]) registryOutdated++;
    NSArray *cliRows = scanning ? @[] : [registryRows arrayByAddingObjectsFromArray:[self panelOtherCLIRows]];
    NSArray *views = @[
        @{@"id": @"clis", @"label": @"CLIs", @"symbol": @"square.stack.3d.up", @"rows": cliRows, @"columns": @[@"Name ·", @"Version", @"Via", @"Status"]},
        @{@"id": @"agents", @"label": @"Agents", @"symbol": @"sparkles", @"rows": [self panelAgentRows], @"columns": @[@"Name ·", @"Version", @"Via", @"Action"]},
        @{@"id": @"updates", @"label": @"Updates", @"symbol": @"arrow.down.circle", @"rows": [self panelUpdateRows], @"count": @([self countWithStatus:StatusOutdated]), @"columns": @[@"Name ·", @"Version", @"Via", @"Action"]},
        @{@"id": @"recent", @"label": @"Recent", @"symbol": @"clock", @"rows": [self panelRecentRows], @"columns": @[@"Name ·", @"Change", @"Via", @"When"]},
        @{@"id": @"all", @"label": @"All", @"symbol": @"list.bullet", @"rows": [self panelAllRows], @"columns": @[@"Name ·", @"Version", @"Via", @"Status"]}
    ];
    NSUInteger outdated = [self countWithStatus:StatusOutdated];
    NSUInteger unknown = [self countWithStatus:StatusUnknown];
    NSMutableDictionary *snapshot = [@{
        @"views": views,
        @"terminals": [self availableTerminals],
        @"preferredTerminal": self.preferredTerminal ?: @"",
        @"sources": [self panelSourceCounts],
        @"stats": @{@"current": @(self.items.count - outdated - unknown), @"outdated": @(outdated), @"unknown": @(unknown), @"registryOutdated": @(registryOutdated)},
        @"status": [self panelStatusLine]
    } mutableCopy];
    if (scanning) snapshot[@"scanning"] = scanning;
    return snapshot;
}

- (NSArray<NSDictionary *> *)tickerPanel:(TickerPanelController *)panel rowsMatching:(NSString *)query {
    NSMutableArray *rows = [NSMutableArray array];
    NSString *needle = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    for (NSDictionary *status in self.registry.statuses) {
        if ([[status[@"title"] lowercaseString] containsString:needle] || [[status[@"id"] lowercaseString] containsString:needle]) [rows addObject:status];
    }
    for (NSDictionary *item in [self searchItemsMatching:query limit:50]) {
        NSMutableDictionary *row = [[self panelRowForItem:item kind:@"cli"] mutableCopy];
        row[@"meta"] = item[@"source"] ?: @"";
        [rows addObject:row];
    }
    return rows;
}

- (void)tickerPanel:(TickerPanelController *)panel activateRow:(NSDictionary *)row {
    NSString *kind = row[@"kind"];
    NSDictionary *item = row[@"item"];
    if ([kind isEqualToString:@"registry"]) return;
    [panel close];
    if ([kind isEqualToString:@"updateAll"]) {
        [NSApp activateIgnoringOtherApps:YES];
        [self updateAll:nil];
    } else if ([kind isEqualToString:@"update"] && item) {
        [NSApp activateIgnoringOtherApps:YES];
        [self runUpdateForItem:item confirm:YES];
    } else if ([kind isEqualToString:@"agent"] && item) {
        [self runInPreferredTerminal:[self launchCommandForAgentItem:item]];
    } else if (item) {
        [self runInPreferredTerminal:[self launchCommandForCLIItem:item]];
    }
}

- (void)tickerPanel:(TickerPanelController *)panel pressButtonOnRow:(NSDictionary *)row {
    // The row button is the only path that starts a registry update.
    if ([row[@"kind"] isEqualToString:@"registry"]) [self.registry runUpdateForStatus:row];
}

- (void)tickerPanel:(TickerPanelController *)panel copyRow:(NSDictionary *)row {
    NSString *text = [row[@"kind"] isEqualToString:@"registry"]
        ? (row[@"updateCommand"] ?: row[@"path"])
        : (row[@"item"] ? [self invocationForCLIItem:row[@"item"]] : nil);
    if (text.length == 0) return;
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString];
}

- (void)tickerPanel:(TickerPanelController *)panel performCommand:(NSString *)command {
    if ([command isEqualToString:TickerCommandRefresh]) {
        [self refresh:nil];
        [self.registry refreshWithInventory:self.items force:YES];
        return;
    }
    [panel close];
    if ([command isEqualToString:TickerCommandUpdateAll]) {
        [NSApp activateIgnoringOtherApps:YES];
        [self updateAll:nil];
    } else if ([command isEqualToString:TickerCommandJSONReport]) {
        [self openJSONReport:nil];
    } else if ([command isEqualToString:TickerCommandMarkdownReport]) {
        [self openMarkdownReport:nil];
    } else if ([command isEqualToString:TickerCommandClassicMenu]) {
        [self showClassicMenu];
    } else if ([command isEqualToString:TickerCommandQuit]) {
        [self quit:nil];
    }
}

- (void)tickerPanel:(TickerPanelController *)panel selectTerminal:(NSString *)terminal {
    if (terminal.length == 0) return;
    self.preferredTerminal = terminal;
    [[NSUserDefaults standardUserDefaults] setObject:terminal forKey:@"PreferredTerminal"];
    [self rebuildMenu];
}

@end

// The dump waits for an inventory scan or registry check to start and then finish; being idle
// before any work has been observed does not count, or it would record pre-refresh versions.
static BOOL RegistryDumpSettled(BOOL *sawActivity, BOOL refreshing, BOOL checking) {
    if (refreshing || checking) *sawActivity = YES;
    return *sawActivity && !refreshing && !checking;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property MenuController *menuController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (RenderPanelPreviewsIfRequested()) return;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.menuController = [[MenuController alloc] init];
    [self startRegistryDumpIfRequested];
}

// `--dump-registry <dir>` waits for the first real scan and version checks, then writes
// registry-status.json and a live render of the CLIs view, and exits. With
// `--exercise-update <id>` it then presses that row's update button, records the streamed
// progress and result, waits for the re-check, and dumps again. It exits non-zero when the
// requested update could not be attempted or failed. Used by CI.
- (void)startRegistryDumpIfRequested {
    NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
    NSUInteger flag = [arguments indexOfObject:@"--dump-registry"];
    if (flag == NSNotFound || flag + 1 >= arguments.count) return;
    NSString *directory = arguments[flag + 1];
    NSUInteger updateFlag = [arguments indexOfObject:@"--exercise-update"];
    NSString *updateId = updateFlag != NSNotFound && updateFlag + 1 < arguments.count ? arguments[updateFlag + 1] : nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    MenuController *controller = self.menuController;
    NSDate *started = [NSDate date];
    // What the panel had before any scan finished: a first launch, or rows restored from the cache.
    NSDictionary *startup = @{@"firstLaunch": @(controller.firstRunScanning), @"cachedRegistryRows": @(controller.registry.statuses.count), @"cachedInventoryItems": @(controller.items.count)};
    [[NSJSONSerialization dataWithJSONObject:startup options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil] writeToFile:[directory stringByAppendingPathComponent:@"startup.json"] atomically:YES];
    NSMutableArray<NSString *> *progress = [NSMutableArray array];
    __block NSInteger phase = 0;
    __block BOOL sawRefresh = NO;
    __block NSDictionary *before = nil;

    NSDictionary *(^statusWithId)(NSString *) = ^NSDictionary *(NSString *entryId) {
        for (NSDictionary *status in controller.registry.statuses) {
            if ([status[@"id"] isEqualToString:entryId]) return status;
        }
        return nil;
    };
    void (^dump)(NSString *) = ^(NSString *suffix) {
        [controller updateFirstRunState];
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *status in controller.registry.statuses) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"id", @"title", @"path", @"version", @"latest", @"via", @"state", @"updateCommand", @"updateState"]) {
                if (status[key]) row[key] = status[key];
            }
            [rows addObject:row];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        [json writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"registry-status%@.json", suffix]] atomically:YES];
        NSMutableArray *agents = [NSMutableArray array];
        for (NSDictionary *row in [controller panelAgentRows]) [agents addObject:@{@"title": row[@"title"] ?: @"", @"via": row[@"via"] ?: @"", @"generic": @([row[@"item"][@"genericAgent"] boolValue])}];
        NSMutableArray *others = [NSMutableArray array];
        for (NSDictionary *row in [controller panelOtherCLIRows]) [others addObject:@{@"title": row[@"title"] ?: @"", @"via": row[@"via"] ?: @""}];
        NSDictionary *summary = @{@"firstRunScanning": @(controller.firstRunScanning), @"agents": agents, @"otherCLIs": others, @"sources": [controller panelSourceCounts]};
        [[NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]
            writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"scan-summary%@.json", suffix]] atomically:YES];
        controller.panel.selectedViewId = @"clis";
        WritePanelPreviewPNG([controller.panel renderContentBitmap], [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"cli-list-live%@.png", suffix]], NO);
        fprintf(stderr, "registry dump%s: %lu CLIs\n", suffix.UTF8String, (unsigned long)rows.count);
    };
    void (^finish)(int) = ^(int code) {
        if (updateId) {
            NSDictionary *after = statusWithId(updateId);
            NSDictionary *report = @{@"id": updateId, @"attempted": before ? @YES : @NO, @"before": before ?: @{}, @"afterVersion": after[@"version"] ?: @"", @"afterState": after[@"state"] ?: @"",
                                     @"updateState": after[@"updateState"] ?: @"", @"progress": progress};
            NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
            [json writeToFile:[directory stringByAppendingPathComponent:@"update-exercise.json"] atomically:YES];
        }
        exit(code);
    };

    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (-[started timeIntervalSinceNow] > 600) {
            [timer invalidate];
            fprintf(stderr, "registry dump timed out in phase %ld\n", (long)phase);
            finish(1);
            return;
        }
        BOOL settled = RegistryDumpSettled(&sawRefresh, controller.refreshing, controller.registry.isChecking);

        if (phase == 0) {
            if (!settled) return;
            dump(@"");
            NSDictionary *target = updateId ? statusWithId(updateId) : nil;
            if (!target || [target[@"updateCommand"] length] == 0) {
                [timer invalidate];
                if (updateId) fprintf(stderr, "exercise-update: %s not installed or has no update command\n", updateId.UTF8String);
                finish(updateId ? 1 : 0);
                return;
            }
            before = @{@"version": target[@"version"] ?: @"", @"state": target[@"state"] ?: @"", @"command": target[@"updateCommand"]};
            [controller tickerPanel:controller.panel pressButtonOnRow:target];
            phase = 1;
            return;
        }

        NSString *line = [controller.registry activeUpdateSummary];
        if (line.length > 0 && ![progress.lastObject isEqualToString:line]) [progress addObject:line];
        NSString *updateState = statusWithId(updateId)[@"updateState"];
        if (phase == 1) {
            if (![updateState isEqualToString:CLIUpdateStateSucceeded] && ![updateState isEqualToString:CLIUpdateStateFailed]) return;
            sawRefresh = controller.refreshing || controller.registry.isChecking;
            phase = 2;
            return;
        }
        if (!settled) return;
        [timer invalidate];
        dump(@"-after-update");
        finish([statusWithId(updateId)[@"updateState"] isEqualToString:CLIUpdateStateFailed] ? 1 : 0);
    }];
}
@end

#ifndef CLITICKER_TESTING
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
#endif
