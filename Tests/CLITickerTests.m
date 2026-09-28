#define CLITICKER_TESTING 1
#import "../Sources/CLITickerObjC/main.m"

static void Assert(BOOL condition, NSString *message) {
    if (condition) return;
    NSLog(@"FAIL: %@", message);
    exit(1);
}

static void TestCommandCapturesBothStreams(void) {
    NSString *program = @"print STDOUT 'o' x 200000; print STDERR 'e' x 200000;";
    CommandResult *result = RunCommandWithTimeout(@"/usr/bin/perl", @[@"-e", program], 10);
    Assert(!result.timedOut, @"large simultaneous output should not deadlock");
    Assert(result.terminationStatus == 0, @"large-output command should succeed");
    Assert(result.standardOutput.length == 200000, @"stdout should be captured completely");
    Assert(result.standardError.length == 200000, @"stderr should be captured completely");
}

static void TestCommandReportsFailure(void) {
    CommandResult *result = RunCommandWithTimeout(@"/bin/sh", @[@"-c", @"printf problem >&2; exit 7"], 5);
    Assert(!result.timedOut, @"failing command should terminate normally");
    Assert(result.terminationStatus == 7, @"exit status should be preserved");
    Assert([result.standardError isEqualToString:@"problem"], @"stderr should be preserved");
}

static void TestCommandTimeout(void) {
    NSDate *started = [NSDate date];
    CommandResult *result = RunCommandWithTimeout(@"/bin/sh", @[@"-c", @"sleep 5"], 0.1);
    Assert(result.timedOut, @"sleeping command should time out");
    Assert(-[started timeIntervalSinceNow] < 3, @"timeout should return promptly");
}

static BOOL ProcessExists(pid_t pid) {
    return kill(pid, 0) == 0 || errno == EPERM;
}

static BOOL WaitForProcessExit(pid_t pid, NSTimeInterval limit) {
    NSDate *giveUp = [NSDate dateWithTimeIntervalSinceNow:limit];
    while (ProcessExists(pid) && giveUp.timeIntervalSinceNow > 0) usleep(20000);
    return !ProcessExists(pid);
}

static void TestCommandTimeoutKillsDescendants(void) {
    NSDate *started = [NSDate date];
    CommandResult *result = RunCommandWithTimeout(@"/bin/sh", @[@"-c", @"sleep 30 & echo $!; wait"], 0.5);
    Assert(result.timedOut, @"command waiting on a background child should time out");
    Assert(-[started timeIntervalSinceNow] < 4, @"timeout should return promptly despite a background child");
    pid_t child = (pid_t)result.standardOutput.intValue;
    Assert(child > 0, @"background child pid should be captured before the timeout");
    BOOL gone = WaitForProcessExit(child, 2);
    if (!gone) kill(child, SIGKILL);
    Assert(gone, @"timeout should kill the command's whole process group");
}

static void TestCommandReturnsWhenBackgroundChildHoldsOutput(void) {
    NSDate *started = [NSDate date];
    CommandResult *result = RunCommandWithTimeout(@"/bin/sh", @[@"-c", @"sleep 30 & echo $!"], 10);
    pid_t child = (pid_t)result.standardOutput.intValue;
    if (child > 0) kill(child, SIGKILL);
    Assert(!result.timedOut, @"exited command should not time out");
    Assert(result.terminationStatus == 0, @"exited command should report its status");
    Assert(child > 0, @"output written before exit should be captured");
    Assert(-[started timeIntervalSinceNow] < 4, @"an inherited pipe must not block return after the command exits");
}

static void TestCommandReportsLaunchError(void) {
    CommandResult *result = RunCommandWithTimeout(@"/nonexistent/cli-ticker-test", @[], 5);
    Assert(result.launchError.length > 0, @"missing executable should report a launch error");
    Assert(!result.timedOut, @"launch failure should not time out");
}

static void TestUpdateCommandsReadPlainly(void) {
    NSString *command = ShellCommandForUpdateAction(@{
        @"executable": @"brew",
        @"arguments": @[@"upgrade", @"--cask", @"node@20"]
    });
    Assert([command isEqualToString:@"brew upgrade --cask node@20"], @"plain words should not be quoted");
    Assert([ShellQuotedArgument(@"") isEqualToString:@"''"], @"empty arguments should stay one word");
    Assert([ShellQuotedArgument(@"=ls") isEqualToString:@"'=ls'"], @"zsh equals expansion should be quoted");
    Assert([ShellQuotedArgument(@"a b") isEqualToString:@"'a b'"], @"spaces should be quoted");
}

