#import "PanelPreview.h"
#import "CLIRegistry.h"
#import "TickerPanel.h"

@interface PanelPreviewSource : NSObject <TickerPanelDelegate>
@property CLIRegistryService *registry;
@end

@implementation PanelPreviewSource

- (NSDictionary *)registryRow:(NSString *)entryId version:(NSString *)version latest:(NSString *)latest via:(NSString *)via state:(NSString *)state update:(NSString *)updateState {
    NSDictionary *entry = nil;
    for (NSDictionary *candidate in self.registry.entries) {
        if ([candidate[@"id"] isEqualToString:entryId]) entry = candidate;
    }
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"kind"] = @"registry";
    row[@"id"] = entryId;
    row[@"title"] = entry[@"label"] ?: entryId;
    row[@"icon"] = [self.registry iconForEntry:entry ?: @{@"id": entryId, @"label": entryId}];
    row[@"version"] = version;
    row[@"via"] = via;
    row[@"state"] = state;
    row[@"detail"] = latest ? [NSString stringWithFormat:@"%@ → %@", version, latest] : version;
    row[@"emphasis"] = @(latest != nil);
    if ([state isEqualToString:@"outdated"]) { row[@"updateAction"] = @{@"executable": @"true", @"arguments": @[]}; row[@"updateCommand"] = @"fixture"; }
    if (updateState) row[@"updateState"] = updateState;
    return row;
}

- (NSArray *)registryRows {
    return @[
        [self registryRow:@"gh" version:@"2.62.0" latest:@"2.63.1" via:@"brew" state:@"outdated" update:nil],
        [self registryRow:@"git" version:@"2.47.1" latest:nil via:@"brew" state:@"current" update:nil],
        [self registryRow:@"node" version:@"23.4.0" latest:nil via:@"brew" state:@"current" update:nil],
        [self registryRow:@"npm" version:@"10.9.2" latest:@"11.0.0" via:@"npm" state:@"outdated" update:CLIUpdateStateRunning],
        [self registryRow:@"brew" version:@"4.4.13" latest:nil via:@"self" state:@"current" update:nil],
        [self registryRow:@"docker" version:@"27.4.0" latest:nil via:@"cask" state:@"current" update:nil],
        [self registryRow:@"aws" version:@"2.22.20" latest:@"2.22.35" via:@"brew" state:@"outdated" update:nil],
        [self registryRow:@"gcloud" version:@"503.0.0" latest:nil via:@"gcloud" state:@"outdated" update:nil],
        [self registryRow:@"az" version:@"2.67.0" latest:nil via:@"brew" state:@"current" update:CLIUpdateStateSucceeded],
        [self registryRow:@"kubectl" version:@"1.32.0" latest:nil via:@"brew" state:@"current" update:nil],
        [self registryRow:@"terraform" version:@"1.10.3" latest:@"1.10.4" via:@"brew" state:@"outdated" update:CLIUpdateStateFailed],
        [self registryRow:@"firebase" version:@"13.29.1" latest:nil via:@"npm" state:@"current" update:nil],
        [self registryRow:@"vercel" version:@"39.2.6" latest:nil via:@"npm" state:@"current" update:nil],
        [self registryRow:@"stripe" version:@"1.22.0" latest:nil via:@"brew" state:@"current" update:nil],
        [self registryRow:@"cursor-agent" version:@"2026.09.12" latest:nil via:@"self" state:@"unknown" update:nil],
        [self registryRow:@"claude" version:@"2.1.4" latest:nil via:@"npm" state:@"current" update:nil]
    ];
}

- (NSDictionary *)row:(NSString *)kind title:(NSString *)title detail:(NSString *)detail via:(NSString *)via meta:(NSString *)meta symbol:(NSString *)symbol emphasis:(BOOL)emphasis {
    return @{@"kind": kind, @"title": title, @"detail": detail, @"via": via, @"meta": meta, @"emphasis": @(emphasis),
             @"icon": [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]};
}

