#import "TickerPanel.h"

NSString *const TickerCommandRefresh = @"refresh";
NSString *const TickerCommandUpdateAll = @"updateAll";
NSString *const TickerCommandJSONReport = @"jsonReport";
NSString *const TickerCommandMarkdownReport = @"markdownReport";
NSString *const TickerCommandSettings = @"settings";
NSString *const TickerCommandUpdateApp = @"updateApp";
NSString *const TickerCommandOpenGitHub = @"openGitHub";
NSString *const TickerCommandQuit = @"quit";
NSString *const TickerCommandSelect = @"select";

NSString *TickerSelectionKey(NSDictionary *row) {
    NSString *key = row[@"selectionKey"];
    return [key isKindOfClass:[NSString class]] && key.length > 0 ? key : nil;
}

BOOL TickerRowIsSelectable(NSDictionary *row) {
    NSDictionary *action = row[@"uninstallAction"];
    return TickerSelectionKey(row) != nil
        && [action[@"executable"] isKindOfClass:[NSString class]]
        && [action[@"arguments"] isKindOfClass:[NSArray class]];
}

void TickerSelectionClick(NSMutableOrderedSet<NSString *> *selected, NSArray<NSDictionary *> *rows, NSInteger index, BOOL extendRange, NSInteger *anchor) {
    if (index < 0 || index >= (NSInteger)rows.count || !TickerRowIsSelectable(rows[index])) return;
    if (extendRange && anchor && *anchor >= 0 && *anchor < (NSInteger)rows.count) {
        NSInteger lower = MIN(*anchor, index);
        NSInteger upper = MAX(*anchor, index);
        for (NSInteger i = lower; i <= upper; i++) {
            if (!TickerRowIsSelectable(rows[i])) continue;
            [selected addObject:TickerSelectionKey(rows[i])];
        }
        return;
    }
    NSString *key = TickerSelectionKey(rows[index]);
    if ([selected containsObject:key]) [selected removeObject:key];
    else [selected addObject:key];
    if (anchor) *anchor = index;
}

void TickerSelectionSelectAll(NSMutableOrderedSet<NSString *> *selected, NSArray<NSDictionary *> *rows) {
    for (NSDictionary *row in rows) {
        if (!TickerRowIsSelectable(row)) continue;
        [selected addObject:TickerSelectionKey(row)];
    }
}

void TickerSelectionClear(NSMutableOrderedSet<NSString *> *selected) {
    [selected removeAllObjects];
}

const NSSize TickerPanelSize = {600, 420};
const NSUInteger TickerUpdatePageSize = 10;

static const CGFloat ToolbarHeight = 28;
static const CGFloat FooterHeight = 22;
static const CGFloat SidebarWidth = 156;
static const CGFloat HeaderHeight = 20;
static const CGFloat RowHeight = 22;
static const CGFloat StatusColumnWidth = 88;
static const CGFloat ViaColumnWidth = 46;
static const CGFloat VersionColumnWidth = 124;
static const CGFloat MenuWidth = 320;
static const CGFloat MenuRowHeight = 22;
static const CGFloat MenuSeparatorHeight = 9;
static const CGFloat SettingsRowHeight = 26;

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
        // Offscreen caching can pass a dirty rect larger than the view without clipping to it.
        NSRectFillUsingOperation(NSIntersectionRect(dirtyRect, self.bounds), NSCompositingOperationSourceOver);
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

// Hamburger dropdown drawn inside the panel: compact monospace rows, a 1px border, the
// selected row marked like list selection. Hover selects; click or Return activates.
@interface TickerMenuView : TickerFlippedView
@property NSArray<NSDictionary *> *items;
@property NSInteger selectedIndex;
@property (copy) void (^activateHandler)(NSInteger index);
+ (CGFloat)heightForItems:(NSArray<NSDictionary *> *)items;
@end

@implementation TickerMenuView
+ (CGFloat)heightForItems:(NSArray<NSDictionary *> *)items {
    CGFloat height = 8;
    for (NSDictionary *item in items) height += MenuRowHeight + ([item[@"separator"] boolValue] ? MenuSeparatorHeight : 0);
    return height;
}

- (NSRect)rectForIndex:(NSInteger)index {
    CGFloat y = 4;
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        if ([self.items[i][@"separator"] boolValue]) y += MenuSeparatorHeight;
        if (i == index) return NSMakeRect(1, y, NSWidth(self.bounds) - 2, MenuRowHeight);
        y += MenuRowHeight;
    }
    return NSZeroRect;
}

- (NSInteger)indexAtPoint:(NSPoint)point {
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        if (NSPointInRect(point, [self rectForIndex:i])) return i;
    }
    return -1;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event {
    NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index >= 0 && index != self.selectedIndex) { self.selectedIndex = index; self.needsDisplay = YES; }
}
- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if (index >= 0 && self.activateHandler) self.activateHandler(index);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        NSDictionary *item = self.items[i];
        NSRect row = [self rectForIndex:i];
        if ([item[@"separator"] boolValue]) {
            [DividerColor() setFill];
            NSRectFillUsingOperation(NSMakeRect(8, NSMinY(row) - (MenuSeparatorHeight + 1) / 2.0, NSWidth(self.bounds) - 16, 1), NSCompositingOperationSourceOver);
        }
        BOOL selected = i == self.selectedIndex;
        if (selected) {
            [SelectedBackground() setFill];
            NSRectFillUsingOperation(row, NSCompositingOperationSourceOver);
            [BorderColor() setFill];
            NSRectFillUsingOperation(NSMakeRect(NSMinX(row), NSMinY(row), 1, NSHeight(row)), NSCompositingOperationSourceOver);
        }
        BOOL emphasis = [item[@"emphasis"] boolValue];
        NSDictionary *titleAttributes = @{NSFontAttributeName: TickerFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: selected || emphasis ? TextBright() : TextPrimary()};
        NSDictionary *dimAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
        NSDictionary *detailAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: emphasis ? TextBright() : TextSecondary()};
        NSString *title = item[@"title"] ?: @"";
        NSSize titleSize = [title sizeWithAttributes:titleAttributes];
        CGFloat textY = NSMinY(row) + (MenuRowHeight - titleSize.height) / 2.0;
        [title drawAtPoint:NSMakePoint(12, textY) withAttributes:titleAttributes];

        CGFloat right = NSWidth(self.bounds) - 10;
        NSString *shortcut = item[@"shortcut"];
        if (shortcut.length > 0) {
            NSSize size = [shortcut sizeWithAttributes:dimAttributes];
            [shortcut drawAtPoint:NSMakePoint(right - size.width, textY + 1) withAttributes:dimAttributes];
        }
        right -= 30;
        NSString *detail = item[@"detail"];
        if (detail.length > 0) {
            CGFloat available = right - (12 + titleSize.width + 12);
            NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
            style.alignment = NSTextAlignmentRight;
            style.lineBreakMode = NSLineBreakByTruncatingHead;
            NSMutableDictionary *attributes = [detailAttributes mutableCopy];
            attributes[NSParagraphStyleAttributeName] = style;
            [detail drawInRect:NSMakeRect(right - available, textY + 1, available, 14) withAttributes:attributes];
        }
    }
}
@end