static void TestUpdateArgumentsAreShellSafe(void) {
    NSString *sentinel = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *name = [NSString stringWithFormat:@"tool name'; touch '%@'; #", sentinel];
    NSDictionary *item = @{@"name": name, @"source": @"npm global"};
    NSDictionary *action = UpdateActionForItem(item, name);
    Assert([action[@"executable"] isEqualToString:@"npm"], @"npm action should retain its executable");
    Assert([action[@"arguments"] lastObject] == name, @"package name should remain one argument");

    NSString *command = ShellCommandForUpdateAction(@{
        @"executable": @"/usr/bin/printf",
        @"arguments": @[@"%s", name]
    });
    CommandResult *result = RunCommandWithTimeout(@"/bin/sh", @[@"-c", command], 5);
    Assert(result.terminationStatus == 0, @"quoted command should execute");
    Assert([result.standardOutput isEqualToString:name], @"quoted package name should round-trip exactly");
    Assert(![[NSFileManager defaultManager] fileExistsAtPath:sentinel], @"package name must not execute shell syntax");
}

static void TestSelfUpdateRunsThroughDetectedBinary(void) {
    CLIRegistryService *registry = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:@"Assets/CLIRegistry/registry.json"]
                                                                     iconDirectory:@"Assets/CLIRegistry/icons"
                                                                    cacheDirectory:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
    NSDictionary *fly = nil;
    for (NSDictionary *entry in registry.entries) {
        if ([entry[@"id"] isEqualToString:@"flyctl"]) fly = entry;
    }
    Assert(fly != nil, @"registry should list Fly.io");
    NSDictionary *action = [CLIRegistryService selfUpdateActionForEntry:fly detectedPath:@"/opt/homebrew/bin/fly"];
    Assert([action[@"executable"] isEqualToString:@"/opt/homebrew/bin/fly"], @"fly-only installs should update through the detected fly binary");
    Assert([action[@"arguments"] isEqualToArray:fly[@"selfUpdate"][@"arguments"]], @"self-update arguments should be preserved");

    NSDictionary *external = @{@"bins": @[@"tool"], @"selfUpdate": @{@"executable": @"tool-updater", @"arguments": @[@"run"]}};
    Assert([[CLIRegistryService selfUpdateActionForEntry:external detectedPath:@"/usr/local/bin/tool"] isEqualToDictionary:external[@"selfUpdate"]], @"updaters other than the entry's binaries should be left alone");
    NSDictionary *script = @{@"bins": @[@"tool"], @"selfUpdate": @{@"script": @"curl example | sh"}};
    Assert([[CLIRegistryService selfUpdateActionForEntry:script detectedPath:@"/usr/local/bin/tool"] isEqualToDictionary:script[@"selfUpdate"]], @"script updates should be left alone");
}

static void TestRegistryDumpWaitsForRefreshBeforeSettling(void) {
    BOOL sawActivity = NO;
    Assert(!RegistryDumpSettled(&sawActivity, NO, NO), @"idle before any refresh starts must not count as settled");
    Assert(!RegistryDumpSettled(&sawActivity, YES, NO), @"an inventory refresh in progress is not settled");
    Assert(!RegistryDumpSettled(&sawActivity, NO, YES), @"a registry re-check in progress is not settled");
    Assert(RegistryDumpSettled(&sawActivity, NO, NO), @"idle after observed work is settled");
}

@interface RowButtonPanelSource : NSObject <TickerPanelDelegate>
@property NSArray<NSDictionary *> *rows;
@property NSDictionary *pressedRow;
@end

