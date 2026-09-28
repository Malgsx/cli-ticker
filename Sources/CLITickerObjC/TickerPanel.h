#import <AppKit/AppKit.h>

@class TickerPanelController;

// Row dictionaries share these keys:
//   kind     agent | update | updateAll | recent | cli | registry
//   title, detail, meta (strings), icon (NSImage), item (inventory item), tooltip
//   emphasis (NSNumber BOOL) renders the detail column brighter
//   openAction / openCommand   argv (and its display form) used when the row is opened
//   selectionKey               stable id for multi-select
//   uninstallAction / uninstallCommand   argv uninstall, when one is safe
//   uninstallReason            why a row cannot be selected
// Registry rows (kind == registry) are CLIRegistry status dictionaries and render
// an update button / progress state in the right-hand column. The button is its own
// click target; activating the row opens the CLI instead.
//
// Snapshot keys besides views/terminals/sources/stats/status:
//   menu      hamburger items: {command, title, detail?, shortcut?, emphasis?, separator? (line above)}.
//             Activating one sends its command to performCommand:, except TickerCommandSettings
//             (settings view) and TickerCommandSelect (select mode), which the panel handles.
//   settings  {id, label, options: [strings], index} rows for the settings view.
//   scanning  first-launch progress (see TickerScanView).
@protocol TickerPanelDelegate <NSObject>
- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel;
- (NSArray<NSDictionary *> *)tickerPanel:(TickerPanelController *)panel rowsMatching:(NSString *)query;
- (void)tickerPanel:(TickerPanelController *)panel activateRow:(NSDictionary *)row;
- (void)tickerPanel:(TickerPanelController *)panel pressButtonOnRow:(NSDictionary *)row;
- (void)tickerPanel:(TickerPanelController *)panel copyRow:(NSDictionary *)row;
- (void)tickerPanel:(TickerPanelController *)panel performCommand:(NSString *)command;
- (void)tickerPanel:(TickerPanelController *)panel selectTerminal:(NSString *)terminal;
@optional
- (void)tickerPanel:(TickerPanelController *)panel changeSetting:(NSString *)settingId toOption:(NSString *)option;
// Invoked only after the in-panel confirmation sheet's Uninstall control is used.
// progress is called on the main queue as each plan moves through running / removed / failed.
- (void)tickerPanel:(TickerPanelController *)panel runUninstallPlans:(NSArray<NSDictionary *> *)plans progress:(void (^)(NSUInteger index, NSString *state, NSString *detail))progress completion:(void (^)(void))completion;
@end

// Selection is keyed by row[@"selectionKey"]. A row is selectable only when that key is
// set and uninstallAction is an {executable, arguments} argv action.
NSString *TickerSelectionKey(NSDictionary *row);
BOOL TickerRowIsSelectable(NSDictionary *row);
void TickerSelectionClick(NSMutableOrderedSet<NSString *> *selected, NSArray<NSDictionary *> *rows, NSInteger index, BOOL extendRange, NSInteger *anchor);
void TickerSelectionSelectAll(NSMutableOrderedSet<NSString *> *selected, NSArray<NSDictionary *> *rows);
void TickerSelectionClear(NSMutableOrderedSet<NSString *> *selected);

extern NSString *const TickerCommandRefresh;
extern NSString *const TickerCommandUpdateAll;
extern NSString *const TickerCommandJSONReport;
extern NSString *const TickerCommandMarkdownReport;
extern NSString *const TickerCommandSettings;
extern NSString *const TickerCommandUpdateApp;
extern NSString *const TickerCommandOpenGitHub;
extern NSString *const TickerCommandQuit;
extern NSString *const TickerCommandSelect;

extern const NSSize TickerPanelSize;

NSImage *TickerMonogramIcon(NSString *mark);

@interface TickerPanelController : NSObject
@property (weak) id<TickerPanelDelegate> delegate;
@property (readonly) NSPanel *panel;
@property (copy) NSString *selectedViewId;
@property (readonly, getter=isVisible) BOOL visible;
@property (readonly, getter=isMenuVisible) BOOL menuVisible;
@property (readonly, getter=isSettingsVisible) BOOL settingsVisible;
@property (readonly, getter=isSelecting) BOOL selecting;
@property (readonly, getter=isUninstallSheetVisible) BOOL uninstallSheetVisible;
@property (readonly, copy) NSOrderedSet<NSString *> *selectedKeys;

- (void)toggleRelativeToStatusButton:(NSStatusBarButton *)button;
- (void)showRelativeToStatusButton:(NSStatusBarButton *)button;
// Opens the panel with the hamburger menu already showing (right-click on the menu bar icon).
- (void)showMenuRelativeToStatusButton:(NSStatusBarButton *)button;
- (void)toggleMenu;
- (void)hideMenu;
- (void)showSettings;
- (void)hideSettings;
- (void)setSelectMode:(BOOL)enabled;
- (void)setPreviewSelectionKeys:(NSArray<NSString *> *)keys;
// Shows the confirmation sheet. Nothing is uninstalled until Uninstall is pressed.
- (void)presentUninstallConfirmation:(NSArray<NSDictionary *> *)plans;
- (void)close;
- (void)reload;

// Renders the panel content (without the window chrome) into a bitmap, for previews.
- (NSBitmapImageRep *)renderContentBitmap;
@end