// Catches clicks outside the open menu so they close it instead of reaching the list.
@interface TickerMenuBackdrop : NSView
@property (copy) void (^clickHandler)(void);
@end

@implementation TickerMenuBackdrop
- (void)mouseDown:(NSEvent *)event { if (self.clickHandler) self.clickHandler(); }
- (void)rightMouseDown:(NSEvent *)event { if (self.clickHandler) self.clickHandler(); }
@end

// Inline settings view: one row per setting with its value in a "‹ value ›" chip.
// ↑/↓ select, ←/→ or Return change, clicking a row steps it forward.
@interface TickerSettingsView : TickerFlippedView
@property NSArray<NSDictionary *> *settings;
@property NSInteger selectedIndex;
@property (copy) void (^changeHandler)(NSInteger index, NSInteger delta);
@end

@implementation TickerSettingsView
- (NSRect)rectForIndex:(NSInteger)index {
    return NSMakeRect(0, 44 + index * SettingsRowHeight, NSWidth(self.bounds), SettingsRowHeight);
}

- (void)mouseDown:(NSEvent *)event {}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSInteger i = 0; i < (NSInteger)self.settings.count; i++) {
        if (!NSPointInRect(point, [self rectForIndex:i])) continue;
        self.selectedIndex = i;
        BOOL leftHalfOfChip = point.x < NSWidth(self.bounds) - 22 - 80;
        if (self.changeHandler) self.changeHandler(i, leftHalfOfChip && point.x > NSWidth(self.bounds) - 22 - 160 ? -1 : 1);
        self.needsDisplay = YES;
        return;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [SectionTitle(@"Settings") drawAtPoint:NSMakePoint(22, 18)];
    NSDictionary *labelAttributes = @{NSFontAttributeName: TickerFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: TextPrimary()};
    NSDictionary *selectedLabelAttributes = @{NSFontAttributeName: TickerFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: TextBright()};
    NSDictionary *valueAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextBright()};
    NSDictionary *hintAttributes = @{NSFontAttributeName: TickerFont(9.5, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    for (NSInteger i = 0; i < (NSInteger)self.settings.count; i++) {
        NSDictionary *setting = self.settings[i];
        NSRect row = [self rectForIndex:i];
        BOOL selected = i == self.selectedIndex;
        if (selected) {
            [SelectedBackground() setFill];
            NSRectFillUsingOperation(row, NSCompositingOperationSourceOver);
            [BorderColor() setFill];
            NSRectFillUsingOperation(NSMakeRect(0, NSMinY(row), 1, NSHeight(row)), NSCompositingOperationSourceOver);
        }
        NSString *label = setting[@"label"] ?: @"";
        NSSize labelSize = [label sizeWithAttributes:labelAttributes];
        [label drawAtPoint:NSMakePoint(22, NSMinY(row) + (SettingsRowHeight - labelSize.height) / 2.0) withAttributes:selected ? selectedLabelAttributes : labelAttributes];

        NSArray *options = setting[@"options"];
        NSInteger index = [setting[@"index"] integerValue];
        NSString *value = index >= 0 && index < (NSInteger)options.count ? options[index] : @"—";
        NSString *chip = options.count > 1 ? [NSString stringWithFormat:@"‹ %@ ›", value] : value;
        NSRect chipRect = NSMakeRect(NSWidth(self.bounds) - 22 - 160, NSMinY(row) + 4, 160, SettingsRowHeight - 8);
        [(selected ? RGBA(1, 1, 1, 0.10) : RGBA(1, 1, 1, 0.05)) setFill];
        NSRectFillUsingOperation(chipRect, NSCompositingOperationSourceOver);
        [BorderColor() setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSInsetRect(chipRect, 0.5, 0.5)];
        border.lineWidth = 1;
        [border stroke];
        NSSize chipSize = [chip sizeWithAttributes:valueAttributes];
        [chip drawAtPoint:NSMakePoint(NSMidX(chipRect) - chipSize.width / 2.0, NSMidY(chipRect) - chipSize.height / 2.0) withAttributes:valueAttributes];
    }
    NSString *hint = @"↑↓ select · ←→ change · esc back";
    [hint drawAtPoint:NSMakePoint(22, NSHeight(self.bounds) - 22) withAttributes:hintAttributes];
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
    NSDictionary *attributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: self.enabled ? TextBright() : TextDim()};
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
@property BOOL showsCheckbox;
@property BOOL checkboxOn;
@property BOOL checkboxEnabled;
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
    CGFloat inset = self.showsCheckbox ? 16 : 0;
    self.iconView.frame = NSMakeRect(10 + inset, (height - 14) / 2.0, 14, 14);
    CGFloat statusX = width - StatusColumnWidth - 8;
    CGFloat viaX = statusX - ViaColumnWidth - 4;
    CGFloat versionX = viaX - VersionColumnWidth - 4;
    self.titleLabel.frame = NSMakeRect(32 + inset, textY, MAX(0, versionX - 36 - inset), 15);
    self.detailLabel.frame = NSMakeRect(versionX, textY, VersionColumnWidth, 15);
    self.viaLabel.frame = NSMakeRect(viaX, textY, ViaColumnWidth, 15);
    self.metaLabel.frame = NSMakeRect(statusX, textY, StatusColumnWidth, 15);
    self.actionButton.frame = NSMakeRect(statusX + 8, 0, StatusColumnWidth - 8, height);
    self.spinner.frame = NSMakeRect(statusX + 6, (height - 12) / 2.0, 12, 12);
}

- (void)drawRect:(NSRect)dirtyRect {
    if (!self.showsCheckbox) return;
    NSRect box = NSMakeRect(6, (NSHeight(self.bounds) - 11) / 2.0, 11, 11);
    [(self.checkboxEnabled ? BorderColor() : TextDim()) setStroke];
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(box, 0.5, 0.5)];
    path.lineWidth = 1;
    [path stroke];
    if (!self.checkboxOn) return;
    NSDictionary *attributes = @{NSFontAttributeName: TickerFont(9, NSFontWeightSemibold), NSForegroundColorAttributeName: self.checkboxEnabled ? TextBright() : TextDim()};
    [@"✓" drawAtPoint:NSMakePoint(NSMinX(box) + 1, NSMinY(box) - 1) withAttributes:attributes];
}

@end

// Confirmation sheet drawn over the list: every CLI, the exact command, then per-row results.
@interface TickerUninstallRows : NSView
@property NSArray<NSDictionary *> *plans;
@end

