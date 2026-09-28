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

static NSDictionary *SelectableRow(NSString *key, NSString *title) {
    return @{@"kind": @"cli", @"title": title, @"selectionKey": key,
             @"uninstallCommand": [NSString stringWithFormat:@"brew uninstall %@", title],
             @"uninstallAction": @{@"executable": @"brew", @"arguments": @[@"uninstall", title]}};
}

static void TestSelectionLogic(void) {
    NSArray *rows = @[SelectableRow(@"a", @"tree"), @{@"kind": @"cli", @"title": @"git", @"selectionKey": @"b", @"uninstallReason": @"Apple system tool"}, SelectableRow(@"c", @"cowsay")];
    NSMutableOrderedSet *selected = [NSMutableOrderedSet orderedSet];
    NSInteger anchor = -1;
    TickerSelectionClick(selected, rows, 1, NO, &anchor);
    Assert(selected.count == 0 && anchor == -1, @"an unselectable row cannot be toggled");
    TickerSelectionClick(selected, rows, 0, NO, &anchor);
    Assert([selected.array isEqualToArray:@[@"a"]] && anchor == 0, @"click selects a row and sets the anchor");
    TickerSelectionClick(selected, rows, 0, NO, &anchor);
    Assert(selected.count == 0 && anchor == 0, @"click again clears that row");
    TickerSelectionClick(selected, rows, 0, NO, &anchor);
    TickerSelectionClick(selected, rows, 2, YES, &anchor);
    Assert(selected.count == 2 && [selected containsObject:@"a"] && [selected containsObject:@"c"], @"shift-click selects the range and skips unselectable rows");
    TickerSelectionClear(selected);
    TickerSelectionSelectAll(selected, rows);
    Assert(selected.count == 2 && [selected containsObject:@"a"] && [selected containsObject:@"c"], @"select all skips rows without a safe uninstall");
    TickerSelectionClear(selected);
    Assert(selected.count == 0, @"clear removes every selection");
}

static void TestUninstallPlans(void) {
    NSDictionary *brew = UninstallPlanForItem(@{@"name": @"tree", @"source": @"Homebrew"});
    Assert([brew[@"command"] isEqualToString:@"brew uninstall tree"], @"brew formulae uninstall with brew uninstall");
    Assert([brew[@"action"][@"arguments"] isEqualToArray:@[@"uninstall", @"tree"]], @"brew uninstall stays argv");

    NSDictionary *cask = UninstallPlanForItem(@{@"name": @"docker", @"source": @"Homebrew Cask"});
    Assert([cask[@"command"] isEqualToString:@"brew uninstall --cask docker"], @"casks pass --cask");

    NSDictionary *npm = UninstallPlanForItem(@{@"name": @"cowsay", @"source": @"npm global"});
    Assert([npm[@"command"] isEqualToString:@"npm uninstall -g cowsay"], @"npm globals use npm uninstall -g");

    NSDictionary *pipx = UninstallPlanForItem(@{@"name": @"pycowsay", @"source": @"pipx"});
    Assert([pipx[@"command"] isEqualToString:@"pipx uninstall pycowsay"], @"pipx has its own uninstall");

    NSDictionary *uv = UninstallPlanForItem(@{@"name": @"ruff", @"source": @"uv tool"});
    Assert([uv[@"command"] isEqualToString:@"uv tool uninstall ruff"], @"uv tools use uv tool uninstall");

    NSDictionary *cargo = UninstallPlanForItem(@{@"name": @"ripgrep", @"source": @"cargo"});
    Assert([cargo[@"command"] isEqualToString:@"cargo uninstall ripgrep"], @"cargo uninstalls the crate name");

    NSDictionary *bun = UninstallPlanForItem(@{@"name": @"prettier", @"source": @"Bun global"});
    Assert([bun[@"command"] isEqualToString:@"bun uninstall -g prettier"], @"bun globals use bun uninstall -g");

    NSDictionary *extension = UninstallPlanForItem(@{@"name": @"owner/gh-foo", @"source": @"gh extension"});
    Assert([extension[@"command"] isEqualToString:@"gh extension remove owner/gh-foo"], @"gh extensions use gh extension remove");

    NSDictionary *go = UninstallPlanForItem(@{@"name": @"goreleaser", @"source": @"go", @"path": @"/Users/x/go/bin/goreleaser"});
    Assert([go[@"action"][@"executable"] isEqualToString:@"/bin/rm"], @"go binaries are removed as a single file");
    Assert([go[@"action"][@"arguments"] isEqualToArray:@[@"/Users/x/go/bin/goreleaser"]], @"go removal does not recurse");
    Assert(UninstallPlanForItem(@{@"name": @"go", @"source": @"go", @"path": @"/usr/local/bin/go"})[@"reason"] != nil, @"a go binary outside GOBIN is not removed");

    Assert([UninstallPlanForItem(@{@"name": @"git", @"source": @"PATH", @"path": @"/usr/bin/git"})[@"reason"] isEqualToString:@"Apple system tool"], @"Apple system tools are unselectable");
    Assert([UninstallPlanForItem(@{@"name": @"editor", @"source": @"App bundle", @"path": @"/Applications/Editor.app/Contents/Resources/bin/editor"})[@"reason"] isEqualToString:@"bundled inside an app"], @"app-bundled CLIs are unselectable");
    Assert(UninstallPlanForItem(@{@"name": @"tool", @"source": @"PATH", @"path": @"/opt/homebrew/bin/tool"})[@"action"] == nil, @"a PATH entry without a package manager is not removed");
    Assert([UninstallPlanForItem(@{@"name": @"tool", @"source": @"~/.local/bin", @"path": @"/Users/x/.local/bin/tool"})[@"reason"] isEqualToString:@"no safe uninstall for this install method"], @"loose binaries have no safe uninstall");

    NSString *sentinel = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *name = [NSString stringWithFormat:@"tool'; touch '%@'; #", sentinel];
    NSDictionary *injected = UninstallPlanForItem(@{@"name": name, @"source": @"npm global"});
    Assert([injected[@"action"][@"arguments"] lastObject] == name, @"package name stays one uninstall argument");
    NSString *output = nil;
    int code = ExecuteArgvAction(@{@"executable": @"/usr/bin/printf", @"arguments": @[@"%s", name]}, 5, &output);
    Assert(code == 0 && [output isEqualToString:name], @"argv uninstall must not interpret the package name");
    Assert(![[NSFileManager defaultManager] fileExistsAtPath:sentinel], @"uninstall arguments must not execute shell syntax");
    Assert(ExecuteArgvAction(@{@"script": @"echo unsafe"}, 5, &output) == 126, @"script actions are refused for uninstall");

    NSDictionary *system = UninstallPlanForRegistryStatus(@{@"kind": @"registry", @"id": @"git", @"state": @"system", @"path": @"/usr/bin/git"});
    Assert([system[@"reason"] isEqualToString:@"Apple system tool"], @"system registry rows explain why they are locked");
}