@implementation RowButtonPanelSource
- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel {
    return @{@"views": @[@{@"id": @"clis", @"label": @"CLIs", @"symbol": @"square.stack.3d.up", @"rows": self.rows, @"columns": @[@"Name ·", @"Version", @"Via", @"Status"]}]};
}
- (NSArray<NSDictionary *> *)tickerPanel:(TickerPanelController *)panel rowsMatching:(NSString *)query { return self.rows; }
- (void)tickerPanel:(TickerPanelController *)panel activateRow:(NSDictionary *)row {}
- (void)tickerPanel:(TickerPanelController *)panel pressButtonOnRow:(NSDictionary *)row { self.pressedRow = row; }
- (void)tickerPanel:(TickerPanelController *)panel copyRow:(NSDictionary *)row {}
- (void)tickerPanel:(TickerPanelController *)panel performCommand:(NSString *)command {}
- (void)tickerPanel:(TickerPanelController *)panel selectTerminal:(NSString *)terminal {}
@end

@interface TickerPanelController (Testing)
- (NSTableView *)tableView;
- (void)rowButtonPressed:(NSButton *)sender;
@end

static NSDictionary *OutdatedRegistryRow(NSString *entryId) {
    return @{@"kind": @"registry", @"id": entryId, @"title": entryId, @"detail": @"1.0 → 2.0", @"state": @"outdated",
             @"updateAction": @{@"executable": @"true", @"arguments": @[]}, @"updateCommand": entryId};
}

static void TestRowButtonResolvesRowFromItsView(void) {
    [NSApplication sharedApplication];
    RowButtonPanelSource *source = [[RowButtonPanelSource alloc] init];
    source.rows = @[OutdatedRegistryRow(@"first"), OutdatedRegistryRow(@"second")];
    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;
    [panel renderContentBitmap];

    NSView *cell = [panel.tableView viewAtColumn:0 row:1 makeIfNecessary:YES];
    NSButton *button = [cell valueForKey:@"actionButton"];
    Assert(button != nil && !button.hidden, @"outdated registry rows should show an update button");
    // A reused cell can carry a stale row index; the press must follow the button's current row.
    button.tag = 0;
    [panel rowButtonPressed:button];
    Assert([source.pressedRow[@"id"] isEqualToString:@"second"], @"update button should act on the row that holds it");
}

static NSString *TemporaryDirectory(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return directory;
}

static void WriteExecutable(NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@"#!/bin/sh\necho 1.0.0\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:path error:nil];
}

static void TestAgentNameHeuristic(void) {
    for (NSString *name in @[@"acme-agent", @"llm", @"gpt-cli", @"my_ai_tool", @"@corp/claude-helper", @"codex-mini"]) {
        Assert(LooksLikeAgentName(name), [NSString stringWithFormat:@"%@ should look like an agent", name]);
    }
    for (NSString *name in @[@"git", @"tree", @"agentic", @"mail", @"brain", @"jq", @"gpg-agent", @"gpg-connect-agent", @"ssh-agent"]) {
        Assert(!LooksLikeAgentName(name), [NSString stringWithFormat:@"%@ should not look like an agent", name]);
    }
}

