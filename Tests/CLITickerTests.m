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
        NSLog(@"All CLITicker tests passed.");
    }
    return 0;
}
