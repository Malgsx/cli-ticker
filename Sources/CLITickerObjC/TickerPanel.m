#import "TickerPanel.h"

NSString *const TickerCommandRefresh = @"refresh";
NSString *const TickerCommandUpdateAll = @"updateAll";
NSString *const TickerCommandJSONReport = @"jsonReport";
NSString *const TickerCommandMarkdownReport = @"markdownReport";
NSString *const TickerCommandClassicMenu = @"classicMenu";
NSString *const TickerCommandQuit = @"quit";

const NSSize TickerPanelSize = {600, 420};

static const CGFloat ToolbarHeight = 28;
static const CGFloat FooterHeight = 22;
static const CGFloat SidebarWidth = 156;
static const CGFloat HeaderHeight = 20;
static const CGFloat RowHeight = 22;
static const CGFloat StatusColumnWidth = 88;
static const CGFloat ViaColumnWidth = 46;
static const CGFloat VersionColumnWidth = 124;

#pragma mark - Palette

static NSColor *RGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

static NSColor *PanelBackground(void) { return RGBA(0.149, 0.176, 0.220, 0.90); }
static NSColor *SidebarBackground(void) { return RGBA(0.110, 0.133, 0.169, 0.45); }
static NSColor *BorderColor(void) { return RGBA(0.78, 0.81, 0.86, 0.42); }
static NSColor *DividerColor(void) { return RGBA(1, 1, 1, 0.07); }
static NSColor *TextPrimary(void) { return RGBA(0.80, 0.83, 0.87, 1); }
static NSColor *TextBright(void) { return RGBA(0.92, 0.93, 0.95, 1); }
static NSColor *TextSecondary(void) { return RGBA(0.55, 0.59, 0.65, 1); }
static NSColor *TextDim(void) { return RGBA(0.42, 0.46, 0.52, 1); }
static NSColor *SelectedBackground(void) { return RGBA(1, 1, 1, 0.075); }
static NSColor *HoverBackground(void) { return RGBA(1, 1, 1, 0.035); }
static NSColor *SuccessColor(void) { return RGBA(0.58, 0.74, 0.60, 1); }
static NSColor *FailureColor(void) { return RGBA(0.84, 0.54, 0.52, 1); }
static NSColor *BarColor(void) { return RGBA(0.80, 0.83, 0.87, 0.85); }
static NSColor *BarTrackColor(void) { return RGBA(1, 1, 1, 0.06); }

static NSFont *TickerFont(CGFloat size, NSFontWeight weight) {
    NSArray<NSString *> *names = weight >= NSFontWeightSemibold
        ? @[@"JetBrainsMonoNerdFont-Bold", @"JetBrainsMono-Bold"]
        : @[@"JetBrainsMonoNerdFont-Regular", @"JetBrainsMono-Regular"];
    for (NSString *name in names) {
        NSFont *font = [NSFont fontWithName:name size:size];
        if (font) return font;
    }
    return [NSFont monospacedSystemFontOfSize:size weight:weight];
}

static NSTextField *TickerLabel(NSString *text, NSFont *font, NSColor *color, NSTextAlignment alignment) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = font;
    label.textColor = color;
    label.alignment = alignment;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.drawsBackground = NO;
    label.bezeled = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

static NSAttributedString *SectionTitle(NSString *text) {
    return [[NSAttributedString alloc] initWithString:text.uppercaseString attributes:@{
        NSFontAttributeName: TickerFont(9, NSFontWeightRegular),
        NSForegroundColorAttributeName: TextDim(),
        NSKernAttributeName: @1.2
    }];
}

static NSImage *SymbolImage(NSString *name, CGFloat pointSize) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightRegular];
    return [image imageWithSymbolConfiguration:config] ?: image;
}

NSImage *TickerMonogramIcon(NSString *mark) {
    NSString *text = mark.length > 0 ? [mark substringToIndex:MIN((NSUInteger)2, mark.length)].uppercaseString : @"?";
    NSImage *image = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor blackColor] set];
        NSBezierPath *frame = [NSBezierPath bezierPathWithRect:NSInsetRect(rect, 1, 1)];
        frame.lineWidth = 1;
        [frame stroke];
        NSDictionary *attributes = @{
            NSFontAttributeName: TickerFont(text.length > 1 ? 6.5 : 8.5, NSFontWeightSemibold),
            NSForegroundColorAttributeName: [NSColor blackColor]
        };
        NSSize size = [text sizeWithAttributes:attributes];
        [text drawAtPoint:NSMakePoint((16 - size.width) / 2.0, (16 - size.height) / 2.0) withAttributes:attributes];
        return YES;
    }];
    image.template = YES;
    return image;
}

#pragma mark - Views

@interface TickerFlippedView : NSView
@property NSColor *fillColor;
@property NSColor *strokeColor;
@end

@implementation TickerFlippedView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    if (self.fillColor) {
        [self.fillColor setFill];
        NSRectFillUsingOperation(dirtyRect, NSCompositingOperationSourceOver);
    }
    if (self.strokeColor) {
        // Drawn rather than a layer border so cacheDisplayInRect previews include it.
        [self.strokeColor setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)];
        border.lineWidth = 1;
        [border stroke];
    }
}
@end

@interface TickerBorderView : TickerFlippedView
@end

@implementation TickerBorderView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface TickerDivider : NSView
@end