static void TestDirectoryScansFindExecutablesOnly(void) {
    NSString *root = TemporaryDirectory();
    WriteExecutable([root stringByAppendingPathComponent:@"bin/tool"]);
    [@"data" writeToFile:[root stringByAppendingPathComponent:@"bin/readme.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    WriteExecutable([root stringByAppendingPathComponent:@"bin/.hidden"]);
    NSArray *found = ExecutablesInDirectory([root stringByAppendingPathComponent:@"bin"]);
    Assert(found.count == 1 && [[found.firstObject lastPathComponent] isEqualToString:@"tool"], @"directory scan should return only visible executables");

    NSString *apps = [root stringByAppendingPathComponent:@"Applications"];
    WriteExecutable([apps stringByAppendingPathComponent:@"Editor.app/Contents/Resources/app/bin/editor"]);
    WriteExecutable([apps stringByAppendingPathComponent:@"Box.app/Contents/Resources/bin/box"]);
    WriteExecutable([apps stringByAppendingPathComponent:@"Plain.app/Contents/MacOS/Plain"]);
    NSArray *directories = AppBundleBinDirectories(@[apps]);
    Assert(directories.count == 2, @"app bundle scan should find bundled bin directories and skip the app executable");
    Assert([[directories.firstObject stringByAppendingPathComponent:@"box"] hasSuffix:@"Box.app/Contents/Resources/bin/box"], @"app bundle directories should be sorted by app name");
}

static void TestCargoAndPipxParsing(void) {
    NSArray *cargo = ParseCargoInstallList(@"ripgrep v14.1.0:\n    rg\nfd-find v10.2.0:\n    fd\n", @"/Users/x/.cargo/bin");
    Assert(cargo.count == 2, @"cargo list should yield one item per crate");
    Assert([cargo[0][@"name"] isEqualToString:@"ripgrep"] && [cargo[0][@"currentVersion"] isEqualToString:@"14.1.0"], @"cargo crate name and version should parse");
    Assert([cargo[0][@"path"] isEqualToString:@"/Users/x/.cargo/bin/rg"], @"cargo item path should point at its first binary");

    NSString *pipx = @"{\"venvs\": {\"pycowsay\": {\"metadata\": {\"main_package\": {\"package_version\": \"0.0.0.2\", \"apps\": [\"pycowsay\"]}}}}}";
    NSArray *items = ParsePipxListJSON(pipx, @"/Users/x/.local/bin");
    Assert(items.count == 1 && [items[0][@"source"] isEqualToString:@"pipx"], @"pipx json should yield pipx items");
    Assert([items[0][@"currentVersion"] isEqualToString:@"0.0.0.2"] && [items[0][@"path"] isEqualToString:@"/Users/x/.local/bin/pycowsay"], @"pipx version and app path should parse");
    Assert(ParsePipxListJSON(@"not json", @"/tmp").count == 0, @"malformed pipx output should be ignored");
}

static void TestDirectoryItemsOnPathAreNotDuplicated(void) {
    NSString *root = TemporaryDirectory();
    NSString *tool = [root stringByAppendingPathComponent:@"tool"];
    WriteExecutable(tool);
    NSString *link = [root stringByAppendingPathComponent:@"link"];
    [[NSFileManager defaultManager] createSymbolicLinkAtPath:link withDestinationPath:tool error:nil];
    NSArray *items = @[Item(@"link", nil, nil, @"PATH", link, StatusUnknown), Item(@"tool", nil, nil, SourceLocalBin, tool, StatusUnknown),
                       Item(@"other", nil, nil, SourceLocalBin, [root stringByAppendingPathComponent:@"other"], StatusUnknown)];
    NSArray *kept = WithoutPathDuplicates(items);
    Assert(kept.count == 2, @"a ~/.local/bin file already on PATH should be listed once");
}

static void TestRegistryResolvesOffPathBinariesFromInventory(void) {
    NSString *root = TemporaryDirectory();
    NSString *codex = [root stringByAppendingPathComponent:@"codex"];
    WriteExecutable(codex);
    NSDictionary *paths = [CLIRegistryService binaryPathsFromInventory:@[@{@"name": @"@openai/codex", @"source": @"npm global"}, @{@"name": @"codex", @"source": SourceLocalBin, @"path": codex},
                                                                          @{@"name": @"gone", @"source": SourceLocalBin, @"path": [root stringByAppendingPathComponent:@"gone"]}]];
    Assert([paths[@"codex"] isEqualToString:codex], @"inventory paths should resolve registry binaries outside PATH");
    Assert(paths[@"gone"] == nil, @"missing files should not resolve");
}

static void TestRegistryRestoresCachedStatuses(void) {
    NSString *cache = TemporaryDirectory();
    NSArray *rows = @[@{@"kind": @"registry", @"id": @"codex", @"title": @"Codex", @"path": @"/usr/local/bin/codex", @"state": @"current", @"detail": @"0.47.2"},
                      @{@"kind": @"registry", @"id": @"no-such-entry", @"title": @"Gone"}];
    [[NSJSONSerialization dataWithJSONObject:rows options:0 error:nil] writeToFile:[cache stringByAppendingPathComponent:@"registry-status.json"] atomically:YES];
    CLIRegistryService *registry = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:@"Assets/CLIRegistry/registry.json"]
                                                                     iconDirectory:@"Assets/CLIRegistry/icons"
                                                                    cacheDirectory:[NSURL fileURLWithPath:cache]];
    Assert(registry.hasCachedStatuses, @"saved statuses should be detected");
    Assert(registry.statuses.count == 1 && [registry.statuses[0][@"id"] isEqualToString:@"codex"], @"cached rows should load, minus entries no longer in the registry");
    Assert(registry.statuses[0][@"icon"] != nil, @"restored rows should get their icon");

    CLIRegistryService *fresh = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:@"Assets/CLIRegistry/registry.json"]
                                                                  iconDirectory:@"Assets/CLIRegistry/icons"
                                                                 cacheDirectory:[NSURL fileURLWithPath:TemporaryDirectory()]];
    Assert(!fresh.hasCachedStatuses && fresh.statuses.count == 0, @"a first launch has no cached rows");
}