static void TestOpenCommandResolution(void) {
    CLIRegistryService *registry = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:@"Assets/CLIRegistry/registry.json"]
                                                                     iconDirectory:@"Assets/CLIRegistry/icons"
                                                                    cacheDirectory:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
    NSDictionary *claude = nil;
    NSDictionary *git = nil;
    for (NSDictionary *entry in registry.entries) {
        if ([entry[@"id"] isEqualToString:@"claude"]) claude = entry;
        if ([entry[@"id"] isEqualToString:@"git"]) git = entry;
    }
    Assert([claude[@"open"] isKindOfClass:[NSArray class]] && [claude[@"open"] count] == 0, @"claude's registry entry overrides launch arguments");
    NSDictionary *claudeAction = OpenActionForCLI(claude, @"/usr/local/bin/claude", @"claude");
    Assert([claudeAction[@"arguments"] isEqualToArray:@[]], @"claude launches with no arguments");
    Assert([ShellCommandForUpdateAction(claudeAction) isEqualToString:@"/usr/local/bin/claude"], @"an agent launch command is just the binary");

    NSDictionary *gitAction = OpenActionForCLI(git, @"/usr/bin/git", @"git");
    Assert([gitAction[@"arguments"] isEqualToArray:@[@"--help"]], @"a plain CLI defaults to --help");
    Assert([ShellCommandForUpdateAction(gitAction) isEqualToString:@"/usr/bin/git --help"], @"the default open command is <cli> --help");

    NSDictionary *override = OpenActionForCLI(@{@"id": @"gh", @"bins": @[@"gh"], @"open": @[@"auth", @"status"]}, @"/opt/homebrew/bin/gh", @"gh");
    Assert([override[@"arguments"] isEqualToArray:@[@"auth", @"status"]], @"registry open replaces the default");
    NSDictionary *agentOverride = OpenActionForCLI(@{@"id": @"codex", @"open": @[@"--version"]}, @"/usr/local/bin/codex", @"codex");
    Assert([agentOverride[@"arguments"] isEqualToArray:@[@"--version"]], @"an explicit open list wins over the agent default");

    NSDictionary *generic = OpenActionForCLI(@{}, @"/Users/x/.local/bin/acme-agent", @"acme-agent");
    Assert([generic[@"arguments"] isEqualToArray:@[]], @"unregistered agent-like CLIs just launch");
    NSDictionary *tree = OpenActionForCLI(nil, @"tree", @"tree");
    Assert([tree[@"arguments"] isEqualToArray:@[@"--help"]], @"an unregistered plain CLI defaults to --help");

    NSDictionary *row = AnnotatedCLIRow(@{@"kind": @"cli", @"title": @"tree", @"item": @{@"name": @"tree", @"source": @"Homebrew"}}, @{});
    Assert([row[@"openCommand"] isEqualToString:@"tree --help"], @"annotated rows carry the open command");
    Assert([row[@"uninstallCommand"] isEqualToString:@"brew uninstall tree"], @"annotated rows carry the uninstall command");
    Assert([row[@"selectionKey"] isEqualToString:@"item:Homebrew:tree"], @"annotated rows have a stable selection key");
    NSDictionary *locked = AnnotatedCLIRow(@{@"kind": @"registry", @"id": @"git", @"title": @"Git", @"state": @"system", @"path": @"/usr/bin/git"}, @{@"id": @"git", @"bins": @[@"git"]});
    Assert(locked[@"uninstallAction"] == nil && [locked[@"uninstallReason"] isEqualToString:@"Apple system tool"], @"system rows stay unselectable");
    Assert([locked[@"openCommand"] isEqualToString:@"/usr/bin/git --help"], @"a system CLI can still be opened");
}