- (NSArray *)updateRows {
    return @[
        [self row:@"updateAll" title:@"Update all" detail:@"9 commands" via:@"" meta:@"run ›" symbol:@"arrow.down.to.line" emphasis:YES],
        [self row:@"update" title:@"gh" detail:@"2.62.0 → 2.63.1" via:@"brew" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"awscli" detail:@"2.22.20 → 2.22.35" via:@"brew" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"ffmpeg" detail:@"7.1 → 7.1.1" via:@"brew" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"terraform" detail:@"1.10.3 → 1.10.4" via:@"brew" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"ghostty" detail:@"1.0.0 → 1.0.1" via:@"cask" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"npm" detail:@"10.9.2 → 11.0.0" via:@"npm" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"Codex" detail:@"0.46.0 → 0.47.2" via:@"npm" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"pnpm" detail:@"9.15.0 → 9.15.2" via:@"npm" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"wrangler" detail:@"3.99.0 → 3.101.0" via:@"npm" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"sqlite" detail:@"3.47.1 → 3.47.2" via:@"brew" meta:@"update ›" symbol:@"arrow.triangle.2.circlepath" emphasis:YES],
        [self row:@"update" title:@"uv" detail:@"0.5.11" via:@"uv" meta:@"manual" symbol:@"arrow.triangle.2.circlepath" emphasis:NO]
    ];
}

- (NSDictionary *)tickerPanelSnapshot:(TickerPanelController *)panel {
    NSArray *registryRows = [self registryRows];
    return @{
        @"views": @[
            @{@"id": @"clis", @"label": @"CLIs", @"symbol": @"square.stack.3d.up", @"rows": registryRows, @"columns": @[@"Name ·", @"Version", @"Via", @"Status"]},
            @{@"id": @"agents", @"label": @"Agents", @"symbol": @"sparkles", @"rows": @[], @"count": @7, @"columns": @[@"Name ·", @"Version", @"Via", @"Action"]},
            @{@"id": @"updates", @"label": @"Updates", @"symbol": @"arrow.down.circle", @"rows": [self updateRows], @"count": @11, @"columns": @[@"Name ·", @"Version", @"Via", @"Action"]},
            @{@"id": @"recent", @"label": @"Recent", @"symbol": @"clock", @"rows": @[], @"count": @3, @"columns": @[@"Name ·", @"Change", @"Via", @"When"]},
            @{@"id": @"all", @"label": @"All", @"symbol": @"list.bullet", @"rows": @[], @"count": @650, @"columns": @[@"Name ·", @"Version", @"Via", @"Status"]}
        ],
        @"terminals": @[@"Terminal", @"Ghostty", @"iTerm"],
        @"preferredTerminal": @"Ghostty",
        @"sources": @[@{@"label": @"path", @"count": @412}, @{@"label": @"brew", @"count": @186}, @{@"label": @"npm", @"count": @24}, @{@"label": @"cask", @"count": @18}, @{@"label": @"bun", @"count": @6}, @{@"label": @"uv", @"count": @4}],
        @"stats": @{@"current": @210, @"outdated": @11, @"unknown": @429},
        @"status": [panel.selectedViewId isEqualToString:@"clis"] ? @"npm · added 1 package in 3s" : @"11 outdated · scanned 4m ago"
    };
}

- (NSArray *)tickerPanel:(TickerPanelController *)panel rowsMatching:(NSString *)query { return @[]; }
- (void)tickerPanel:(TickerPanelController *)panel activateRow:(NSDictionary *)row {}
- (void)tickerPanel:(TickerPanelController *)panel pressButtonOnRow:(NSDictionary *)row {}
- (void)tickerPanel:(TickerPanelController *)panel copyRow:(NSDictionary *)row {}
- (void)tickerPanel:(TickerPanelController *)panel performCommand:(NSString *)command {}
- (void)tickerPanel:(TickerPanelController *)panel selectTerminal:(NSString *)terminal {}

@end

static void DrawBackdrop(NSRect rect) {
    NSGradient *gradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithSRGBRed:0.36 green:0.40 blue:0.48 alpha:1],
        [NSColor colorWithSRGBRed:0.22 green:0.25 blue:0.32 alpha:1],
        [NSColor colorWithSRGBRed:0.13 green:0.15 blue:0.20 alpha:1]
    ]];
    [gradient drawInRect:rect angle:-90];
}