@implementation TickerUninstallRows
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSDictionary *titleAttributes = @{NSFontAttributeName: TickerFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: TextPrimary()};
    NSDictionary *commandAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextSecondary()};
    NSDictionary *okAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: SuccessColor()};
    NSDictionary *badAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: FailureColor()};
    NSDictionary *runAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextBright()};
    for (NSUInteger i = 0; i < self.plans.count; i++) {
        NSDictionary *plan = self.plans[i];
        CGFloat y = i * 22;
        if (i % 2 == 1) {
            [RGBA(1, 1, 1, 0.025) setFill];
            NSRectFillUsingOperation(NSMakeRect(0, y, NSWidth(self.bounds), 22), NSCompositingOperationSourceOver);
        }
        NSString *title = plan[@"title"] ?: @"";
        [title drawAtPoint:NSMakePoint(14, y + 4) withAttributes:titleAttributes];
        NSString *state = plan[@"state"] ?: @"pending";
        NSString *trailing = plan[@"command"] ?: @"";
        NSDictionary *trailingAttributes = commandAttributes;
        if ([state isEqualToString:@"running"]) {
            trailing = @"running…";
            trailingAttributes = runAttributes;
        } else if ([state isEqualToString:@"removed"]) {
            trailing = @"removed";
            trailingAttributes = okAttributes;
        } else if ([state isEqualToString:@"failed"]) {
            NSString *detail = plan[@"detail"] ?: @"failed";
            trailing = [detail isEqualToString:@"failed"] ? @"failed" : [NSString stringWithFormat:@"failed · %@", detail];
            trailingAttributes = badAttributes;
        }
        NSSize size = [trailing sizeWithAttributes:trailingAttributes];
        CGFloat maxWidth = NSWidth(self.bounds) - 180;
        if (size.width > maxWidth && maxWidth > 20) {
            while (trailing.length > 4 && [[trailing stringByAppendingString:@"…"] sizeWithAttributes:trailingAttributes].width > maxWidth) {
                trailing = [trailing substringToIndex:trailing.length - 1];
            }
            trailing = [trailing stringByAppendingString:@"…"];
            size = [trailing sizeWithAttributes:trailingAttributes];
        }
        [trailing drawAtPoint:NSMakePoint(NSWidth(self.bounds) - size.width - 12, y + 5) withAttributes:trailingAttributes];
    }
}
@end

@interface TickerUninstallSheet : TickerFlippedView
@property (nonatomic, copy) NSArray<NSDictionary *> *plans;
@property BOOL running;
@property BOOL finished;
@property TickerChipButton *cancelButton;
@property TickerChipButton *confirmButton;
@property NSScrollView *scrollView;
@property TickerUninstallRows *rowsView;
@end

@implementation TickerUninstallSheet
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scrollView.drawsBackground = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.scrollerStyle = NSScrollerStyleOverlay;
    self.scrollView.scrollerKnobStyle = NSScrollerKnobStyleLight;
    self.rowsView = [[TickerUninstallRows alloc] initWithFrame:NSZeroRect];
    self.scrollView.documentView = self.rowsView;
    [self addSubview:self.scrollView];

    self.cancelButton = [[TickerChipButton alloc] initWithFrame:NSZeroRect];
    self.cancelButton.bordered = NO;
    self.cancelButton.title = @"Cancel";
    self.confirmButton = [[TickerChipButton alloc] initWithFrame:NSZeroRect];
    self.confirmButton.bordered = NO;
    self.confirmButton.title = @"Uninstall";
    [self addSubview:self.cancelButton];
    [self addSubview:self.confirmButton];
    return self;
}

- (void)setPlans:(NSArray<NSDictionary *> *)plans {
    _plans = [plans copy];
    self.rowsView.plans = _plans;
    self.rowsView.needsDisplay = YES;
    self.needsDisplay = YES;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    self.cancelButton.frame = NSMakeRect(width - 196, height - 32, 88, 22);
    self.confirmButton.frame = NSMakeRect(width - 100, height - 32, 88, 22);
    self.scrollView.frame = NSMakeRect(8, 58, MAX(0, width - 16), MAX(0, height - 58 - 44));
    CGFloat rowHeight = MAX(self.plans.count * 22, NSHeight(self.scrollView.frame));
    self.rowsView.frame = NSMakeRect(0, 0, NSWidth(self.scrollView.frame), rowHeight);
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [SectionTitle(@"Uninstall") drawAtPoint:NSMakePoint(22, 14)];
    NSUInteger count = self.plans.count;
    NSString *title = self.finished
        ? @"Uninstall finished"
        : (self.running ? [NSString stringWithFormat:@"Uninstalling %lu %@…", count, count == 1 ? @"CLI" : @"CLIs"]
                        : [NSString stringWithFormat:@"Uninstall %lu %@?", count, count == 1 ? @"CLI" : @"CLIs"]);
    NSDictionary *titleAttributes = @{NSFontAttributeName: TickerFont(13, NSFontWeightSemibold), NSForegroundColorAttributeName: TextBright()};
    [title drawAtPoint:NSMakePoint(22, 30) withAttributes:titleAttributes];
    NSString *hint = self.finished ? @"Rescanning this Mac." : (self.running ? @"Running each command in order." : @"Nothing is removed until you confirm.");
    NSDictionary *hintAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    NSSize hintSize = [hint sizeWithAttributes:hintAttributes];
    [hint drawAtPoint:NSMakePoint(NSWidth(self.bounds) - hintSize.width - 22, 16) withAttributes:hintAttributes];
}
@end

// Update-all confirmation: a wide card, ten commands to a page, pager along the bottom.
static const CGFloat UpdateRowHeight = 20;

@interface TickerUpdateSheet : TickerFlippedView
@property (copy) NSString *heading;
@property (copy) NSString *detailText;
@property (copy) NSArray<NSString *> *commands;
@property NSInteger page;
@property TickerChipButton *previousButton;
@property TickerChipButton *nextButton;
@property TickerChipButton *cancelButton;
@property TickerChipButton *confirmButton;
- (NSUInteger)pageCount;
- (NSArray<NSString *> *)visibleCommands;
- (void)stepPage:(NSInteger)delta;
- (void)relayout;
@end

@implementation TickerUpdateSheet
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.previousButton = [[TickerChipButton alloc] initWithFrame:NSZeroRect];
    self.nextButton = [[TickerChipButton alloc] initWithFrame:NSZeroRect];
    self.cancelButton = [[TickerChipButton alloc] initWithFrame:NSZeroRect];
    self.confirmButton = [[TickerChipButton alloc] initWithFrame:NSZeroRect];
    self.previousButton.bordered = NO;
    self.nextButton.bordered = NO;
    self.cancelButton.bordered = NO;
    self.confirmButton.bordered = NO;
    self.previousButton.title = @"‹";
    self.nextButton.title = @"›";
    self.cancelButton.title = @"Cancel";
    self.confirmButton.title = @"Update";
    for (NSButton *button in @[self.previousButton, self.nextButton, self.cancelButton, self.confirmButton]) {
        [self addSubview:button];
    }
    return self;
}