@implementation TickerDivider
- (void)drawRect:(NSRect)dirtyRect {
    [DividerColor() setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}
@end

@interface TickerKeyPanel : NSPanel
@property (copy) void (^cancelHandler)(void);
// ⌘-shortcuts; the app has no main menu while the accessory panel is key.
@property (copy) BOOL (^commandKeyHandler)(NSString *characters);
@end

@implementation TickerKeyPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (flags == NSEventModifierFlagCommand && self.commandKeyHandler && self.commandKeyHandler(event.charactersIgnoringModifiers.lowercaseString)) return YES;
    return [super performKeyEquivalent:event];
}
- (void)cancelOperation:(id)sender {
    if (self.cancelHandler) self.cancelHandler();
}
@end

// Sidebar row: label on the left, count right-aligned, subtle highlight when selected.
@interface TickerSidebarRow : NSView
@property (weak) id target;
@property SEL action;
@property NSString *label;
@property NSString *count;
@property NSImage *symbol;
@property BOOL selected;
@property BOOL hovering;
@property id representedObject;
@end

@implementation TickerSidebarRow
- (BOOL)isFlipped { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds) && self.action) [NSApp sendAction:self.action to:self.target from:self];
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.selected || self.hovering) {
        [(self.selected ? SelectedBackground() : HoverBackground()) setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
    if (self.selected) {
        [BorderColor() setFill];
        NSRectFillUsingOperation(NSMakeRect(0, 0, 1, NSHeight(self.bounds)), NSCompositingOperationSourceOver);
    }

    NSColor *color = self.selected ? TextBright() : TextPrimary();
    CGFloat textX = 12;
    if (self.symbol) {
        NSImage *tinted = [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [self.symbol drawInRect:rect];
            [TextSecondary() set];
            NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop);
            return YES;
        }];
        [tinted drawInRect:NSMakeRect(12, (NSHeight(self.bounds) - 12) / 2.0, 12, 12) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        textX = 30;
    }
    NSDictionary *attributes = @{NSFontAttributeName: TickerFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: color};
    NSSize size = [self.label sizeWithAttributes:attributes];
    [self.label drawAtPoint:NSMakePoint(textX, (NSHeight(self.bounds) - size.height) / 2.0) withAttributes:attributes];

    if (self.count.length > 0) {
        NSDictionary *countAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
        NSSize countSize = [self.count sizeWithAttributes:countAttributes];
        [self.count drawAtPoint:NSMakePoint(NSWidth(self.bounds) - countSize.width - 10, (NSHeight(self.bounds) - countSize.height) / 2.0) withAttributes:countAttributes];
    }
}
@end

// Horizontal bars: "label ▮▮▮▮▯▯ count" per entry.
@interface TickerBarsView : NSView
@property NSArray<NSDictionary *> *entries;
@end