static void TestTerminalLaunchDoesNotBlock(void) {
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_semaphore_t hold = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSString *seenCommand = nil;
    __block BOOL finished = NO;
    TerminalLaunchHook = ^(NSString *command, NSString *terminal) {
        seenCommand = command;
        dispatch_semaphore_signal(started);
        dispatch_semaphore_wait(hold, DISPATCH_TIME_FOREVER);
        finished = YES;
        dispatch_semaphore_signal(done);
    };
    NSDate *began = [NSDate date];
    DispatchTerminalLaunch(@"tree --help", @"Ghostty");
    Assert(-[began timeIntervalSinceNow] < 0.5, @"scheduling a terminal launch returns immediately");
    Assert(dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) == 0, @"the launch runs off the caller");
    Assert(!finished, @"the caller does not wait for the terminal");
    Assert([seenCommand isEqualToString:@"tree --help"], @"the launch receives the open command");
    dispatch_semaphore_signal(hold);
    Assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) == 0, @"the background launch should finish once released");
    TerminalLaunchHook = nil;
}

static void TestTerminalLaunchTargetsPreferredBundle(void) {
    NSDictionary *expected = @{
        @"Terminal": @"com.apple.Terminal",
        @"Ghostty": @"com.mitchellh.ghostty",
        @"iTerm": @"com.googlecode.iterm2",
        @"Warp": @"dev.warp.Warp-Stable",
        @"Alacritty": @"org.alacritty"
    };
    NSString *agent = ShellCommandForUpdateAction(OpenActionForCLI(@{@"id": @"claude", @"open": @[]}, @"/usr/local/bin/claude", @"claude"));
    NSString *cli = ShellCommandForUpdateAction(OpenActionForCLI(nil, @"/usr/bin/git", @"git"));
    Assert([agent isEqualToString:@"/usr/local/bin/claude"], @"an interactive agent command is the binary");
    Assert([cli isEqualToString:@"/usr/bin/git --help"], @"a plain CLI command uses the registry default");

    for (NSString *name in expected) {
        NSDictionary *request = TerminalLaunchRequest(name, cli);
        NSString *bundle = expected[name];
        NSString *joined = [request[@"arguments"] componentsJoinedByString:@"\n"];
        Assert([request[@"bundleIdentifier"] isEqualToString:bundle], [NSString stringWithFormat:@"%@ should launch %@", name, bundle]);
        Assert([joined containsString:bundle], [NSString stringWithFormat:@"%@ launch arguments must name %@\n%@", name, bundle, joined]);
        BOOL carriesCommand = [joined containsString:cli] || [request[@"configuration"] containsString:cli];
        Assert(carriesCommand, [NSString stringWithFormat:@"%@ launch must include the CLI command", name]);
        Assert([request[@"command"] isEqualToString:cli], @"the launch request keeps the command");
    }

    NSDictionary *ghosttyAgent = TerminalLaunchRequest(@"Ghostty", agent);
    NSDictionary *terminalCLI = TerminalLaunchRequest(@"Terminal", cli);
    NSString *ghosttyArgs = [ghosttyAgent[@"arguments"] componentsJoinedByString:@"\n"];
    Assert([ghosttyAgent[@"bundleIdentifier"] isEqualToString:@"com.mitchellh.ghostty"], @"preferred Ghostty targets com.mitchellh.ghostty");
    Assert([ghosttyArgs containsString:@"com.mitchellh.ghostty"], @"the Ghostty script addresses that bundle id");
    Assert([ghosttyArgs containsString:agent], @"an agent row launches the agent command");
    Assert(![ghosttyArgs containsString:@"--help"], @"an interactive agent is not opened with --help");
    Assert([[ghosttyAgent[@"directArguments"] componentsJoinedByString:@" "] containsString:@"com.mitchellh.ghostty"], @"Ghostty's direct open still targets its bundle");
    Assert([[ghosttyAgent[@"directArguments"] lastObject] isEqualToString:agent], @"the direct Ghostty open runs the agent command");
    Assert([terminalCLI[@"bundleIdentifier"] isEqualToString:@"com.apple.Terminal"], @"preferred Terminal.app targets com.apple.Terminal");
    Assert(![ghosttyAgent[@"bundleIdentifier"] isEqualToString:terminalCLI[@"bundleIdentifier"]], @"Ghostty and Terminal.app must produce different launch targets");

    NSDictionary *installed = TerminalOpenPlan(@"Ghostty", agent, YES);
    Assert(![installed[@"fallback"] boolValue] && installed[@"notice"] == nil, @"an installed preferred terminal is launched as itself");
    Assert([installed[@"bundleIdentifier"] isEqualToString:@"com.mitchellh.ghostty"], @"installed Ghostty stays on Ghostty");

    NSDictionary *missing = TerminalOpenPlan(@"Ghostty", cli, NO);
    Assert([missing[@"fallback"] boolValue], @"a missing preferred terminal falls back");
    Assert([missing[@"notice"] containsString:@"Ghostty isn't installed"], @"the panel is told which terminal is missing");
    Assert([missing[@"notice"] containsString:@"Opening Terminal instead"], @"the panel says which app will open");
    Assert([missing[@"preferred"] isEqualToString:@"Ghostty"], @"the saved preference stays Ghostty");
    Assert([missing[@"bundleIdentifier"] isEqualToString:@"com.apple.Terminal"], @"the fallback target is Terminal.app");
    Assert(![missing[@"bundleIdentifier"] isEqualToString:installed[@"bundleIdentifier"]], @"the fallback launch target differs from Ghostty");
}