- (NSUInteger)pageCount {
    if (self.commands.count == 0) return 1;
    return (self.commands.count + TickerUpdatePageSize - 1) / TickerUpdatePageSize;
}

- (NSArray<NSString *> *)visibleCommands {
    if (self.commands.count == 0) return @[];
    NSUInteger start = (NSUInteger)self.page * TickerUpdatePageSize;
    if (start >= self.commands.count) return @[];
    NSUInteger length = MIN(TickerUpdatePageSize, self.commands.count - start);
    return [self.commands subarrayWithRange:NSMakeRange(start, length)];
}

- (void)stepPage:(NSInteger)delta {
    NSInteger last = (NSInteger)self.pageCount - 1;
    self.page = MAX(0, MIN(last, self.page + delta));
    [self relayout];
    self.needsDisplay = YES;
}

- (void)relayout {
    NSUInteger shown = self.commands.count == 0 ? 2 : MIN(TickerUpdatePageSize, MAX(self.visibleCommands.count, 1));
    CGFloat width = TickerPanelSize.width - 28;
    CGFloat height = 62 + shown * UpdateRowHeight + 42;
    CGFloat available = TickerPanelSize.height - ToolbarHeight - FooterHeight;
    CGFloat y = ToolbarHeight + MAX(8, floor((available - height) / 2.0));
    self.frame = NSMakeRect(14, y, width, height);

    CGFloat buttonY = height - 32;
    self.previousButton.frame = NSMakeRect(16, buttonY, 28, 22);
    self.nextButton.frame = NSMakeRect(92, buttonY, 28, 22);
    self.confirmButton.frame = NSMakeRect(width - 96, buttonY, 80, 22);
    self.cancelButton.frame = NSMakeRect(width - 184, buttonY, 80, 22);
    BOOL hasCommands = self.commands.count > 0;
    self.confirmButton.hidden = !hasCommands;
    self.previousButton.enabled = self.page > 0;
    self.nextButton.enabled = self.page + 1 < (NSInteger)self.pageCount;
    self.previousButton.alphaValue = self.previousButton.enabled ? 1 : 0.35;
    self.nextButton.alphaValue = self.nextButton.enabled ? 1 : 0.35;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [SectionTitle(@"Update") drawAtPoint:NSMakePoint(18, 12)];
    NSDictionary *titleAttributes = @{NSFontAttributeName: TickerFont(13, NSFontWeightSemibold), NSForegroundColorAttributeName: TextBright()};
    [self.heading ?: @"" drawAtPoint:NSMakePoint(18, 28) withAttributes:titleAttributes];
    NSDictionary *detailAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    NSString *detail = self.detailText ?: @"";
    NSSize detailSize = [detail sizeWithAttributes:detailAttributes];
    [detail drawAtPoint:NSMakePoint(NSWidth(self.bounds) - detailSize.width - 18, 14) withAttributes:detailAttributes];

    NSDictionary *indexAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextDim()};
    NSDictionary *commandAttributes = @{NSFontAttributeName: TickerFont(11, NSFontWeightRegular), NSForegroundColorAttributeName: TextPrimary()};
    NSArray<NSString *> *visible = [self visibleCommands];
    if (visible.count == 0) {
        [@"Nothing here can be updated from the panel." drawAtPoint:NSMakePoint(18, 62) withAttributes:detailAttributes];
    }
    NSUInteger start = (NSUInteger)self.page * TickerUpdatePageSize;
    CGFloat commandLimit = NSWidth(self.bounds) - 64;
    for (NSUInteger i = 0; i < visible.count; i++) {
        CGFloat y = 58 + i * UpdateRowHeight;
        if (i % 2 == 0) {
            [RGBA(1, 1, 1, 0.025) setFill];
            NSRectFillUsingOperation(NSMakeRect(10, y, NSWidth(self.bounds) - 20, UpdateRowHeight), NSCompositingOperationSourceOver);
        }
        NSString *index = [NSString stringWithFormat:@"%02lu", (unsigned long)(start + i + 1)];
        [index drawAtPoint:NSMakePoint(18, y + 3) withAttributes:indexAttributes];
        NSString *command = visible[i];
        while (command.length > 4 && [command sizeWithAttributes:commandAttributes].width > commandLimit) {
            command = [[command substringToIndex:command.length - 1] stringByAppendingString:@"…"];
            // The appended ellipsis can still be too wide; drop one more source character next loop.
            if ([command sizeWithAttributes:commandAttributes].width > commandLimit && command.length > 4) {
                command = [[command substringToIndex:command.length - 2] stringByAppendingString:@"…"];
            }
        }
        [command drawAtPoint:NSMakePoint(52, y + 2) withAttributes:commandAttributes];
    }

    NSString *pageLabel = [NSString stringWithFormat:@"%ld / %lu", (long)(self.page + 1), (unsigned long)self.pageCount];
    NSDictionary *pageAttributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular), NSForegroundColorAttributeName: TextSecondary()};
    NSSize pageSize = [pageLabel sizeWithAttributes:pageAttributes];
    [pageLabel drawAtPoint:NSMakePoint(48, NSHeight(self.bounds) - 26) withAttributes:pageAttributes];
    (void)pageSize;
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
@property TickerMenuView *menuView;
@property TickerMenuBackdrop *menuBackdrop;
@property TickerSettingsView *settingsView;
@property (readwrite, getter=isMenuVisible) BOOL menuVisible;
@property (readwrite, getter=isSettingsVisible) BOOL settingsVisible;
@property (readwrite, getter=isSelecting) BOOL selecting;
@property (readwrite, getter=isUninstallSheetVisible) BOOL uninstallSheetVisible;
@property (readwrite, getter=isUpdateSheetVisible) BOOL updateSheetVisible;
@property TickerMenuBackdrop *updateBackdrop;
@property TickerUpdateSheet *updateSheet;
@property NSMutableOrderedSet<NSString *> *selectedKeySet;
@property NSInteger selectionAnchor;
@property NSButton *selectButton;
@property TickerChipButton *selectAllButton;
@property TickerChipButton *clearButton;
@property TickerChipButton *footerUninstall;
@property TickerUninstallSheet *uninstallSheet;
@property NSMutableArray<NSMutableDictionary *> *uninstallPlans;
@property BOOL uninstallRunning;
@property BOOL uninstallFinished;
@property id globalMonitor;
@property NSDate *lastResignDate;
@property (weak) NSStatusBarButton *statusButton;
@end

@implementation TickerPanelController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.selectedViewId = @"clis";
    self.selectedKeySet = [NSMutableOrderedSet orderedSet];
    self.selectionAnchor = -1;
    [self buildPanel];
    return self;
}

