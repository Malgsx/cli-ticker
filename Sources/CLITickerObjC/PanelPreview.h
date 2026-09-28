#import <AppKit/AppKit.h>

// `CLITicker --render-previews <dir>` renders the menu bar panel with fixture data
// to menubar-preview.png and cli-list-preview.png, then exits. Used by CI.
BOOL RenderPanelPreviewsIfRequested(void);

// Composites a rendered panel bitmap over a backdrop (optionally under a mock menu bar) and writes a PNG.
BOOL WritePanelPreviewPNG(NSBitmapImageRep *panelBitmap, NSString *path, BOOL withMenuBar);