@interface UninstallPanelSource : RowButtonPanelSource
@property NSUInteger activations;
@property NSUInteger uninstallRuns;
@property NSArray *plans;
@end

@implementation UninstallPanelSource
- (void)tickerPanel:(TickerPanelController *)panel activateRow:(NSDictionary *)row { self.activations++; }
- (void)tickerPanel:(TickerPanelController *)panel runUninstallPlans:(NSArray<NSDictionary *> *)plans progress:(void (^)(NSUInteger, NSString *, NSString *))progress completion:(void (^)(void))completion {
    self.uninstallRuns++;
    self.plans = plans;
    if (progress) progress(0, @"removed", @"removed");
    if (completion) completion();
}
@end

@interface TickerPanelController (UninstallTesting)
- (void)handleRowClickAtIndex:(NSInteger)index shift:(BOOL)shift;
- (void)uninstallFooterPressed;
- (void)confirmUninstallPressed;
- (void)cancelUninstallPressed;
@end

static void TestSelectModeConfirmsBeforeUninstall(void) {
    [NSApplication sharedApplication];
    UninstallPanelSource *source = [[UninstallPanelSource alloc] init];
    source.rows = @[SelectableRow(@"a", @"tree"), @{@"kind": @"cli", @"title": @"git", @"selectionKey": @"b", @"uninstallReason": @"Apple system tool"}, SelectableRow(@"c", @"cowsay")];
    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;
    [panel renderContentBitmap];

    [panel handleRowClickAtIndex:0 shift:NO];
    Assert(source.activations == 1 && panel.selectedKeys.count == 0, @"a click outside select mode opens the row");

    [panel setSelectMode:YES];
    [panel handleRowClickAtIndex:0 shift:NO];
    [panel handleRowClickAtIndex:1 shift:NO];
    Assert(source.activations == 1, @"select mode does not open the CLI");
    Assert([panel.selectedKeys.array isEqualToArray:@[@"a"]], @"select mode toggles only selectable rows");
    [panel handleRowClickAtIndex:2 shift:YES];
    Assert(panel.selectedKeys.count == 2 && [panel.selectedKeys containsObject:@"a"] && [panel.selectedKeys containsObject:@"c"], @"shift-click in the panel selects the range");

    [panel uninstallFooterPressed];
    Assert(panel.uninstallSheetVisible && source.uninstallRuns == 0, @"the footer opens the confirmation sheet and does not uninstall");
    Assert(panel.uninstallSheetVisible, @"the sheet stays up until a choice is made");
    [panel cancelUninstallPressed];
    Assert(!panel.uninstallSheetVisible && source.uninstallRuns == 0, @"cancel leaves every CLI installed");

    [panel uninstallFooterPressed];
    [panel confirmUninstallPressed];
    Assert(source.uninstallRuns == 1, @"Uninstall on the sheet is what starts the commands");
    Assert(source.plans.count == 2, @"the sheet runs one plan per selected CLI");
    Assert([source.plans[0][@"command"] isEqualToString:@"brew uninstall tree"], @"the confirmed plan carries the exact command");
    Assert([source.plans[1][@"command"] isEqualToString:@"brew uninstall cowsay"], @"the second plan is cowsay");
}