static void TestRegistryListsAgentCLIs(void) {
    CLIRegistryService *registry = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:@"Assets/CLIRegistry/registry.json"]
                                                                     iconDirectory:@"Assets/CLIRegistry/icons"
                                                                    cacheDirectory:[NSURL fileURLWithPath:TemporaryDirectory()]];
    NSMutableSet *ids = [NSMutableSet set];
    for (NSDictionary *entry in registry.entries) [ids addObject:entry[@"id"]];
    for (NSString *agent in @[@"claude", @"codex", @"cursor-agent", @"gemini", @"aider", @"opencode", @"qwen", @"copilot"]) {
        Assert([ids containsObject:agent], [NSString stringWithFormat:@"registry should list %@", agent]);
    }
}

@interface ScanPanelSource : RowButtonPanelSource
@property NSDictionary *scanning;
@end

@implementation ScanPanelSource
- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel {
    NSMutableDictionary *snapshot = [[super tickerPanelSnapshot:panel] mutableCopy];
    if (self.scanning) snapshot[@"scanning"] = self.scanning;
    return snapshot;
}
@end

static void TestPanelShowsScanningStateOnlyWhileScanning(void) {
    [NSApplication sharedApplication];
    ScanPanelSource *source = [[ScanPanelSource alloc] init];
    source.rows = @[];
    source.scanning = @{@"title": @"Scanning your machine…", @"detail": @"", @"steps": @[@{@"label": @"PATH", @"done": @YES, @"count": @3}, @{@"label": @"npm -g", @"done": @NO}]};
    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;
    [panel renderContentBitmap];
    NSView *scanView = [panel valueForKey:@"scanView"];
    Assert(scanView != nil && !scanView.hidden, @"first launch should show the scanning view");
    source.scanning = nil;
    source.rows = @[OutdatedRegistryRow(@"codex")];
    [panel reload];
    Assert(scanView.hidden, @"the scanning view should go away once results are in");
}

@interface MenuPanelSource : RowButtonPanelSource
@property NSMutableArray<NSString *> *commands;
@property NSMutableArray<NSString *> *settingChanges;
@end

@implementation MenuPanelSource
- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel {
    NSMutableDictionary *snapshot = [[super tickerPanelSnapshot:panel] mutableCopy];
    snapshot[@"menu"] = @[
        @{@"command": TickerCommandUpdateAll, @"title": @"Update all", @"shortcut": @"⌘U"},
        @{@"command": TickerCommandRefresh, @"title": @"Check for updates / rescan", @"shortcut": @"⌘R"},
        @{@"command": TickerCommandSettings, @"title": @"Settings", @"separator": @YES},
        @{@"command": TickerCommandQuit, @"title": @"Quit", @"separator": @YES}
    ];
    snapshot[@"settings"] = @[
        @{@"id": @"terminal", @"label": @"Preferred terminal", @"options": @[@"Terminal", @"Ghostty"], @"index": @0},
        @{@"id": @"refreshInterval", @"label": @"Rescan every", @"options": @[@"5 min", @"15 min", @"off"], @"index": @1}
    ];
    return snapshot;
}
- (void)tickerPanel:(TickerPanelController *)panel performCommand:(NSString *)command { [self.commands addObject:command]; }
- (void)tickerPanel:(TickerPanelController *)panel changeSetting:(NSString *)settingId toOption:(NSString *)option {
    [self.settingChanges addObject:[NSString stringWithFormat:@"%@=%@", settingId, option]];
}
@end

@interface TickerPanelController (MenuTesting) <NSTextFieldDelegate>
- (void)menuPressed:(id)sender;
- (void)cancel;
@end