@implementation TickerBarsView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSInteger maxCount = 1;
    for (NSDictionary *entry in self.entries) maxCount = MAX(maxCount, [entry[@"count"] integerValue]);

    NSDictionary *labelAttributes = @{NSFontAttributeName: TickerFont(9.5, NSFontWeightRegular), NSForegroundColorAttributeName: TextSecondary()};
    NSDictionary *countAttributes = @{NSFontAttributeName: TickerFont(9.5, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    CGFloat y = 0;
    CGFloat barX = 64;
    CGFloat barWidth = NSWidth(self.bounds) - barX - 38;
    for (NSDictionary *entry in self.entries) {
        NSString *label = entry[@"label"] ?: @"";
        NSString *count = [entry[@"count"] description];
        [label drawAtPoint:NSMakePoint(12, y + 1) withAttributes:labelAttributes];

        // Segmented blocks echo the visualizer bars in the Omarchy reference.
        NSInteger segments = 12;
        CGFloat gap = 1.5;
        CGFloat segmentWidth = (barWidth - gap * (segments - 1)) / segments;
        NSInteger filled = (NSInteger)ceil((double)[entry[@"count"] integerValue] / maxCount * segments);
        for (NSInteger i = 0; i < segments; i++) {
            [(i < filled ? BarColor() : BarTrackColor()) setFill];
            NSRectFillUsingOperation(NSMakeRect(barX + i * (segmentWidth + gap), y + 4, segmentWidth, 7), NSCompositingOperationSourceOver);
        }
        NSSize countSize = [count sizeWithAttributes:countAttributes];
        [count drawAtPoint:NSMakePoint(NSWidth(self.bounds) - countSize.width - 10, y + 1) withAttributes:countAttributes];
        y += 15;
    }
}
@end

// Thin stacked bar for the footer: up to date / outdated / unknown.
@interface TickerStackedBar : NSView
@property NSArray<NSNumber *> *values;
@end

@implementation TickerStackedBar
- (void)drawRect:(NSRect)dirtyRect {
    [BarTrackColor() setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    double total = 0;
    for (NSNumber *value in self.values) total += value.doubleValue;
    if (total <= 0) return;
    NSArray<NSColor *> *colors = @[RGBA(0.80, 0.83, 0.87, 0.75), RGBA(0.92, 0.93, 0.95, 1), RGBA(0.55, 0.59, 0.65, 0.5)];
    CGFloat x = 0;
    for (NSUInteger i = 0; i < self.values.count && i < colors.count; i++) {
        CGFloat width = round(NSWidth(self.bounds) * self.values[i].doubleValue / total);
        [colors[i] setFill];
        NSRectFillUsingOperation(NSMakeRect(x, 0, width, NSHeight(self.bounds)), NSCompositingOperationSourceOver);
        x += width + (width > 0 ? 1 : 0);
    }
}
@end

// First-launch state drawn over the list: title, one line of context, and a checklist of
// install sources that ticks off as each scanner finishes.
@interface TickerScanView : TickerFlippedView
@property NSDictionary *state;
@end

@implementation TickerScanView
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGFloat x = 22;
    CGFloat width = NSWidth(self.bounds) - x * 2;
    NSArray<NSDictionary *> *steps = self.state[@"steps"];
    NSUInteger done = 0;
    for (NSDictionary *step in steps) if ([step[@"done"] boolValue]) done++;

    NSDictionary *titleAttributes = @{NSFontAttributeName: TickerFont(13, NSFontWeightSemibold), NSForegroundColorAttributeName: TextBright()};
    [self.state[@"title"] ?: @"" drawAtPoint:NSMakePoint(x, 30) withAttributes:titleAttributes];

    NSMutableParagraphStyle *wrap = [[NSMutableParagraphStyle alloc] init];
    wrap.lineBreakMode = NSLineBreakByWordWrapping;
    wrap.lineSpacing = 2;
    NSDictionary *detailAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextSecondary(), NSParagraphStyleAttributeName: wrap};
    [self.state[@"detail"] ?: @"" drawInRect:NSMakeRect(x, 54, width, 32) withAttributes:detailAttributes];

    NSInteger segments = 24;
    CGFloat gap = 2;
    CGFloat segmentWidth = (width - gap * (segments - 1)) / segments;
    NSInteger filled = steps.count > 0 ? (NSInteger)round((double)done / steps.count * segments) : 0;
    for (NSInteger i = 0; i < segments; i++) {
        [(i < filled ? BarColor() : BarTrackColor()) setFill];
        NSRectFillUsingOperation(NSMakeRect(x + i * (segmentWidth + gap), 96, segmentWidth, 6), NSCompositingOperationSourceOver);
    }

    NSDictionary *doneAttributes = @{NSFontAttributeName: TickerFont(10.5, NSFontWeightRegular), NSForegroundColorAttributeName: TextPrimary()};
    NSDictionary *pendingAttributes = @{NSFontAttributeName: TickerFont(10.5, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    NSDictionary *countAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    CGFloat columnWidth = (width - 16) / 2.0;
    NSUInteger perColumn = (steps.count + 1) / 2;
    for (NSUInteger i = 0; i < steps.count; i++) {
        NSDictionary *step = steps[i];
        BOOL isDone = [step[@"done"] boolValue];
        CGFloat columnX = x + (i < perColumn ? 0 : columnWidth + 16);
        CGFloat y = 116 + (i % MAX(perColumn, (NSUInteger)1)) * 19;
        NSString *line = [NSString stringWithFormat:@"%@ %@", isDone ? @"✓" : @"·", step[@"label"] ?: @""];
        [line drawAtPoint:NSMakePoint(columnX, y) withAttributes:isDone ? doneAttributes : pendingAttributes];
        NSString *count = isDone ? [step[@"count"] description] : @"…";
        if (count.length > 0) {
            NSSize size = [count sizeWithAttributes:countAttributes];
            [count drawAtPoint:NSMakePoint(columnX + columnWidth - size.width, y + 1) withAttributes:countAttributes];
        }
    }
}
@end

@interface TickerRowView : NSTableRowView
@property BOOL hovering;
@end

@implementation TickerRowView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event { self.hovering = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { self.hovering = NO; self.needsDisplay = YES; }
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (!self.hovering || self.selected) return;
    [HoverBackground() setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
}
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [SelectedBackground() setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    [BorderColor() setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, 1, NSHeight(self.bounds)), NSCompositingOperationSourceOver);
}
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }
@end

// Bordered text button matching the "[ V ] Exit" chips in the reference.
@interface TickerChipButton : NSButton
@end

@implementation TickerChipButton
- (void)drawRect:(NSRect)dirtyRect {
    NSRect frame = NSInsetRect(self.bounds, 0.5, 2.5);
    BOOL pressed = self.isHighlighted;
    [(pressed ? RGBA(1, 1, 1, 0.16) : RGBA(1, 1, 1, 0.06)) setFill];
    NSRectFillUsingOperation(frame, NSCompositingOperationSourceOver);
    [BorderColor() setStroke];
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:frame];
    path.lineWidth = 1;
    [path stroke];
    NSDictionary *attributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextBright()};
    NSSize size = [self.title sizeWithAttributes:attributes];
    [self.title drawAtPoint:NSMakePoint((NSWidth(self.bounds) - size.width) / 2.0, (NSHeight(self.bounds) - size.height) / 2.0) withAttributes:attributes];
}
- (BOOL)isFlipped { return YES; }
@end

@interface TickerCellView : NSTableCellView
@property NSImageView *iconView;
@property NSTextField *titleLabel;
@property NSTextField *detailLabel;
@property NSTextField *viaLabel;
@property NSTextField *metaLabel;
@property TickerChipButton *actionButton;
@property NSProgressIndicator *spinner;
@end

