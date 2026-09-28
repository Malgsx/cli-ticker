#import <AppKit/AppKit.h>

// Runs an executable and returns stdout. main.m supplies its RunCommand so version
// probes share the app's command runner instead of duplicating it.
typedef NSString *(^CLIRegistryCommandRunner)(NSString *launchPath, NSArray<NSString *> *arguments);
// Returns the shell update command for an inventory item (Homebrew / npm), or nil.
typedef NSString *(^CLIRegistryInventoryUpdateCommand)(NSDictionary *inventoryItem);

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
@property (copy) CLIRegistryInventoryUpdateCommand inventoryUpdateCommand;
// Called on the main queue whenever statuses or update progress change.
@property (copy) void (^changeHandler)(void);
// Called on the main queue after an update finishes so the inventory can rescan.
@property (copy) void (^updateFinishedHandler)(NSDictionary *status, BOOL succeeded);
@property (readonly) NSArray<NSDictionary *> *statuses;
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