@interface UpdatePanelSource : RowButtonPanelSource
@property NSArray<NSString *> *confirmed;
@end

@implementation UpdatePanelSource
- (void)tickerPanel:(TickerPanelController *)panel confirmUpdateCommands:(NSArray<NSString *> *)commands {
    self.confirmed = commands;
}
@end

@interface TickerPanelController (UpdateTesting)
- (void)confirmUpdatePressed;
- (void)cancelUpdatePressed;
- (void)windowDidResignKey:(NSNotification *)notification;
@end

static void AssertUpdateConfirmationDetached(TickerPanelController *panel) {
    Assert(panel.updateConfirmationDetached, @"opening the confirmation detaches it from the status panel");
    NSWindow *updateWindow = panel.updateWindow;
    Assert(updateWindow != nil && updateWindow != panel.panel, @"the confirmation is its own window");
    NSView *sheet = [panel valueForKey:@"updateSheet"];
    Assert(sheet.window == updateWindow, @"the card is hosted by the detached window");
    Assert((updateWindow.styleMask & NSWindowStyleMaskTitled) != 0, @"a title bar lets the window be dragged");
    Assert((updateWindow.styleMask & NSWindowStyleMaskClosable) != 0, @"the window has a close button");
    Assert(updateWindow.movable, @"the detached window can be moved");
    Assert(updateWindow.level == NSFloatingWindowLevel, @"the confirmation floats on its own");
    Assert(updateWindow.level != panel.panel.level, @"it is not glued to the status-item window level");
    Assert(panel.panel.childWindows == nil || ![panel.panel.childWindows containsObject:updateWindow], @"it is not a child of the status panel");
    Assert(NSWidth(sheet.frame) >= TickerPanelSize.width - 1, @"the window is wide enough for the ten-per-page grid");
}