@implementation TickerCellView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.iconView = [[NSImageView alloc] init];
    self.iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.titleLabel = TickerLabel(@"", TickerFont(11, NSFontWeightRegular), TextPrimary(), NSTextAlignmentLeft);
    self.detailLabel = TickerLabel(@"", TickerFont(10, NSFontWeightRegular), TextSecondary(), NSTextAlignmentRight);
    self.viaLabel = TickerLabel(@"", TickerFont(10, NSFontWeightRegular), TextDim(), NSTextAlignmentRight);
    self.metaLabel = TickerLabel(@"", TickerFont(10, NSFontWeightRegular), TextDim(), NSTextAlignmentRight);
    self.actionButton = [[TickerChipButton alloc] init];
    self.actionButton.bordered = NO;
    self.actionButton.hidden = YES;
    self.spinner = [[NSProgressIndicator alloc] init];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSView *view in @[self.iconView, self.titleLabel, self.detailLabel, self.viaLabel, self.metaLabel, self.actionButton, self.spinner]) {
        [self addSubview:view];
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat textY = (height - 15) / 2.0;
    self.iconView.frame = NSMakeRect(10, (height - 14) / 2.0, 14, 14);
    CGFloat statusX = width - StatusColumnWidth - 8;
    CGFloat viaX = statusX - ViaColumnWidth - 4;
    CGFloat versionX = viaX - VersionColumnWidth - 4;
    self.titleLabel.frame = NSMakeRect(32, textY, versionX - 36, 15);
    self.detailLabel.frame = NSMakeRect(versionX, textY, VersionColumnWidth, 15);
    self.viaLabel.frame = NSMakeRect(viaX, textY, ViaColumnWidth, 15);
    self.metaLabel.frame = NSMakeRect(statusX, textY, StatusColumnWidth, 15);
    self.actionButton.frame = NSMakeRect(statusX + 8, 0, StatusColumnWidth - 8, height);
    self.spinner.frame = NSMakeRect(statusX + 6, (height - 12) / 2.0, 12, 12);
}

@end

#pragma mark - Controller

@interface TickerPanelController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate>
@property (readwrite) NSPanel *panel;
@property NSDictionary *snapshot;
@property NSArray<NSDictionary *> *rows;
@property TickerFlippedView *root;
@property TickerFlippedView *sidebar;
@property NSTextField *pathLabel;
@property NSTextField *searchField;
@property NSTextField *headerTitle;
@property NSTextField *headerVersion;
@property NSTextField *headerVia;
@property NSTextField *headerStatus;
@property NSTableView *tableView;
@property NSTextField *footerLeft;
@property NSTextField *footerRight;
@property TickerStackedBar *footerBar;
@property TickerScanView *scanView;
@property id globalMonitor;
@property NSDate *lastResignDate;
@property (weak) NSStatusBarButton *statusButton;
@end

@implementation TickerPanelController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.selectedViewId = @"clis";
    [self buildPanel];
    return self;
}

- (void)buildPanel {
    NSRect frame = NSMakeRect(0, 0, TickerPanelSize.width, TickerPanelSize.height);
    TickerKeyPanel *panel = [[TickerKeyPanel alloc] initWithContentRect:frame
                                                              styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                                backing:NSBackingStoreBuffered
                                                                  defer:YES];
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;
    panel.level = NSStatusWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.delegate = self;
    __weak typeof(self) weakSelf = self;
    panel.cancelHandler = ^{ [weakSelf close]; };
    panel.commandKeyHandler = ^BOOL(NSString *characters) { return [weakSelf handleCommandKey:characters]; };
    self.panel = panel;

    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:frame];
    blur.material = NSVisualEffectMaterialHUDWindow;
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.state = NSVisualEffectStateActive;
    blur.wantsLayer = YES;
    blur.layer.cornerRadius = 0;
    panel.contentView = blur;

    TickerFlippedView *root = [[TickerFlippedView alloc] initWithFrame:frame];
    root.fillColor = PanelBackground();
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [blur addSubview:root];
    self.root = root;

    [self buildToolbar];
    [self buildSidebar];
    [self buildList];
    [self buildFooter];

    TickerBorderView *border = [[TickerBorderView alloc] initWithFrame:frame];
    border.strokeColor = BorderColor();
    border.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:border];
}

- (NSButton *)toolbarButton:(NSString *)symbol tooltip:(NSString *)tooltip action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:SymbolImage(symbol, 11) target:self action:action];
    button.bordered = NO;
    button.contentTintColor = TextSecondary();
    button.toolTip = tooltip;
    return button;
}

