#import <AppKit/AppKit.h>

@class TickerPanelController;

// Row dictionaries share these keys:
//   kind     agent | update | updateAll | recent | cli | registry
//   title, detail, meta (strings), icon (NSImage), item (inventory item), tooltip
//   emphasis (NSNumber BOOL) renders the detail column brighter
// Registry rows (kind == registry) are CLIRegistry status dictionaries and render
// an update button / progress state in the right-hand column.
@protocol TickerPanelDelegate <NSObject>
- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel;
- (NSArray<NSDictionary *> *)tickerPanel:(TickerPanelController *)panel rowsMatching:(NSString *)query;
- (void)tickerPanel:(TickerPanelController *)panel activateRow:(NSDictionary *)row;
- (void)tickerPanel:(TickerPanelController *)panel pressButtonOnRow:(NSDictionary *)row;
- (void)tickerPanel:(TickerPanelController *)panel copyRow:(NSDictionary *)row;
- (void)tickerPanel:(TickerPanelController *)panel performCommand:(NSString *)command;
- (void)tickerPanel:(TickerPanelController *)panel selectTerminal:(NSString *)terminal;
@end

extern NSString *const TickerCommandRefresh;
extern NSString *const TickerCommandUpdateAll;
extern NSString *const TickerCommandJSONReport;
extern NSString *const TickerCommandMarkdownReport;
extern NSString *const TickerCommandClassicMenu;
extern NSString *const TickerCommandQuit;

extern const NSSize TickerPanelSize;

NSImage *TickerMonogramIcon(NSString *mark);

@interface TickerPanelController : NSObject
@property (weak) id<TickerPanelDelegate> delegate;
@property (readonly) NSPanel *panel;
@property (copy) NSString *selectedViewId;
@property (readonly, getter=isVisible) BOOL visible;

- (void)toggleRelativeToStatusButton:(NSStatusBarButton *)button;
- (void)showRelativeToStatusButton:(NSStatusBarButton *)button;
- (void)close;
- (void)reload;

// Renders the panel content (without the window chrome) into a bitmap, for previews.
- (NSBitmapImageRep *)renderContentBitmap;
@end