static void TestUpdateConfirmationPaginatesTenPerPage(void) {
    [NSApplication sharedApplication];
    UpdatePanelSource *source = [[UpdatePanelSource alloc] init];
    source.rows = @[];
    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;
    [panel renderContentBitmap];

    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    for (NSUInteger i = 0; i < 25; i++) [commands addObject:[NSString stringWithFormat:@"brew upgrade pkg-%lu", (unsigned long)i]];
    [panel presentUpdateConfirmationWithTitle:@"Update 25 tools?" detail:@"Opens Ghostty and runs these" commands:commands];
    Assert(panel.updateSheetVisible, @"Update all opens the confirmation");
    AssertUpdateConfirmationDetached(panel);
    Assert(TickerUpdatePageSize == 10, @"a page holds 10 commands");
    Assert(panel.updatePage == 1 && panel.updatePageCount == 3, @"25 commands fill three pages");
    Assert(panel.visibleUpdateCommands.count == 10, @"the first page shows 10 commands");
    Assert([panel.visibleUpdateCommands.firstObject isEqualToString:@"brew upgrade pkg-0"], @"page 1 starts at the first command");
    NSView *sheet = [panel valueForKey:@"updateSheet"];
    NSButton *exitButton = [sheet valueForKey:@"exitButton"];
    Assert([exitButton.title isEqualToString:@"Exit"], @"the card has an Exit button");
    Assert(exitButton.action == @selector(cancelUpdatePressed) && exitButton.target == panel, @"Exit closes the card");
    Assert(NSMaxY(exitButton.frame) < 36 && NSMinX(exitButton.frame) > NSWidth(sheet.frame) * 0.7, @"Exit sits in the top-right of the card");
    Assert(NSWidth(sheet.frame) > NSHeight(sheet.frame), @"the confirmation is a wide box");
    Assert(sheet.window != panel.panel, @"the card is not trapped in the status panel");

    NSArray<NSString *> *pageOne = [panel.visibleUpdateCommands copy];
    Assert(pageOne.count == 10, @"page 1 is ten commands");
    for (NSUInteger i = 0; i < 10; i++) {
        Assert([pageOne[i] isEqualToString:[NSString stringWithFormat:@"brew upgrade pkg-%lu", (unsigned long)i]], @"page 1 keeps command order");
    }
    NSView *commandSheet = [panel valueForKey:@"updateSheet"];
    NSRect box = [panel visibleUpdateCommandBoxFrame];
    NSRect first = [panel frameForVisibleUpdateCommandAtIndex:0];
    NSRect second = [panel frameForVisibleUpdateCommandAtIndex:1];
    NSRect sixth = [panel frameForVisibleUpdateCommandAtIndex:5];
    Assert(NSWidth(box) > NSHeight(box) * 2, @"the ten commands sit in a horizontal box");
    Assert(NSContainsRect(box, first) && NSContainsRect(box, sixth), @"every command on the page is inside the box");
    Assert(NSMinX(second) >= NSMaxX(first) && fabs(NSMinY(first) - NSMinY(second)) < 1, @"the second command is beside the first");
    Assert(NSMinY(sixth) >= NSMaxY(first) && fabs(NSMinX(first) - NSMinX(sixth)) < 1, @"the sixth command wraps to the next row of the box");
    Assert(NSWidth(first) < NSWidth(commandSheet.frame) / 3.0, @"a command is a cell, not a full-width line");
    NSButton *previous = [commandSheet valueForKey:@"previousButton"];
    NSButton *next = [commandSheet valueForKey:@"nextButton"];
    Assert(!previous.hidden && !next.hidden, @"more than ten commands show the page controls");

    PressKey(panel, @selector(moveRight:));
    Assert(panel.updatePage == 2 && [panel.visibleUpdateCommands.firstObject isEqualToString:@"brew upgrade pkg-10"], @"right arrow shows the next 10");
    NSArray<NSString *> *pageTwo = [panel.visibleUpdateCommands copy];
    Assert(pageTwo.count == 10, @"page 2 is ten commands");
    Assert(![pageTwo containsObject:@"brew upgrade pkg-0"] && ![pageTwo containsObject:@"brew upgrade pkg-9"], @"page 2 hides the first page");
    Assert([pageTwo.lastObject isEqualToString:@"brew upgrade pkg-19"], @"page 2 ends at command 20");
    PressKey(panel, @selector(moveRight:));
    Assert(panel.updatePage == 3 && panel.visibleUpdateCommands.count == 5, @"the last page holds the remainder");
    NSArray<NSString *> *pageThree = [panel.visibleUpdateCommands copy];
    Assert([pageThree.firstObject isEqualToString:@"brew upgrade pkg-20"] && [pageThree.lastObject isEqualToString:@"brew upgrade pkg-24"], @"page 3 is the last five commands");
    PressKey(panel, @selector(moveRight:));
    Assert(panel.updatePage == 3, @"the last page stays put");
    PressKey(panel, @selector(moveLeft:));
    Assert(panel.updatePage == 2, @"left arrow goes back a page");

    PressKey(panel, @selector(cancelOperation:));
    Assert(!panel.updateSheetVisible && source.confirmed == nil, @"esc closes the sheet without updating");

    [panel presentUpdateConfirmationWithTitle:@"Update 25 tools?" detail:@"Opens Ghostty and runs these" commands:commands];
    PressKey(panel, @selector(moveRight:));
    PressKey(panel, @selector(insertNewline:));
    Assert(!panel.updateSheetVisible, @"return confirms and closes the sheet");
    Assert(source.confirmed.count == 25, @"confirm includes every page, not only the one on screen");
    Assert([source.confirmed[14] isEqualToString:@"brew upgrade pkg-14"], @"a command from a later page is included");

    source.confirmed = nil;
    [panel presentUpdateConfirmationWithTitle:@"No supported updates" detail:@"These need a manual update." commands:@[]];
    Assert(panel.visibleUpdateCommands.count == 0 && panel.updatePageCount == 1, @"an empty plan is one blank page");
    NSButton *confirm = [[panel valueForKey:@"updateSheet"] valueForKey:@"confirmButton"];
    Assert(confirm.hidden, @"an empty plan has no Update control");
    PressKey(panel, @selector(insertNewline:));
    Assert(panel.updateSheetVisible && source.confirmed == nil, @"return does not run an empty plan");
    [panel cancelUpdatePressed];
    Assert(!panel.updateSheetVisible, @"cancel dismisses the empty plan");

    [panel presentUpdateConfirmationWithTitle:@"Update 25 tools?" detail:@"Opens Ghostty and runs these" commands:commands];
    exitButton = [[panel valueForKey:@"updateSheet"] valueForKey:@"exitButton"];
    Assert([exitButton sendAction:exitButton.action to:exitButton.target], @"Exit sends its action");
    Assert(!panel.updateSheetVisible && source.confirmed == nil, @"Exit closes the sheet without updating");

    [panel presentUpdateConfirmationWithTitle:@"Update 25 tools?" detail:@"Opens Ghostty and runs these" commands:commands];
    AssertUpdateConfirmationDetached(panel);
    NSWindow *updateWindow = panel.updateWindow;
    [panel.panel orderFrontRegardless];
    if (panel.panel.isVisible) {
        [panel windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:panel.panel]];
        Assert(!panel.isVisible, @"resigning key closes the status panel");
    }
    Assert(panel.updateSheetVisible && updateWindow.isVisible && source.confirmed == nil, @"the status panel resigning does not dismiss the confirmation");
    [panel close];
    Assert(panel.updateSheetVisible && updateWindow.isVisible && source.confirmed == nil, @"closing the status panel does not cancel the confirmation");
    [updateWindow close];
    Assert(!panel.updateSheetVisible && source.confirmed == nil, @"closing the detached window cancels");

    NSMutableArray<NSString *> *four = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) [four addObject:[NSString stringWithFormat:@"brew upgrade few-%lu", (unsigned long)i]];
    [panel presentUpdateConfirmationWithTitle:@"Update 4 tools?" detail:@"Opens Ghostty" commands:four];
    Assert(panel.updatePageCount == 1 && panel.visibleUpdateCommands.count == 4, @"one to ten commands stay on a single page");
    NSButton *singlePagePrevious = [[panel valueForKey:@"updateSheet"] valueForKey:@"previousButton"];
    Assert(singlePagePrevious.hidden, @"a single page does not show the pager");
    NSRect only = [panel frameForVisibleUpdateCommandAtIndex:0];
    NSRect beside = [panel frameForVisibleUpdateCommandAtIndex:1];
    Assert(NSMinX(beside) >= NSMaxX(only), @"a short page still lays commands across the box");
    Assert(NSEqualRects([panel frameForVisibleUpdateCommandAtIndex:4], NSZeroRect), @"a short page does not invent empty slots");
    [panel cancelUpdatePressed];

    NSMutableArray<NSString *> *eightyEight = [NSMutableArray array];
    for (NSUInteger i = 0; i < 88; i++) [eightyEight addObject:[NSString stringWithFormat:@"brew upgrade many-%lu", (unsigned long)i]];
    [panel presentUpdateConfirmationWithTitle:@"Update 88 tools?" detail:@"Opens Ghostty" commands:eightyEight];
    Assert(panel.updatePageCount == 9 && panel.visibleUpdateCommands.count == 10, @"88 commands fill nine pages of ten");
    for (NSUInteger page = 1; page < 9; page++) PressKey(panel, @selector(moveRight:));
    Assert(panel.updatePage == 9 && panel.visibleUpdateCommands.count == 8, @"the ninth page holds the last eight");
    Assert([panel.visibleUpdateCommands.firstObject isEqualToString:@"brew upgrade many-80"], @"the last page starts at command 81");
    [panel cancelUpdatePressed];
}