- (void)buildToolbar {
    CGFloat width = TickerPanelSize.width;
    NSImageView *prompt = [NSImageView imageViewWithImage:SymbolImage(@"chevron.right", 9)];
    prompt.contentTintColor = TextDim();
    prompt.frame = NSMakeRect(12, 8, 10, 12);
    [self.root addSubview:prompt];

    self.pathLabel = TickerLabel(@"~/cli", TickerFont(11, NSFontWeightRegular), TextSecondary(), NSTextAlignmentLeft);
    self.pathLabel.frame = NSMakeRect(28, 6, 220, 16);
    [self.root addSubview:self.pathLabel];

    TickerFlippedView *searchBox = [[TickerFlippedView alloc] initWithFrame:NSMakeRect(250, 5, 176, 18)];
    searchBox.fillColor = RGBA(0, 0, 0, 0.20);
    searchBox.strokeColor = DividerColor();
    [self.root addSubview:searchBox];
    NSImageView *glass = [NSImageView imageViewWithImage:SymbolImage(@"magnifyingglass", 9)];
    glass.contentTintColor = TextDim();
    glass.frame = NSMakeRect(6, 3, 11, 12);
    [searchBox addSubview:glass];

    self.searchField = [[NSTextField alloc] initWithFrame:NSMakeRect(21, 2, 150, 14)];
    self.searchField.font = TickerFont(10.5, NSFontWeightRegular);
    self.searchField.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"search clis" attributes:@{
        NSFontAttributeName: TickerFont(10.5, NSFontWeightRegular),
        NSForegroundColorAttributeName: TextDim()
    }];
    self.searchField.focusRingType = NSFocusRingTypeNone;
    self.searchField.bezeled = NO;
    self.searchField.bordered = NO;
    self.searchField.drawsBackground = NO;
    self.searchField.textColor = TextPrimary();
    self.searchField.cell.scrollable = YES;
    self.searchField.cell.usesSingleLineMode = YES;
    self.searchField.delegate = self;
    [searchBox addSubview:self.searchField];

    NSArray *buttons = @[
        [self toolbarButton:@"arrow.clockwise" tooltip:@"Rescan this Mac for CLIs and agents (⌘R)" action:@selector(refreshPressed:)],
        [self toolbarButton:@"arrow.down.to.line" tooltip:@"Update all supported tools" action:@selector(updateAllPressed:)],
        [self toolbarButton:@"doc.text" tooltip:@"Open Markdown report" action:@selector(markdownPressed:)],
        [self toolbarButton:@"curlybraces" tooltip:@"Open JSON report" action:@selector(jsonPressed:)],
        [self toolbarButton:@"line.3.horizontal" tooltip:@"Classic menu (right-click the menu bar icon)" action:@selector(classicMenuPressed:)],
        [self toolbarButton:@"power" tooltip:@"Quit" action:@selector(quitPressed:)]
    ];
    CGFloat x = width - 12 - 18 * buttons.count - 4 * (buttons.count - 1);
    for (NSButton *button in buttons) {
        button.frame = NSMakeRect(x, 5, 18, 18);
        [self.root addSubview:button];
        x += 22;
    }

    TickerDivider *divider = [[TickerDivider alloc] initWithFrame:NSMakeRect(0, ToolbarHeight - 1, width, 1)];
    [self.root addSubview:divider];
}

- (void)buildSidebar {
    self.sidebar = [[TickerFlippedView alloc] initWithFrame:NSMakeRect(1, ToolbarHeight, SidebarWidth, TickerPanelSize.height - ToolbarHeight - FooterHeight)];
    self.sidebar.fillColor = SidebarBackground();
    [self.root addSubview:self.sidebar];
    TickerDivider *divider = [[TickerDivider alloc] initWithFrame:NSMakeRect(SidebarWidth, ToolbarHeight, 1, TickerPanelSize.height - ToolbarHeight - FooterHeight)];
    [self.root addSubview:divider];
}

- (void)buildList {
    CGFloat x = SidebarWidth + 1;
    CGFloat width = TickerPanelSize.width - x - 1;
    CGFloat statusX = width - StatusColumnWidth - 8;
    CGFloat viaX = statusX - ViaColumnWidth - 4;
    CGFloat versionX = viaX - VersionColumnWidth - 4;

    TickerFlippedView *header = [[TickerFlippedView alloc] initWithFrame:NSMakeRect(x, ToolbarHeight, width, HeaderHeight)];
    header.fillColor = RGBA(0, 0, 0, 0.08);
    NSFont *headerFont = TickerFont(9.5, NSFontWeightRegular);
    self.headerTitle = TickerLabel(@"Name ·", headerFont, TextDim(), NSTextAlignmentLeft);
    self.headerTitle.frame = NSMakeRect(32, 3, versionX - 36, 14);
    self.headerVersion = TickerLabel(@"Version", headerFont, TextDim(), NSTextAlignmentRight);
    self.headerVersion.frame = NSMakeRect(versionX, 3, VersionColumnWidth, 14);
    self.headerVia = TickerLabel(@"Via", headerFont, TextDim(), NSTextAlignmentRight);
    self.headerVia.frame = NSMakeRect(viaX, 3, ViaColumnWidth, 14);
    self.headerStatus = TickerLabel(@"Status", headerFont, TextDim(), NSTextAlignmentRight);
    self.headerStatus.frame = NSMakeRect(statusX, 3, StatusColumnWidth, 14);
    for (NSView *view in @[self.headerTitle, self.headerVersion, self.headerVia, self.headerStatus]) [header addSubview:view];
    [self.root addSubview:header];

    CGFloat listY = ToolbarHeight + HeaderHeight;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(x, listY, width, TickerPanelSize.height - listY - FooterHeight)];
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.scrollerStyle = NSScrollerStyleOverlay;
    scrollView.scrollerKnobStyle = NSScrollerKnobStyleLight;
    scrollView.automaticallyAdjustsContentInsets = NO;

    NSTableView *table = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"row"];
    column.width = width;
    [table addTableColumn:column];
    table.headerView = nil;
    table.backgroundColor = [NSColor clearColor];
    table.rowHeight = RowHeight;
    table.intercellSpacing = NSMakeSize(0, 0);
    table.gridStyleMask = NSTableViewGridNone;
    table.focusRingType = NSFocusRingTypeNone;
    table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    if (@available(macOS 11.0, *)) table.style = NSTableViewStyleFullWidth;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.action = @selector(rowClicked:);
    table.menu = [[NSMenu alloc] initWithTitle:@"Row"];
    table.menu.delegate = (id<NSMenuDelegate>)self;
    scrollView.documentView = table;
    [self.root addSubview:scrollView];
    self.tableView = table;

    self.scanView = [[TickerScanView alloc] initWithFrame:NSMakeRect(x, ToolbarHeight, width, TickerPanelSize.height - ToolbarHeight - FooterHeight)];
    self.scanView.fillColor = RGBA(0.149, 0.176, 0.220, 1);
    self.scanView.hidden = YES;
    [self.root addSubview:self.scanView];
}