- (NSOrderedSet<NSString *> *)selectedKeys {
    return [self.selectedKeySet copy];
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
    panel.cancelHandler = ^{ [weakSelf cancel]; };
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

    self.menuBackdrop = [[TickerMenuBackdrop alloc] initWithFrame:frame];
    self.menuBackdrop.hidden = YES;
    self.menuBackdrop.clickHandler = ^{ [weakSelf hideMenu]; };
    [root addSubview:self.menuBackdrop];
    self.menuView = [[TickerMenuView alloc] initWithFrame:NSMakeRect(TickerPanelSize.width - MenuWidth - 8, ToolbarHeight - 2, MenuWidth, 100)];
    self.menuView.fillColor = RGBA(0.125, 0.149, 0.188, 1);
    self.menuView.strokeColor = BorderColor();
    self.menuView.hidden = YES;
    self.menuView.activateHandler = ^(NSInteger index) { [weakSelf activateMenuItemAtIndex:index]; };
    [root addSubview:self.menuView];
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

    self.selectButton = [self toolbarButton:@"checkmark.square" tooltip:@"Select CLIs to uninstall" action:@selector(selectPressed:)];
    NSArray *buttons = @[
        [self toolbarButton:@"arrow.clockwise" tooltip:@"Rescan this Mac for CLIs and agents (⌘R)" action:@selector(refreshPressed:)],
        [self toolbarButton:@"arrow.down.to.line" tooltip:@"Update all supported tools" action:@selector(updateAllPressed:)],
        self.selectButton,
        [self toolbarButton:@"doc.text" tooltip:@"Open Markdown report" action:@selector(markdownPressed:)],
        [self toolbarButton:@"curlybraces" tooltip:@"Open JSON report" action:@selector(jsonPressed:)],
        [self toolbarButton:@"line.3.horizontal" tooltip:@"Menu (right-click the menu bar icon)" action:@selector(menuPressed:)],
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
    self.selectAllButton = [[TickerChipButton alloc] initWithFrame:NSMakeRect(width - 148, 1, 78, 18)];
    self.selectAllButton.bordered = NO;
    self.selectAllButton.title = @"Select all";
    self.selectAllButton.target = self;
    self.selectAllButton.action = @selector(selectAllPressed:);
    self.selectAllButton.hidden = YES;
    self.clearButton = [[TickerChipButton alloc] initWithFrame:NSMakeRect(width - 66, 1, 54, 18)];
    self.clearButton.bordered = NO;
    self.clearButton.title = @"Clear";
    self.clearButton.target = self;
    self.clearButton.action = @selector(clearSelectionPressed:);
    self.clearButton.hidden = YES;
    for (NSView *view in @[self.headerTitle, self.headerVersion, self.headerVia, self.headerStatus, self.selectAllButton, self.clearButton]) [header addSubview:view];
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

    self.settingsView = [[TickerSettingsView alloc] initWithFrame:self.scanView.frame];
    self.settingsView.fillColor = RGBA(0.149, 0.176, 0.220, 1);
    self.settingsView.hidden = YES;
    __weak typeof(self) weakSelf = self;
    self.settingsView.changeHandler = ^(NSInteger index, NSInteger delta) { [weakSelf changeSettingAtIndex:index by:delta]; };
    [self.root addSubview:self.settingsView];
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

    self.footerUninstall = [[TickerChipButton alloc] initWithFrame:NSMakeRect(118, y + 2, 78, 18)];
    self.footerUninstall.bordered = NO;
    self.footerUninstall.title = @"Uninstall";
    self.footerUninstall.target = self;
    self.footerUninstall.action = @selector(uninstallFooterPressed);
    self.footerUninstall.hidden = YES;
    [self.root addSubview:self.footerUninstall];

    self.uninstallSheet = [[TickerUninstallSheet alloc] initWithFrame:NSMakeRect(SidebarWidth + 1, ToolbarHeight, TickerPanelSize.width - SidebarWidth - 2, TickerPanelSize.height - ToolbarHeight - FooterHeight)];
    self.uninstallSheet.fillColor = RGBA(0.125, 0.149, 0.188, 1);
    self.uninstallSheet.strokeColor = BorderColor();
    self.uninstallSheet.hidden = YES;
    self.uninstallSheet.cancelButton.target = self;
    self.uninstallSheet.cancelButton.action = @selector(cancelUninstallPressed);
    self.uninstallSheet.confirmButton.target = self;
    self.uninstallSheet.confirmButton.action = @selector(confirmUninstallPressed);
    [self.root addSubview:self.uninstallSheet];

    self.updateBackdrop = [[TickerMenuBackdrop alloc] initWithFrame:frame];
    self.updateBackdrop.hidden = YES;
    self.updateBackdrop.clickHandler = ^{ [weakSelf cancelUpdatePressed]; };
    [self.root addSubview:self.updateBackdrop];
    self.updateSheet = [[TickerUpdateSheet alloc] initWithFrame:NSZeroRect];
    self.updateSheet.fillColor = RGBA(0.110, 0.133, 0.169, 1);
    self.updateSheet.strokeColor = BorderColor();
    self.updateSheet.hidden = YES;
    self.updateSheet.previousButton.target = self;
    self.updateSheet.previousButton.action = @selector(updatePagePrevious);
    self.updateSheet.nextButton.target = self;
    self.updateSheet.nextButton.action = @selector(updatePageNext);
    self.updateSheet.cancelButton.target = self;
    self.updateSheet.cancelButton.action = @selector(cancelUpdatePressed);
    self.updateSheet.confirmButton.target = self;
    self.updateSheet.confirmButton.action = @selector(confirmUpdatePressed);
    [self.updateBackdrop addSubview:self.updateSheet];
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

    NSString *label = self.updateSheetVisible ? @"update" : (self.selecting ? @"select" : (self.settingsVisible ? @"settings" : [view[@"label"] lowercaseString]));
    if ([self isSearching]) label = [NSString stringWithFormat:@"search/%@", query];
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
    self.footerBar.values = @[stats[@"current"] ?: @0, stats[@"outdated"] ?: @0, stats[@"unknown"] ?: @0];
    self.footerBar.needsDisplay = YES;
    self.footerRight.stringValue = self.snapshot[@"status"] ?: @"";
    [self updateSelectionChrome];

    NSDictionary *scanning = self.snapshot[@"scanning"];
    self.scanView.state = [scanning isKindOfClass:[NSDictionary class]] ? scanning : nil;
    self.scanView.hidden = self.scanView.state == nil || [self isSearching];
    self.scanView.needsDisplay = YES;

    NSArray *settings = self.snapshot[@"settings"];
    self.settingsView.settings = [settings isKindOfClass:[NSArray class]] ? settings : @[];
    self.settingsView.selectedIndex = MIN(MAX(self.settingsView.selectedIndex, 0), MAX((NSInteger)self.settingsView.settings.count - 1, 0));
    self.settingsView.hidden = !self.settingsVisible || [self isSearching];
    self.settingsView.needsDisplay = YES;
    if (self.settingsVisible && !self.selecting) self.footerLeft.stringValue = [NSString stringWithFormat:@"%lu settings", (unsigned long)self.settingsView.settings.count];
    if (self.uninstallSheetVisible) {
        [self.root addSubview:self.uninstallSheet positioned:NSWindowAbove relativeTo:nil];
        self.uninstallSheet.hidden = NO;
        [self.uninstallSheet setNeedsLayout:YES];
        [self.uninstallSheet layoutSubtreeIfNeeded];
        self.uninstallSheet.needsDisplay = YES;
    }
    if (self.updateSheetVisible) {
        [self.root addSubview:self.updateBackdrop positioned:NSWindowAbove relativeTo:nil];
        self.updateBackdrop.hidden = NO;
        self.updateSheet.hidden = NO;
        [self.updateSheet relayout];
        self.updateSheet.needsDisplay = YES;
    }
    [self layoutMenu];

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
        row.selected = ![self isSearching] && !self.settingsVisible && [view[@"id"] isEqualToString:self.selectedViewId];
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

- (NSString *)shortUninstallReason:(NSString *)reason {
    if ([reason containsString:@"Apple"]) return @"system";
    if ([reason containsString:@"app"]) return @"in app";
    return @"manual";
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
    BOOL selectable = TickerRowIsSelectable(row);
    BOOL hasReason = [row[@"uninstallReason"] isKindOfClass:[NSString class]] && [row[@"uninstallReason"] length] > 0;
    cell.showsCheckbox = self.selecting && (selectable || hasReason || TickerSelectionKey(row) != nil);
    cell.checkboxOn = selectable && [self.selectedKeySet containsObject:TickerSelectionKey(row)];
    cell.checkboxEnabled = selectable;
    if (self.selecting && !selectable && hasReason) {
        cell.metaLabel.stringValue = [self shortUninstallReason:row[@"uninstallReason"]];
        cell.metaLabel.textColor = TextDim();
        cell.toolTip = row[@"uninstallReason"];
    }
    [cell setNeedsLayout:YES];
    cell.needsDisplay = YES;

    if ([row[@"kind"] isEqualToString:@"registry"]) [self configureRegistryCell:cell withRow:row];
    if (self.selecting && !selectable && hasReason) {
        cell.actionButton.hidden = YES;
        cell.metaLabel.hidden = NO;
        cell.metaLabel.stringValue = [self shortUninstallReason:row[@"uninstallReason"]];
    }
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

- (BOOL)eventHitActionButton {
    NSEvent *event = NSApp.currentEvent;
    if (!event || !self.tableView.window) return NO;
    NSView *view = [self.tableView.window.contentView hitTest:event.locationInWindow];
    while (view && view != self.tableView) {
        if ([view isKindOfClass:[NSButton class]]) return YES;
        view = view.superview;
    }
    return NO;
}

- (void)handleRowClickAtIndex:(NSInteger)index shift:(BOOL)shift {
    if (self.uninstallSheetVisible || index < 0) return;
    if (self.selecting) {
        TickerSelectionClick(self.selectedKeySet, self.rows, index, shift, &_selectionAnchor);
        [self reloadVisibleRowsKeepingHighlight:index];
        [self updateSelectionChrome];
        return;
    }
    NSDictionary *row = [self rowAtIndex:index];
    if (row) [self.delegate tickerPanel:self activateRow:row];
}

- (void)reloadVisibleRowsKeepingHighlight:(NSInteger)index {
    NSInteger selected = index >= 0 ? index : self.tableView.selectedRow;
    [self.tableView reloadData];
    if (selected >= 0 && selected < (NSInteger)self.rows.count) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
        [self.tableView scrollRowToVisible:selected];
    }
}

- (void)rowClicked:(NSTableView *)sender {
    if ([self eventHitActionButton]) return;
    BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
    [self handleRowClickAtIndex:sender.clickedRow shift:shift];
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
    if (self.updateSheetVisible) return [self updateSheetCommand:commandSelector];
    if (self.menuVisible) return [self menuCommand:commandSelector];
    if (self.settingsVisible && ![self isSearching]) return [self settingsCommand:commandSelector];
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
        if (self.uninstallSheetVisible) return YES;
        if (self.selecting) {
            [self handleRowClickAtIndex:selected shift:NO];
            return YES;
        }
        NSDictionary *row = [self rowAtIndex:selected];
        if (row) [self.delegate tickerPanel:self activateRow:row];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        if (self.uninstallSheetVisible) {
            [self cancelUninstallPressed];
            return YES;
        }
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

#pragma mark Menu and settings

- (NSArray<NSDictionary *> *)menuItems {
    NSArray *items = self.snapshot[@"menu"];
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

- (void)layoutMenu {
    self.menuView.items = [self menuItems];
    CGFloat height = [TickerMenuView heightForItems:self.menuView.items];
    self.menuView.frame = NSMakeRect(TickerPanelSize.width - MenuWidth - 8, ToolbarHeight - 2, MenuWidth, height);
    self.menuView.hidden = !self.menuVisible;
    self.menuBackdrop.hidden = !self.menuVisible;
    self.menuView.needsDisplay = YES;
}

- (void)toggleMenu {
    if (self.menuVisible) [self hideMenu];
    else [self showMenu];
}

- (void)showMenu {
    self.menuVisible = YES;
    self.menuView.selectedIndex = 0;
    [self reload];
}

- (void)hideMenu {
    if (!self.menuVisible) return;
    self.menuVisible = NO;
    [self layoutMenu];
}

- (void)showSettings {
    self.menuVisible = NO;
    self.settingsVisible = YES;
    self.searchField.stringValue = @"";
    [self reload];
}

- (void)hideSettings {
    if (!self.settingsVisible) return;
    self.settingsVisible = NO;
    [self reload];
}

// Esc peels back one layer: menu, then settings, then the panel itself.
- (void)cancel {
    if (self.updateSheetVisible) [self cancelUpdatePressed];
    else if (self.uninstallSheetVisible) [self cancelUninstallPressed];
    else if (self.menuVisible) [self hideMenu];
    else if (self.settingsVisible) [self hideSettings];
    else if (self.selecting) [self setSelectMode:NO];
    else [self close];
}

- (void)activateMenuItemAtIndex:(NSInteger)index {
    NSArray *items = [self menuItems];
    if (index < 0 || index >= (NSInteger)items.count) return;
    NSString *command = items[index][@"command"];
    [self hideMenu];
    if ([command isEqualToString:TickerCommandSettings]) {
        [self showSettings];
    } else if ([command isEqualToString:TickerCommandSelect]) {
        [self setSelectMode:!self.selecting];
    } else if (command.length > 0) {
        [self.delegate tickerPanel:self performCommand:command];
    }
}

- (BOOL)menuCommand:(SEL)commandSelector {
    NSInteger count = (NSInteger)self.menuView.items.count;
    if (commandSelector == @selector(moveDown:) || commandSelector == @selector(moveUp:)) {
        if (count == 0) return YES;
        NSInteger delta = commandSelector == @selector(moveDown:) ? 1 : -1;
        self.menuView.selectedIndex = (self.menuView.selectedIndex + delta + count) % count;
        self.menuView.needsDisplay = YES;
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        [self activateMenuItemAtIndex:self.menuView.selectedIndex];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self hideMenu];
        return YES;
    }
    return NO;
}

- (BOOL)settingsCommand:(SEL)commandSelector {
    NSInteger count = (NSInteger)self.settingsView.settings.count;
    if (commandSelector == @selector(moveDown:) || commandSelector == @selector(moveUp:)) {
        if (count == 0) return YES;
        NSInteger delta = commandSelector == @selector(moveDown:) ? 1 : -1;
        self.settingsView.selectedIndex = MAX(0, MIN(count - 1, self.settingsView.selectedIndex + delta));
        self.settingsView.needsDisplay = YES;
        return YES;
    }
    if (commandSelector == @selector(moveLeft:) || commandSelector == @selector(moveRight:) || commandSelector == @selector(insertNewline:)) {
        [self changeSettingAtIndex:self.settingsView.selectedIndex by:commandSelector == @selector(moveLeft:) ? -1 : 1];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self hideSettings];
        return YES;
    }
    return NO;
}

- (void)changeSettingAtIndex:(NSInteger)index by:(NSInteger)delta {
    NSArray *settings = self.settingsView.settings;
    if (index < 0 || index >= (NSInteger)settings.count) return;
    NSDictionary *setting = settings[index];
    NSArray *options = setting[@"options"];
    if (options.count < 2) return;
    NSInteger next = ([setting[@"index"] integerValue] + delta + (NSInteger)options.count) % (NSInteger)options.count;
    if ([self.delegate respondsToSelector:@selector(tickerPanel:changeSetting:toOption:)]) {
        [self.delegate tickerPanel:self changeSetting:setting[@"id"] toOption:options[next]];
    }
    [self reload];
}

#pragma mark Actions

- (void)viewSelected:(TickerSidebarRow *)sender {
    self.settingsVisible = NO;
    self.menuVisible = NO;
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
    if ([characters isEqualToString:@","]) { [self showSettings]; return YES; }
    if ([characters isEqualToString:@"o"]) { [self markdownPressed:nil]; return YES; }
    if ([characters isEqualToString:@"a"]) {
        if (!self.selecting) [self setSelectMode:YES];
        [self selectAllPressed:nil];
        return YES;
    }
    if ([characters isEqualToString:@"s"]) { [self setSelectMode:!self.selecting]; return YES; }
    return NO;
}

- (void)refreshPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandRefresh]; }
- (void)updateAllPressed:(id)sender {
    if (self.updateSheetVisible) {
        [self confirmUpdatePressed];
        return;
    }
    [self.delegate tickerPanel:self performCommand:TickerCommandUpdateAll];
}
- (void)markdownPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandMarkdownReport]; }
- (void)jsonPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandJSONReport]; }
- (void)menuPressed:(id)sender { [self toggleMenu]; }
- (void)quitPressed:(id)sender { [self.delegate tickerPanel:self performCommand:TickerCommandQuit]; }
- (void)selectPressed:(id)sender { [self setSelectMode:!self.selecting]; }

