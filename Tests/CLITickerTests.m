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
        TestUpdateArgumentsAreShellSafe();
        NSLog(@"All CLITicker tests passed.");
    }
    return 0;
}