- (void)buildFooter {
    CGFloat width = TickerPanelSize.width;
    CGFloat y = TickerPanelSize.height - FooterHeight;
    TickerDivider *divider = [[TickerDivider alloc] initWithFrame:NSMakeRect(0, y, width, 1)];
    [self.root addSubview:divider];

    self.footerLeft = TickerLabel(@"", TickerFont(10, NSFontWeightRegular), TextSecondary(), NSTextAlignmentLeft);
    self.footerLeft.frame = NSMakeRect(12, y + 4, 150, 14);
    [self.root addSubview:self.footerLeft];

    self.footerBar = [[TickerStackedBar alloc] initWithFrame:NSMakeRect(SidebarWidth + 12, y + 9, 90, 4)];
    [self.root addSubview:self.footerBar];

    self.footerRight = TickerLabel(@"", TickerFont(10, NSFontWeightRegular), TextSecondary(), NSTextAlignmentRight);
    self.footerRight.frame = NSMakeRect(SidebarWidth + 110, y + 4, width - SidebarWidth - 122, 14);
    [self.root addSubview:self.footerRight];
}

#pragma mark Data

- (NSArray<NSDictionary *> *)views {
    NSArray *views = self.snapshot[@"views"];
    return [views isKindOfClass:[NSArray class]] ? views : @[];
}

- (NSDictionary *)selectedView {
    for (NSDictionary *view in [self views]) {
        if ([view[@"id"] isEqualToString:self.selectedViewId]) return view;
    }
    return [self views].firstObject;
}

- (BOOL)isSearching {
    return [self.searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length > 0;
}

- (void)reload {
    self.snapshot = [self.delegate tickerPanelSnapshot:self] ?: @{};
    NSDictionary *view = [self selectedView];
    if (view) self.selectedViewId = view[@"id"];

    NSString *query = self.searchField.stringValue ?: @"";
    NSArray *rows = [self isSearching] ? [self.delegate tickerPanel:self rowsMatching:query] : view[@"rows"];
    NSInteger selected = self.tableView.selectedRow;
    self.rows = rows ?: @[];
    [self.tableView reloadData];
    if (self.rows.count > 0) {
        NSInteger row = selected >= 0 && selected < (NSInteger)self.rows.count ? selected : 0;
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }

    NSString *label = [self isSearching] ? [NSString stringWithFormat:@"search/%@", query] : [view[@"label"] lowercaseString];
    self.pathLabel.stringValue = [NSString stringWithFormat:@"~/cli/%@", label ?: @""];
    NSArray *columns = view[@"columns"];
    if ([self isSearching]) columns = @[@"Name ·", @"Version", @"Via", @"Source"];
    if (columns.count == 4) {
        self.headerTitle.stringValue = columns[0];
        self.headerVersion.stringValue = columns[1];
        self.headerVia.stringValue = columns[2];
        self.headerStatus.stringValue = columns[3];
    }

    NSDictionary *stats = self.snapshot[@"stats"];
    self.footerLeft.stringValue = [NSString stringWithFormat:@"%lu items", (unsigned long)self.rows.count];
    self.footerBar.values = @[stats[@"current"] ?: @0, stats[@"outdated"] ?: @0, stats[@"unknown"] ?: @0];
    self.footerBar.needsDisplay = YES;
    self.footerRight.stringValue = self.snapshot[@"status"] ?: @"";

    NSDictionary *scanning = self.snapshot[@"scanning"];
    self.scanView.state = [scanning isKindOfClass:[NSDictionary class]] ? scanning : nil;
    self.scanView.hidden = self.scanView.state == nil || [self isSearching];
    self.scanView.needsDisplay = YES;

    [self rebuildSidebar];
}

- (TickerSidebarRow *)sidebarRowWithLabel:(NSString *)label count:(NSString *)count y:(CGFloat)y {
    TickerSidebarRow *row = [[TickerSidebarRow alloc] initWithFrame:NSMakeRect(0, y, SidebarWidth, 20)];
    row.label = label;
    row.count = count;
    row.target = self;
    return row;
}

- (NSTextField *)sectionLabel:(NSString *)title y:(CGFloat)y {
    NSTextField *label = [NSTextField labelWithAttributedString:SectionTitle(title)];
    label.frame = NSMakeRect(12, y, SidebarWidth - 24, 14);
    return label;
}

- (void)rebuildSidebar {
    for (NSView *view in [self.sidebar.subviews copy]) [view removeFromSuperview];
    CGFloat y = 10;

    [self.sidebar addSubview:[self sectionLabel:@"Views" y:y]];
    y += 18;
    for (NSDictionary *view in [self views]) {
        NSArray *rows = view[@"rows"];
        NSString *count = view[@"count"] ? [view[@"count"] description] : [NSString stringWithFormat:@"%lu", (unsigned long)rows.count];
        TickerSidebarRow *row = [self sidebarRowWithLabel:view[@"label"] count:count y:y];
        row.symbol = SymbolImage(view[@"symbol"] ?: @"folder", 10);
        row.selected = ![self isSearching] && [view[@"id"] isEqualToString:self.selectedViewId];
        row.representedObject = view[@"id"];
        row.action = @selector(viewSelected:);
        [self.sidebar addSubview:row];
        y += 20;
    }

    NSArray *terminals = self.snapshot[@"terminals"];
    if (terminals.count > 0) {
        y += 10;
        [self.sidebar addSubview:[self sectionLabel:@"Terminal" y:y]];
        y += 18;
        for (NSString *terminal in terminals) {
            TickerSidebarRow *row = [self sidebarRowWithLabel:terminal count:nil y:y];
            row.symbol = SymbolImage(@"terminal", 10);
            row.selected = [terminal isEqualToString:self.snapshot[@"preferredTerminal"]];
            row.representedObject = terminal;
            row.action = @selector(terminalSelected:);
            [self.sidebar addSubview:row];
            y += 20;
        }
    }

    NSArray *sources = self.snapshot[@"sources"];
    if (sources.count > 0) {
        y += 10;
        [self.sidebar addSubview:[self sectionLabel:@"Sources" y:y]];
        y += 18;
        CGFloat available = NSHeight(self.sidebar.bounds) - y - 6;
        NSUInteger visible = MIN(sources.count, (NSUInteger)MAX(0, floor(available / 15)));
        TickerBarsView *bars = [[TickerBarsView alloc] initWithFrame:NSMakeRect(0, y, SidebarWidth, visible * 15)];
        bars.entries = [sources subarrayWithRange:NSMakeRange(0, visible)];
        [self.sidebar addSubview:bars];
    }
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.rows.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[TickerRowView alloc] init];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    TickerCellView *cell = [tableView makeViewWithIdentifier:@"TickerCell" owner:self];
    if (!cell) {
        cell = [[TickerCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, RowHeight)];
        cell.identifier = @"TickerCell";
        cell.actionButton.target = self;
        cell.actionButton.action = @selector(rowButtonPressed:);
    }
    NSDictionary *data = self.rows[row];
    [self configureCell:cell withRow:data];
    return cell;
}