- (void)updateSelectionChrome {
    self.selectButton.contentTintColor = self.selecting ? TextBright() : TextSecondary();
    self.selectAllButton.hidden = !self.selecting;
    self.clearButton.hidden = !self.selecting;
    self.headerStatus.hidden = self.selecting;
    CGFloat inset = self.selecting ? 16 : 0;
    NSRect title = self.headerTitle.frame;
    title.origin.x = 32 + inset;
    title.size.width = MAX(0, NSMinX(self.headerVersion.frame) - title.origin.x - 4);
    self.headerTitle.frame = title;
    BOOL showUninstall = self.selecting && !self.settingsVisible;
    self.footerUninstall.hidden = !showUninstall;
    self.footerBar.hidden = showUninstall;
    self.footerRight.hidden = showUninstall;
    if (showUninstall) {
        NSString *summary = [NSString stringWithFormat:@"%lu selected · Uninstall", (unsigned long)self.selectedKeySet.count];
        self.footerLeft.hidden = YES;
        self.footerUninstall.title = summary;
        NSDictionary *attributes = @{NSFontAttributeName: TickerFont(10, NSFontWeightRegular)};
        CGFloat textWidth = MAX(120, ceil([summary sizeWithAttributes:attributes].width) + 16);
        self.footerUninstall.frame = NSMakeRect(8, TickerPanelSize.height - FooterHeight + 2, textWidth, 18);
        self.footerUninstall.enabled = self.selectedKeySet.count > 0;
    } else {
        self.footerLeft.hidden = NO;
        if (!self.settingsVisible) {
            self.footerLeft.stringValue = [NSString stringWithFormat:@"%lu items", (unsigned long)self.rows.count];
            self.footerLeft.frame = NSMakeRect(12, TickerPanelSize.height - FooterHeight + 4, 150, 14);
        }
    }
}