static NSDictionary *UpdatableRow(NSString *key, NSString *command) {
    NSMutableDictionary *row = [SelectableRow(key, key) mutableCopy];
    row[@"updateCommand"] = command;
    return row;
}

@interface GroupUpdatePanelSource : UpdatePanelSource
@end

@implementation GroupUpdatePanelSource
- (void)tickerPanel:(TickerPanelController *)panel confirmUpdateCommands:(NSArray<NSString *> *)commands {
    self.confirmed = commands;
    DispatchGroupUpdate(commands, @"echo group", @"Ghostty", nil);
}
@end

static void TestGroupUpdateDoesNotBlock(void) {
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_semaphore_t hold = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSArray<NSString *> *seenCommands = nil;
    __block NSString *seenTerminal = nil;
    __block BOOL finished = NO;
    GroupUpdateHook = ^(NSArray<NSString *> *commands, NSString *terminal) {
        seenCommands = commands;
        seenTerminal = terminal;
        dispatch_semaphore_signal(started);
        dispatch_semaphore_wait(hold, DISPATCH_TIME_FOREVER);
        finished = YES;
        dispatch_semaphore_signal(done);
    };

    [NSApplication sharedApplication];
    GroupUpdatePanelSource *source = [[GroupUpdatePanelSource alloc] init];
    source.rows = @[
        UpdatableRow(@"a", @"brew upgrade a"),
        UpdatableRow(@"b", @"brew upgrade b"),
        UpdatableRow(@"c", @"npm install -g c")
    ];
    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;
    [panel renderContentBitmap];
    [panel setSelectMode:YES];
    [panel handleRowClickAtIndex:0 shift:NO];
    [panel handleRowClickAtIndex:2 shift:NO];
    NSButton *update = [panel valueForKey:@"footerUpdate"];
    Assert(update != nil && !update.hidden, @"two selected updates show an Update control");
    Assert([update.title isEqualToString:@"Update 2"], @"the control counts the selected update commands");
    Assert([update sendAction:update.action to:update.target], @"Update opens the confirmation");
    Assert(panel.updateSheetVisible && panel.updatePageCount == 1, @"the selection confirms in the detached window");
    AssertUpdateConfirmationDetached(panel);
    Assert([panel.visibleUpdateCommands isEqualToArray:@[@"brew upgrade a", @"npm install -g c"]], @"the sheet lists only the selected commands");
    NSButton *pager = [[panel valueForKey:@"updateSheet"] valueForKey:@"previousButton"];
    Assert(pager.hidden, @"two commands do not paginate");

    source.confirmed = nil;
    NSDate *began = [NSDate date];
    PressKey(panel, @selector(insertNewline:));
    Assert(-[began timeIntervalSinceNow] < 0.5, @"confirming a multi-select update returns immediately");
    Assert(!panel.updateSheetVisible && !panel.updateWindow.isVisible, @"confirm closes the detached window");
    Assert(source.confirmed.count == 2, @"confirm hands back every selected command");
    Assert(dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) == 0, @"the group update runs off the caller");
    Assert(!finished, @"the caller does not wait for the terminal");
    Assert([seenCommands isEqualToArray:source.confirmed], @"the background update receives the selected commands");
    Assert([seenTerminal isEqualToString:@"Ghostty"], @"the background update uses the preferred terminal");
    dispatch_semaphore_signal(hold);
    Assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))) == 0, @"the background update finishes once released");
    GroupUpdateHook = nil;

    [panel noteBackgroundUpdateStatus:@"Updating 2 in Ghostty…"];
    NSTextField *footer = [panel valueForKey:@"footerRight"];
    Assert([footer.stringValue isEqualToString:@"Updating 2 in Ghostty…"], @"group update progress shows in the footer");
    NSMutableDictionary *running = [UpdatableRow(@"a", @"brew upgrade a") mutableCopy];
    running[@"updateState"] = @"running";
    source.rows = @[running];
    [panel setSelectMode:NO];
    [panel reload];
    NSTableView *table = [panel valueForKey:@"tableView"];
    NSView *cell = [table viewAtColumn:0 row:0 makeIfNecessary:YES];
    NSTextField *meta = [cell valueForKey:@"metaLabel"];
    Assert([meta.stringValue isEqualToString:@"updating"], @"a running group update marks the row");
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
        TestSelectionLogic();
        TestUninstallPlans();
        TestOpenCommandResolution();
        TestTerminalLaunchDoesNotBlock();
        TestTerminalLaunchTargetsPreferredBundle();
        TestSelectModeConfirmsBeforeUninstall();
        TestUpdateConfirmationPaginatesTenPerPage();
        TestGroupUpdateDoesNotBlock();
        NSLog(@"All CLITicker tests passed.");
    }
    return 0;
}