- (void)configureCell:(TickerCellView *)cell withRow:(NSDictionary *)row {
    NSImage *icon = row[@"icon"];
    cell.iconView.image = icon;
    cell.iconView.contentTintColor = TextSecondary();
    cell.iconView.alphaValue = icon.isTemplate ? 1.0 : 0.85;
    cell.titleLabel.stringValue = row[@"title"] ?: @"";
    cell.titleLabel.textColor = TextPrimary();
    cell.detailLabel.stringValue = row[@"detail"] ?: @"";
    cell.detailLabel.textColor = [row[@"emphasis"] boolValue] ? TextBright() : TextSecondary();
    cell.viaLabel.stringValue = row[@"via"] ?: @"";
    cell.metaLabel.stringValue = row[@"meta"] ?: @"";
    cell.metaLabel.textColor = TextDim();
    cell.actionButton.hidden = YES;
    cell.metaLabel.hidden = NO;
    [cell.spinner stopAnimation:nil];
    cell.toolTip = row[@"tooltip"];

    if ([row[@"kind"] isEqualToString:@"registry"]) [self configureRegistryCell:cell withRow:row];
}

- (void)configureRegistryCell:(TickerCellView *)cell withRow:(NSDictionary *)row {
    NSString *updateState = row[@"updateState"];
    NSString *state = row[@"state"];
    cell.metaLabel.alignment = NSTextAlignmentRight;

    if ([updateState isEqualToString:@"running"]) {
        [cell.spinner startAnimation:nil];
        cell.metaLabel.stringValue = @"updating";
        cell.metaLabel.textColor = TextPrimary();
        return;
    }
    if ([updateState isEqualToString:@"succeeded"]) {
        cell.metaLabel.stringValue = @"✓ updated";
        cell.metaLabel.textColor = SuccessColor();
        return;
    }
    if ([updateState isEqualToString:@"queued"]) {
        cell.metaLabel.stringValue = @"queued";
        cell.metaLabel.textColor = TextSecondary();
        return;
    }
    if ([updateState isEqualToString:@"failed"]) {
        cell.metaLabel.hidden = YES;
        cell.actionButton.hidden = NO;
        cell.actionButton.title = @"✗ retry";
        cell.actionButton.toolTip = [NSString stringWithFormat:@"Update failed: %@", row[@"tooltip"] ?: @""];
        return;
    }
    if ([state isEqualToString:@"outdated"]) {
        if ([row[@"updateCommand"] length] > 0) {
            cell.metaLabel.hidden = YES;
            cell.actionButton.hidden = NO;
            cell.actionButton.title = @"↑ update";
            cell.actionButton.toolTip = [NSString stringWithFormat:@"Run: %@", row[@"updateCommand"]];
        } else {
            cell.metaLabel.stringValue = @"manual";
            cell.metaLabel.textColor = TextSecondary();
        }
        return;
    }
    if ([state isEqualToString:@"current"]) {
        cell.metaLabel.stringValue = @"up to date";
    } else if ([state isEqualToString:@"system"]) {
        cell.metaLabel.stringValue = @"system";
    } else if ([state isEqualToString:@"checking"]) {
        cell.metaLabel.stringValue = @"checking…";
    } else {
        cell.metaLabel.stringValue = @"—";
    }
}

- (NSDictionary *)rowAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.rows.count) return nil;
    return self.rows[index];
}

- (void)rowClicked:(NSTableView *)sender {
    NSDictionary *row = [self rowAtIndex:sender.clickedRow];
    if (!row) return;
    [self.delegate tickerPanel:self activateRow:row];
}

// Reused cell views can outlive a reload that reorders rows, so resolve the row at press time.
- (void)rowButtonPressed:(NSButton *)sender {
    NSDictionary *row = [self rowAtIndex:[self.tableView rowForView:sender]];
    if (!row) return;
    [self.delegate tickerPanel:self pressButtonOnRow:row];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSDictionary *row = [self rowAtIndex:self.tableView.clickedRow];
    if (!row) return;
    NSMenuItem *open = [menu addItemWithTitle:[row[@"kind"] isEqualToString:@"update"] ? @"Update…" : @"Open in Terminal" action:@selector(contextActivate:) keyEquivalent:@""];
    open.target = self;
    NSMenuItem *copy = [menu addItemWithTitle:@"Copy Command" action:@selector(contextCopy:) keyEquivalent:@""];
    copy.target = self;
}