- (void)setSelectMode:(BOOL)enabled {
    if (self.selecting == enabled) {
        [self updateSelectionChrome];
        return;
    }
    self.selecting = enabled;
    self.selectionAnchor = -1;
    if (!enabled) {
        TickerSelectionClear(self.selectedKeySet);
        [self dismissUninstallSheet];
    }
    [self reload];
}

- (void)setPreviewSelectionKeys:(NSArray<NSString *> *)keys {
    [self.selectedKeySet removeAllObjects];
    for (NSString *key in keys) if (key.length > 0) [self.selectedKeySet addObject:key];
    [self reload];
}

- (void)selectAllPressed:(id)sender {
    TickerSelectionSelectAll(self.selectedKeySet, self.rows);
    [self reloadVisibleRowsKeepingHighlight:self.tableView.selectedRow];
    [self updateSelectionChrome];
}

- (void)clearSelectionPressed:(id)sender {
    TickerSelectionClear(self.selectedKeySet);
    self.selectionAnchor = -1;
    [self reloadVisibleRowsKeepingHighlight:self.tableView.selectedRow];
    [self updateSelectionChrome];
}

- (NSArray<NSMutableDictionary *> *)plansForSelectedRows {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSDictionary *view in [self views]) {
        NSArray *rows = view[@"rows"];
        if ([rows isKindOfClass:[NSArray class]]) [candidates addObjectsFromArray:rows];
    }
    [candidates addObjectsFromArray:self.rows];
    NSMutableArray<NSMutableDictionary *> *plans = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *row in candidates) {
        NSString *key = TickerSelectionKey(row);
        if (!key || ![self.selectedKeySet containsObject:key] || [seen containsObject:key] || !TickerRowIsSelectable(row)) continue;
        [seen addObject:key];
        [plans addObject:[@{
            @"key": key,
            @"title": row[@"title"] ?: key,
            @"command": row[@"uninstallCommand"] ?: @"",
            @"action": row[@"uninstallAction"],
            @"state": @"pending"
        } mutableCopy]];
    }
    return plans;
}