BOOL WritePanelPreviewPNG(NSBitmapImageRep *panelBitmap, NSString *path, BOOL withMenuBar) {
    const CGFloat scale = 2;
    const CGFloat margin = 36;
    const CGFloat menuBarHeight = withMenuBar ? 26 : 0;
    NSSize panelSize = TickerPanelSize;
    NSSize canvas = NSMakeSize(panelSize.width + margin * 2, panelSize.height + margin * 2 + menuBarHeight);

    NSBitmapImageRep *output = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:(NSInteger)(canvas.width * scale)
                                                                       pixelsHigh:(NSInteger)(canvas.height * scale)
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSDeviceRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    output.size = canvas;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:output];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    NSRect bounds = NSMakeRect(0, 0, canvas.width, canvas.height);
    DrawBackdrop(bounds);

    NSRect panelRect = NSMakeRect(margin, margin, panelSize.width, panelSize.height);
    if (withMenuBar) {
        NSRect bar = NSMakeRect(0, canvas.height - menuBarHeight, canvas.width, menuBarHeight);
        [[NSColor colorWithSRGBRed:0.10 green:0.12 blue:0.16 alpha:0.72] setFill];
        NSRectFillUsingOperation(bar, NSCompositingOperationSourceOver);

        NSDictionary *clockAttributes = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.88 alpha:1]};
        NSString *clock = @"Mon 28 Sep  02:14";
        NSSize clockSize = [clock sizeWithAttributes:clockAttributes];
        [clock drawAtPoint:NSMakePoint(canvas.width - clockSize.width - 14, NSMinY(bar) + (menuBarHeight - clockSize.height) / 2) withAttributes:clockAttributes];

        CGFloat iconX = canvas.width - clockSize.width - 14 - 44;
        NSRect highlight = NSMakeRect(iconX - 6, NSMinY(bar) + 3, 30, menuBarHeight - 6);
        [[NSColor colorWithWhite:1 alpha:0.16] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:highlight xRadius:4 yRadius:4] fill];
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"CLIStatusTemplate" ofType:@"png"];
        NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
        if (icon) {
            NSImage *white = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
                [icon drawInRect:rect];
                [[NSColor colorWithWhite:0.95 alpha:1] set];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
                return YES;
            }];
            [white drawInRect:NSMakeRect(iconX, NSMinY(bar) + 4, 18, 18)];
        }
        CGFloat panelX = MIN(canvas.width - panelSize.width - 6, NSMidX(highlight) - panelSize.width / 2);
        panelRect = NSMakeRect(panelX, NSMinY(bar) - 4 - panelSize.height, panelSize.width, panelSize.height);
    }

    [panelBitmap drawInRect:panelRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];

    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [output representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

BOOL RenderPanelPreviewsIfRequested(void) {
    NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
    NSUInteger flag = [arguments indexOfObject:@"--render-previews"];
    if (flag == NSNotFound || flag + 1 >= arguments.count) return NO;
    NSString *directory = arguments[flag + 1];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    PanelPreviewSource *source = [[PanelPreviewSource alloc] init];
    NSString *registryPath = [[NSBundle mainBundle] pathForResource:@"registry" ofType:@"json" inDirectory:@"CLIRegistry"];
    NSString *iconDirectory = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"CLIRegistry/icons"];
    source.registry = [[CLIRegistryService alloc] initWithRegistryURL:[NSURL fileURLWithPath:registryPath ?: @""] iconDirectory:iconDirectory cacheDirectory:[NSURL fileURLWithPath:NSTemporaryDirectory()]];

    TickerPanelController *panel = [[TickerPanelController alloc] init];
    panel.delegate = source;

    panel.selectedViewId = @"updates";
    BOOL menuBarOK = WritePanelPreviewPNG([panel renderContentBitmap], [directory stringByAppendingPathComponent:@"menubar-preview.png"], YES);
    panel.selectedViewId = @"clis";
    BOOL listOK = WritePanelPreviewPNG([panel renderContentBitmap], [directory stringByAppendingPathComponent:@"cli-list-preview.png"], NO);

    fprintf(stderr, "menubar-preview: %s, cli-list-preview: %s\n", menuBarOK ? "ok" : "failed", listOK ? "ok" : "failed");
    exit(menuBarOK && listOK ? 0 : 1);
    return YES;
}