- (void)contextActivate:(id)sender {
    NSDictionary *row = [self rowAtIndex:self.tableView.clickedRow];
    if (row) [self.delegate tickerPanel:self activateRow:row];
}

- (void)contextCopy:(id)sender {
    NSDictionary *row = [self rowAtIndex:self.tableView.clickedRow];
    if (row) [self.delegate tickerPanel:self copyRow:row];
}

#pragma mark Search

- (void)controlTextDidChange:(NSNotification *)notification {
    [self searchChanged:notification.object];
}

- (void)searchChanged:(id)sender {
    [self.tableView deselectAll:nil];
    [self reload];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    NSInteger selected = self.tableView.selectedRow;
    if (commandSelector == @selector(moveDown:) || commandSelector == @selector(moveUp:)) {
        NSInteger delta = commandSelector == @selector(moveDown:) ? 1 : -1;
        NSInteger next = MAX(0, MIN((NSInteger)self.rows.count - 1, selected + delta));
        if (self.rows.count > 0) {
            [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
            [self.tableView scrollRowToVisible:next];
        }
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        NSDictionary *row = [self rowAtIndex:selected];
        if (row) [self.delegate tickerPanel:self activateRow:row];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.searchField.stringValue.length > 0) {
            self.searchField.stringValue = @"";
            [self reload];
        } else {
            [self close];
        }
        return YES;
    }
    return NO;
}

#pragma mark Actions

- (void)viewSelected:(TickerSidebarRow *)sender {
    self.selectedViewId = sender.representedObject;
    self.searchField.stringValue = @"";
    [self.tableView deselectAll:nil];
    [self reload];
    [self.tableView scrollRowToVisible:0];
}

- (void)terminalSelected:(TickerSidebarRow *)sender {
    [self.delegate tickerPanel:self selectTerminal:sender.representedObject];
    [self reload];
}

- (BOOL)handleCommandKey:(NSString *)characters {
    if ([characters isEqualToString:@"r"]) { [self refreshPressed:nil]; return YES; }
    if ([characters isEqualToString:@"u"]) { [self updateAllPressed:nil]; return YES; }
    if ([characters isEqualToString:@"q"]) { [self quitPressed:nil]; return YES; }
    if ([characters isEqualToString:@"f"]) { [self.panel makeFirstResponder:self.searchField]; return YES; }
    return NO;
}

- (void)refreshPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandRefresh]; }
- (void)updateAllPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandUpdateAll]; }
- (void)markdownPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandMarkdownReport]; }
- (void)jsonPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandJSONReport]; }
- (void)classicMenuPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandClassicMenu]; }
- (void)quitPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandQuit]; }

#pragma mark Window

- (BOOL)isVisible {
    return self.panel.isVisible;
}

- (void)toggleRelativeToStatusButton:(NSStatusBarButton *)button {
    if (self.panel.isVisible) {
        [self close];
        return;
    }
    // Clicking the status item while open resigns key first; don't reopen on that same click.
    if (self.lastResignDate && -[self.lastResignDate timeIntervalSinceNow] < 0.25) return;
    [self showRelativeToStatusButton:button];
}

- (void)showRelativeToStatusButton:(NSStatusBarButton *)button {
    self.statusButton = button;
    [self reload];

    NSRect buttonRect = [button.window convertRectToScreen:[button convertRect:button.bounds toView:nil]];
    NSScreen *screen = button.window.screen ?: [NSScreen mainScreen];
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMidX(buttonRect) - TickerPanelSize.width / 2.0;
    x = MAX(NSMinX(visible) + 6, MIN(x, NSMaxX(visible) - TickerPanelSize.width - 6));
    CGFloat y = NSMinY(buttonRect) - TickerPanelSize.height - 4;
    [self.panel setFrame:NSMakeRect(x, y, TickerPanelSize.width, TickerPanelSize.height) display:YES];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel makeFirstResponder:self.searchField];
    button.highlighted = YES;

    if (!self.globalMonitor) {
        __weak typeof(self) weakSelf = self;
        self.globalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *event) {
            [weakSelf close];
        }];
    }
}

- (void)close {
    if (self.globalMonitor) {
        [NSEvent removeMonitor:self.globalMonitor];
        self.globalMonitor = nil;
    }
    [self.panel orderOut:nil];
    self.statusButton.highlighted = NO;
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (!self.panel.isVisible) return;
    self.lastResignDate = [NSDate date];
    [self close];
}

- (NSBitmapImageRep *)renderContentBitmap {
    [self reload];
    // Table rows are only materialized once the window is on screen, so order it in off-screen.
    [self.panel setFrame:NSMakeRect(-20000, -20000, TickerPanelSize.width, TickerPanelSize.height) display:NO];
    [self.panel orderFrontRegardless];
    [self.root layoutSubtreeIfNeeded];
    [self.tableView layoutSubtreeIfNeeded];
    [self.panel displayIfNeeded];
    NSBitmapImageRep *bitmap = [self.root bitmapImageRepForCachingDisplayInRect:self.root.bounds];
    [self.root cacheDisplayInRect:self.root.bounds toBitmapImageRep:bitmap];
    [self.panel orderOut:nil];
    return bitmap;
}

@end
