#import <AppKit/AppKit.h>

// `CLITicker --render-previews <dir>` renders the menu bar panel with fixture data
// to menubar-preview.png and cli-list-preview.png, then exits. Used by CI.
BOOL RenderPanelPreviewsIfRequested(void);