- (void)showUninstallSheet {
    self.uninstallSheet.plans = self.uninstallPlans;
    self.uninstallSheet.running = self.uninstallRunning;
    self.uninstallSheet.finished = self.uninstallFinished;
    self.uninstallSheet.cancelButton.hidden = self.uninstallFinished;
    self.uninstallSheet.confirmButton.title = self.uninstallFinished ? @"Done" : @"Uninstall";
    self.uninstallSheet.confirmButton.enabled = !self.uninstallRunning;
    self.uninstallSheet.hidden = NO;
    self.uninstallSheetVisible = YES;
    [self.root addSubview:self.uninstallSheet positioned:NSWindowAbove relativeTo:nil];
    [self.uninstallSheet setNeedsLayout:YES];
    [self.uninstallSheet layoutSubtreeIfNeeded];
    self.uninstallSheet.needsDisplay = YES;
}

- (BOOL)updateSheetCommand:(SEL)commandSelector {
    if (commandSelector == @selector(moveLeft:) || commandSelector == @selector(moveUp:)) {
        [self.updateSheet stepPage:-1];
        return YES;
    }
    if (commandSelector == @selector(moveRight:) || commandSelector == @selector(moveDown:)) {
        [self.updateSheet stepPage:1];
        return YES;
    }
    if (commandSelector == @selector(insertNewline:)) {
        [self confirmUpdatePressed];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self cancelUpdatePressed];
        return YES;
    }
    return YES;
}

- (void)updatePagePrevious { [self.updateSheet stepPage:-1]; }
- (void)updatePageNext { [self.updateSheet stepPage:1]; }

- (NSUInteger)updatePage {
    return self.updateSheetVisible ? (NSUInteger)self.updateSheet.page + 1 : 0;
}

- (NSUInteger)updatePageCount {
    return self.updateSheet.pageCount;
}

- (NSArray<NSString *> *)visibleUpdateCommands {
    return [self.updateSheet visibleCommands];
}

- (void)presentUpdateConfirmationWithTitle:(NSString *)title detail:(NSString *)detail commands:(NSArray<NSString *> *)commands {
    self.menuVisible = NO;
    [self layoutMenu];
    self.updateSheet.heading = title ?: @"";
    self.updateSheet.detailText = detail ?: @"";
    self.updateSheet.commands = commands ?: @[];
    self.updateSheet.page = 0;
    self.updateSheet.cancelButton.title = commands.count > 0 ? @"Cancel" : @"Close";
    [self.updateSheet relayout];
    self.updateBackdrop.hidden = NO;
    self.updateSheet.hidden = NO;
    self.updateSheetVisible = YES;
    [self.root addSubview:self.updateBackdrop positioned:NSWindowAbove relativeTo:nil];
    self.updateSheet.needsDisplay = YES;
    self.pathLabel.stringValue = @"~/cli/update";
}

- (void)dismissUpdateConfirmation {
    self.updateBackdrop.hidden = YES;
    self.updateSheet.hidden = YES;
    self.updateSheetVisible = NO;
    self.updateSheet.commands = @[];
}

- (void)cancelUpdatePressed {
    if (!self.updateSheetVisible) return;
    [self dismissUpdateConfirmation];
    [self reload];
}

- (void)confirmUpdatePressed {
    if (!self.updateSheetVisible || self.updateSheet.commands.count == 0) return;
    NSArray<NSString *> *commands = [self.updateSheet.commands copy];
    [self dismissUpdateConfirmation];
    if ([self.delegate respondsToSelector:@selector(tickerPanel:confirmUpdateCommands:)]) {
        [self.delegate tickerPanel:self confirmUpdateCommands:commands];
    }
}

- (void)dismissUninstallSheet {
    self.uninstallSheet.hidden = YES;
    self.uninstallSheetVisible = NO;
    self.uninstallRunning = NO;
    self.uninstallFinished = NO;
    self.uninstallPlans = nil;
}

- (void)presentUninstallConfirmation:(NSArray<NSDictionary *> *)plans {
    NSMutableArray *mutable = [NSMutableArray array];
    for (NSDictionary *plan in plans) [mutable addObject:[plan mutableCopy]];
    self.uninstallPlans = mutable;
    self.uninstallRunning = NO;
    self.uninstallFinished = NO;
    [self showUninstallSheet];
}

- (void)uninstallFooterPressed {
    if (!self.selecting || self.uninstallSheetVisible) return;
    NSArray *plans = [self plansForSelectedRows];
    if (plans.count == 0) return;
    [self presentUninstallConfirmation:plans];
}

- (void)cancelUninstallPressed {
    if (self.uninstallRunning && !self.uninstallFinished) return;
    [self dismissUninstallSheet];
}

- (void)confirmUninstallPressed {
    if (!self.uninstallSheetVisible) return;
    if (self.uninstallFinished) {
        [self dismissUninstallSheet];
        [self setSelectMode:NO];
        return;
    }
    if (self.uninstallRunning || self.uninstallPlans.count == 0) return;
    if (![self.delegate respondsToSelector:@selector(tickerPanel:runUninstallPlans:progress:completion:)]) return;
    self.uninstallRunning = YES;
    self.uninstallSheet.running = YES;
    self.uninstallSheet.confirmButton.enabled = NO;
    self.uninstallSheet.needsDisplay = YES;
    __weak typeof(self) weakSelf = self;
    [self.delegate tickerPanel:self runUninstallPlans:self.uninstallPlans progress:^(NSUInteger index, NSString *state, NSString *detail) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || index >= strongSelf.uninstallPlans.count) return;
        NSMutableDictionary *plan = strongSelf.uninstallPlans[index];
        plan[@"state"] = state ?: @"";
        if (detail.length > 0) plan[@"detail"] = detail;
        strongSelf.uninstallSheet.plans = strongSelf.uninstallPlans;
        [strongSelf.uninstallSheet.rowsView setNeedsDisplay:YES];
    } completion:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.uninstallRunning = NO;
        strongSelf.uninstallFinished = YES;
        strongSelf.uninstallSheet.running = NO;
        strongSelf.uninstallSheet.finished = YES;
        strongSelf.uninstallSheet.cancelButton.hidden = YES;
        strongSelf.uninstallSheet.confirmButton.title = @"Done";
        strongSelf.uninstallSheet.confirmButton.enabled = YES;
        strongSelf.uninstallSheet.needsDisplay = YES;
    }];
}

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

- (void)showMenuRelativeToStatusButton:(NSStatusBarButton *)button {
    if (self.panel.isVisible && self.menuVisible) {
        [self close];
        return;
    }
    if (!self.panel.isVisible) [self showRelativeToStatusButton:button];
    [self showMenu];
}

- (void)close {
    [self dismissUpdateConfirmation];
    self.menuVisible = NO;
    self.settingsVisible = NO;
    [self layoutMenu];
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