static void PressKey(TickerPanelController *panel, SEL command) {
    NSTextField *field = [panel valueForKey:@"searchField"];
    [panel control:field textView:[[NSTextView alloc] init] doCommandBySelector:command];
}

static void TestHamburgerMenuIsInPanelAndKeyboardDriven(void) {
    [NSApplication sharedApplication];
    MenuPanelSource *source = [[MenuPanelSource alloc] init];
    source.rows = @[OutdatedRegistryRow(@"codex")];
    source.commands = [NSMutableArray array];
    source.settingChanges = [NSMutableArray array];
    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;
    [panel renderContentBitmap];

    [panel menuPressed:nil];
    NSView *menuView = [panel valueForKey:@"menuView"];
    Assert(panel.menuVisible && !menuView.hidden, @"the hamburger should open the in-panel menu");
    Assert(NSHeight(menuView.frame) > 4 * 22, @"the menu should size to its items");
    Assert(NSContainsRect(panel.panel.contentView.bounds, menuView.frame), @"the menu should sit inside the panel");

    PressKey(panel, @selector(moveDown:));
    PressKey(panel, @selector(insertNewline:));
    Assert([source.commands isEqualToArray:@[TickerCommandRefresh]], @"down + return should run the second item");
    Assert(!panel.menuVisible && menuView.hidden, @"activating an item should close the menu");

    [panel menuPressed:nil];
    PressKey(panel, @selector(moveUp:));
    PressKey(panel, @selector(insertNewline:));
    Assert([source.commands.lastObject isEqualToString:TickerCommandQuit], @"up from the first item should wrap to the last");

    [panel menuPressed:nil];
    PressKey(panel, @selector(cancelOperation:));
    Assert(!panel.menuVisible, @"esc should close the menu");
    Assert(source.commands.count == 2, @"esc should not run anything");

    [panel menuPressed:nil];
    PressKey(panel, @selector(moveDown:));
    PressKey(panel, @selector(moveDown:));
    PressKey(panel, @selector(insertNewline:));
    NSView *settingsView = [panel valueForKey:@"settingsView"];
    Assert(panel.settingsVisible && !settingsView.hidden, @"Settings should open the inline settings view");
    Assert(source.commands.count == 2, @"Settings is handled by the panel, not sent as a command");

    PressKey(panel, @selector(moveDown:));
    PressKey(panel, @selector(moveRight:));
    PressKey(panel, @selector(moveUp:));
    PressKey(panel, @selector(moveLeft:));
    Assert([source.settingChanges isEqualToArray:@[@"refreshInterval=off", @"terminal=Ghostty"]], [NSString stringWithFormat:@"arrow keys should change settings: %@", source.settingChanges]);

    [panel cancel];
    Assert(!panel.settingsVisible && settingsView.hidden, @"esc should leave settings before closing the panel");
}

static void TestNoNativeMenuRemains(void) {
    Assert(![MenuController instancesRespondToSelector:NSSelectorFromString(@"showClassicMenu")], @"the classic NSMenu should be gone");
    Assert(![MenuController instancesRespondToSelector:NSSelectorFromString(@"rebuildMenu")], @"the classic NSMenu builder should be gone");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TestHamburgerMenuIsInPanelAndKeyboardDriven();
        TestNoNativeMenuRemains();
        TestAgentNameHeuristic();
        TestDirectoryScansFindExecutablesOnly();
        TestCargoAndPipxParsing();
        TestDirectoryItemsOnPathAreNotDuplicated();
        TestRegistryResolvesOffPathBinariesFromInventory();
        TestRegistryRestoresCachedStatuses();
        TestRegistryListsAgentCLIs();
        TestPanelShowsScanningStateOnlyWhileScanning();
        TestCommandCapturesBothStreams();
        TestCommandReportsFailure();
        TestCommandTimeout();
        TestCommandTimeoutKillsDescendants();
        TestCommandReturnsWhenBackgroundChildHoldsOutput();
        TestCommandReportsLaunchError();
        TestUpdateCommandsReadPlainly();
        TestUpdateArgumentsAreShellSafe();
        TestSelfUpdateRunsThroughDetectedBinary();
        TestRegistryDumpWaitsForRefreshBeforeSettling();
        TestRowButtonResolvesRowFromItsView();
        NSLog(@"All CLITicker tests passed.");
    }
    return 0;
}
