#import <AppKit/AppKit.h>

// Runs an executable and returns stdout. main.m supplies its RunCommand so version
// probes share the app's command runner instead of duplicating it.
typedef NSString *(^CLIRegistryCommandRunner)(NSString *launchPath, NSArray<NSString *> *arguments);
// Update actions share main.m's update-action shape: @{executable, arguments} runs as
// argv without a shell; @{script} is reserved for fixed vendor installer pipelines.
typedef NSDictionary *(^CLIRegistryInventoryUpdateAction)(NSDictionary *inventoryItem);
// Serializes an update action for display (tooltips, copy command).
typedef NSString *(^CLIRegistryShellCommandForAction)(NSDictionary *action);

extern NSString *const CLIUpdateStateQueued;
extern NSString *const CLIUpdateStateRunning;
extern NSString *const CLIUpdateStateSucceeded;
extern NSString *const CLIUpdateStateFailed;

// Detects well-known CLIs from a bundled JSON registry, resolves their installed
// version and install method, and decides whether an update is available using
// the matching source: Homebrew / npm inventory, a registry check command, or the
// latest GitHub release. Status dictionaries are ready to render as panel rows.
@interface CLIRegistryService : NSObject
@property (copy) CLIRegistryCommandRunner commandRunner;
@property (copy) CLIRegistryInventoryUpdateAction inventoryUpdateAction;
@property (copy) CLIRegistryShellCommandForAction shellCommandForAction;
// Called on the main queue whenever statuses or update progress change.
@property (copy) void (^changeHandler)(void);
// Called on the main queue after an update finishes so the inventory can rescan.
@property (copy) void (^updateFinishedHandler)(NSDictionary *status, BOOL succeeded);
@property (nonatomic, readonly) NSArray<NSDictionary *> *statuses;
@property (readonly, getter=isChecking) BOOL checking;

- (instancetype)initWithRegistryURL:(NSURL *)registryURL iconDirectory:(NSString *)iconDirectory cacheDirectory:(NSURL *)cacheDirectory;
- (void)refreshWithInventory:(NSArray<NSDictionary *> *)items force:(BOOL)force;
// Only ever invoked from an explicit user click.
- (void)runUpdateForStatus:(NSDictionary *)status;
- (NSString *)activeUpdateSummary;

// Exposed for previews and tests.
+ (NSComparisonResult)compareVersion:(NSString *)a toVersion:(NSString *)b;
+ (NSString *)versionFromOutput:(NSString *)output pattern:(NSString *)pattern;
- (NSImage *)iconForEntry:(NSDictionary *)entry;
- (NSArray<NSDictionary *> *)entries;
@end
