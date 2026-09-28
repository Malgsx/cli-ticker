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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
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
