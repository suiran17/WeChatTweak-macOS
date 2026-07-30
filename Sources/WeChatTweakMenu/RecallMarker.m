#import "RecallMarker.h"

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <os/lock.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <unistd.h>

static NSString * const WCTRecalledServerIDsKey =
    @"WeChatTweak.RecalledServerIDs";

// These offsets are specific to WeChat 4.1.12 (269341), x86_64.
#if defined(__x86_64__)
static const uintptr_t WCTRecallParserPatchOffset = 0x4d34ead;
static const uintptr_t WCTServerIDConverterOffset = 0x4bd3700;
static const uintptr_t WCTChatItemConstructorEpilogueOffset = 0x5f6d9c;
static const uintptr_t WCTChatItemDestructorVTableOffset = 0x5f6dda;
static const uintptr_t WCTChatItemDestructorResumeOffset = 0x5f6de1;
static const uintptr_t WCTChatItemVTableHeaderOffset = 0x9c099d8;
#endif

// WeChat 4.1.12 ChatItemView/BaseChatItemViewModel layout.
static const ptrdiff_t WCTChatItemViewModelOffset = 0x230;
static const ptrdiff_t WCTViewModelServerIDOffset = 0x1b0;
static const ptrdiff_t WCTQObjectPrivateOffset = 0x8;
static const ptrdiff_t WCTQObjectParentOffset = 0x10;
static const ptrdiff_t WCTQObjectChildrenOffset = 0x18;
static const ptrdiff_t WCTQWidgetDataOffset = 0x28;
static const ptrdiff_t WCTQWidgetRectOffset = 0x14;

enum {
    WCTMaximumTrackedChatItems = 4096,
    WCTMaximumRecalledServerIDs = 4096,
    WCTMaximumAvatarTraversalDepth = 4,
    WCTMaximumAvatarTraversalNodes = 128,
};

typedef struct {
    int32_t x1;
    int32_t y1;
    int32_t x2;
    int32_t y2;
} WCTQtRect;

static os_unfair_lock WCTRuntimeLock = OS_UNFAIR_LOCK_INIT;
static void *WCTTrackedChatItems[WCTMaximumTrackedChatItems];
static size_t WCTTrackedChatItemCount;
static uint64_t WCTRecalledServerIDs[WCTMaximumRecalledServerIDs];
static size_t WCTRecalledServerIDCount;

#if defined(__x86_64__)
static uintptr_t WCTResourcesDylibBase(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL) {
            continue;
        }

        NSString *path = [NSString stringWithUTF8String:name];
        if ([path hasSuffix:@"/Contents/Resources/wechat.dylib"]) {
            return (uintptr_t)_dyld_get_image_header(index);
        }
    }
    return 0;
}
#endif

static BOOL WCTIsLikelyPointer(const void *pointer) {
    uintptr_t value = (uintptr_t)pointer;
    return value >= 0x100000000ULL && (value & (sizeof(void *) - 1)) == 0;
}

static BOOL WCTReadMemory(
    const void *source,
    void *destination,
    size_t length
) {
    if (source == NULL || destination == NULL || length == 0) {
        return NO;
    }

    uintptr_t address = (uintptr_t)source;
    if (address < 0x100000000ULL || address > UINTPTR_MAX - length) {
        return NO;
    }

    mach_vm_size_t bytesRead = 0;
    kern_return_t result = mach_vm_read_overwrite(
        mach_task_self(),
        (mach_vm_address_t)address,
        (mach_vm_size_t)length,
        (mach_vm_address_t)destination,
        &bytesRead
    );
    return result == KERN_SUCCESS && bytesRead == length;
}

static void WCTRegisterChatItem(void *chatItem) {
    if (!WCTIsLikelyPointer(chatItem)) {
        return;
    }

    os_unfair_lock_lock(&WCTRuntimeLock);
    for (size_t index = 0; index < WCTTrackedChatItemCount; index++) {
        if (WCTTrackedChatItems[index] == chatItem) {
            os_unfair_lock_unlock(&WCTRuntimeLock);
            return;
        }
    }

    if (WCTTrackedChatItemCount < WCTMaximumTrackedChatItems) {
        WCTTrackedChatItems[WCTTrackedChatItemCount++] = chatItem;
    }
    os_unfair_lock_unlock(&WCTRuntimeLock);
}

#if defined(__x86_64__)
static void WCTUnregisterChatItem(void *chatItem) {
    os_unfair_lock_lock(&WCTRuntimeLock);
    for (size_t index = 0; index < WCTTrackedChatItemCount; index++) {
        if (WCTTrackedChatItems[index] != chatItem) {
            continue;
        }

        WCTTrackedChatItems[index] =
            WCTTrackedChatItems[WCTTrackedChatItemCount - 1];
        WCTTrackedChatItems[WCTTrackedChatItemCount - 1] = NULL;
        WCTTrackedChatItemCount--;
        break;
    }
    os_unfair_lock_unlock(&WCTRuntimeLock);
}
#endif

static BOOL WCTAddRecalledServerIDLocked(uint64_t serverID) {
    if (serverID == 0) {
        return NO;
    }

    for (size_t index = 0; index < WCTRecalledServerIDCount; index++) {
        if (WCTRecalledServerIDs[index] == serverID) {
            return NO;
        }
    }

    if (WCTRecalledServerIDCount < WCTMaximumRecalledServerIDs) {
        WCTRecalledServerIDs[WCTRecalledServerIDCount++] = serverID;
    } else {
        memmove(
            &WCTRecalledServerIDs[0],
            &WCTRecalledServerIDs[1],
            sizeof(uint64_t) * (WCTMaximumRecalledServerIDs - 1)
        );
        WCTRecalledServerIDs[WCTMaximumRecalledServerIDs - 1] = serverID;
    }
    return YES;
}

static BOOL WCTIsRecalledServerID(uint64_t serverID) {
    if (serverID == 0) {
        return NO;
    }

    BOOL found = NO;
    os_unfair_lock_lock(&WCTRuntimeLock);
    for (size_t index = 0; index < WCTRecalledServerIDCount; index++) {
        if (WCTRecalledServerIDs[index] == serverID) {
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&WCTRuntimeLock);
    return found;
}

static NSArray<NSString *> *WCTRecalledServerIDStrings(void) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    os_unfair_lock_lock(&WCTRuntimeLock);
    for (size_t index = 0; index < WCTRecalledServerIDCount; index++) {
        [result addObject:
            [NSString stringWithFormat:
                @"%llu",
                (unsigned long long)WCTRecalledServerIDs[index]]];
    }
    os_unfair_lock_unlock(&WCTRuntimeLock);
    return result;
}

static void WCTPersistRecalledServerIDs(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:WCTRecalledServerIDStrings()
                 forKey:WCTRecalledServerIDsKey];
}

static void WCTRecordRecalledServerID(uint64_t serverID) {
    BOOL added = NO;
    os_unfair_lock_lock(&WCTRuntimeLock);
    added = WCTAddRecalledServerIDLocked(serverID);
    os_unfair_lock_unlock(&WCTRuntimeLock);

    if (!added) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        WCTPersistRecalledServerIDs();
    });
}

static void WCTLoadRecalledServerIDs(void) {
    NSArray *stored =
        [NSUserDefaults.standardUserDefaults arrayForKey:WCTRecalledServerIDsKey];
    if (![stored isKindOfClass:NSArray.class]) {
        return;
    }

    os_unfair_lock_lock(&WCTRuntimeLock);
    for (id value in stored) {
        uint64_t serverID = 0;
        if ([value isKindOfClass:NSString.class]) {
            serverID = strtoull([(NSString *)value UTF8String], NULL, 10);
        } else if ([value respondsToSelector:@selector(unsignedLongLongValue)]) {
            serverID = [value unsignedLongLongValue];
        }
        WCTAddRecalledServerIDLocked(serverID);
    }
    os_unfair_lock_unlock(&WCTRuntimeLock);
}

static size_t WCTSnapshotTrackedChatItems(
    void **destination,
    size_t capacity
) {
    os_unfair_lock_lock(&WCTRuntimeLock);
    size_t count = MIN(capacity, WCTTrackedChatItemCount);
    memcpy(destination, WCTTrackedChatItems, count * sizeof(void *));
    os_unfair_lock_unlock(&WCTRuntimeLock);
    return count;
}

static BOOL WCTReadWidgetRect(void *widget, WCTQtRect *rect) {
    if (!WCTIsLikelyPointer(widget) || rect == NULL) {
        return NO;
    }

    void *widgetData = NULL;
    if (!WCTReadMemory(
            (uint8_t *)widget + WCTQWidgetDataOffset,
            &widgetData,
            sizeof(widgetData)
        ) ||
        !WCTIsLikelyPointer(widgetData)) {
        return NO;
    }

    WCTQtRect candidate;
    if (!WCTReadMemory(
            (uint8_t *)widgetData + WCTQWidgetRectOffset,
            &candidate,
            sizeof(candidate)
        )) {
        return NO;
    }
    int64_t width = (int64_t)candidate.x2 - candidate.x1 + 1;
    int64_t height = (int64_t)candidate.y2 - candidate.y1 + 1;
    if (width <= 0 || height <= 0 || width > 20000 || height > 20000) {
        return NO;
    }

    *rect = candidate;
    return YES;
}

static void *WCTWidgetParent(void *widget) {
    if (!WCTIsLikelyPointer(widget)) {
        return NULL;
    }

    void *privateData = NULL;
    if (!WCTReadMemory(
            (uint8_t *)widget + WCTQObjectPrivateOffset,
            &privateData,
            sizeof(privateData)
        ) ||
        !WCTIsLikelyPointer(privateData)) {
        return NULL;
    }

    void *parent = NULL;
    if (!WCTReadMemory(
            (uint8_t *)privateData + WCTQObjectParentOffset,
            &parent,
            sizeof(parent)
        )) {
        return NULL;
    }
    return parent;
}

static BOOL WCTWidgetOriginInWindow(void *widget, NSPoint *origin) {
    if (origin == NULL) {
        return NO;
    }

    int64_t x = 0;
    int64_t y = 0;
    void *current = widget;

    for (NSUInteger depth = 0; depth < 32; depth++) {
        void *parent = WCTWidgetParent(current);
        if (parent == NULL) {
            if (depth == 0) {
                WCTQtRect rect;
                if (!WCTReadWidgetRect(current, &rect)) {
                    return NO;
                }
                x += rect.x1;
                y += rect.y1;
            }
            origin->x = x;
            origin->y = y;
            return YES;
        }

        WCTQtRect rect;
        if (!WCTReadWidgetRect(current, &rect)) {
            return NO;
        }
        x += rect.x1;
        y += rect.y1;
        if (llabs(x) > 100000 || llabs(y) > 100000) {
            return NO;
        }
        current = parent;
    }
    return NO;
}

typedef struct {
    BOOL found;
    int64_t bestScore;
    int32_t itemWidth;
    WCTQtRect rect;
    void *visited[WCTMaximumAvatarTraversalNodes];
    size_t visitedCount;
} WCTAvatarSearch;

static BOOL WCTAvatarSearchVisit(
    WCTAvatarSearch *search,
    void *widget
) {
    for (size_t index = 0; index < search->visitedCount; index++) {
        if (search->visited[index] == widget) {
            return NO;
        }
    }
    if (search->visitedCount >= WCTMaximumAvatarTraversalNodes) {
        return NO;
    }
    search->visited[search->visitedCount++] = widget;
    return YES;
}

static void WCTSearchAvatarDescendants(
    void *widget,
    int64_t widgetX,
    int64_t widgetY,
    NSUInteger depth,
    WCTAvatarSearch *search
) {
    if (depth >= WCTMaximumAvatarTraversalDepth ||
        !WCTIsLikelyPointer(widget) ||
        !WCTAvatarSearchVisit(search, widget)) {
        return;
    }

    void *privateData = NULL;
    if (!WCTReadMemory(
            (uint8_t *)widget + WCTQObjectPrivateOffset,
            &privateData,
            sizeof(privateData)
        ) ||
        !WCTIsLikelyPointer(privateData)) {
        return;
    }

    void *children = NULL;
    if (!WCTReadMemory(
            (uint8_t *)privateData + WCTQObjectChildrenOffset,
            &children,
            sizeof(children)
        ) ||
        !WCTIsLikelyPointer(children)) {
        return;
    }

    uint32_t bounds[2];
    if (!WCTReadMemory(
            (uint8_t *)children + 8,
            bounds,
            sizeof(bounds)
        )) {
        return;
    }
    uint32_t begin = bounds[0];
    uint32_t end = bounds[1];
    if (end < begin || end - begin > 64) {
        return;
    }

    for (uint32_t index = begin; index < end; index++) {
        void *child = NULL;
        if (!WCTReadMemory(
                (uint8_t *)children + 16 + index * sizeof(void *),
                &child,
                sizeof(child)
            ) ||
            !WCTIsLikelyPointer(child)) {
            continue;
        }

        WCTQtRect childRect;
        if (!WCTReadWidgetRect(child, &childRect)) {
            continue;
        }

        int64_t x1 = widgetX + childRect.x1;
        int64_t y1 = widgetY + childRect.y1;
        int64_t x2 = widgetX + childRect.x2;
        int64_t y2 = widgetY + childRect.y2;
        int64_t width = x2 - x1 + 1;
        int64_t height = y2 - y1 + 1;

        int64_t leftDistance = llabs(x1);
        int64_t rightDistance =
            llabs((int64_t)search->itemWidth - 1 - x2);
        int64_t edgeDistance = MIN(leftDistance, rightDistance);
        if (width >= 32 && width <= 64 &&
            height >= 32 && height <= 90 &&
            y1 >= -32 && y1 <= 128 &&
            edgeDistance <= 96 &&
            x1 >= INT32_MIN && x1 <= INT32_MAX &&
            y1 >= INT32_MIN && y1 <= INT32_MAX &&
            x2 >= INT32_MIN && x2 <= INT32_MAX &&
            y2 >= INT32_MIN && y2 <= INT32_MAX) {
            int64_t score =
                edgeDistance * 10000 +
                llabs(y1 - 6) * 100 +
                llabs(width - height) * 10 +
                llabs(width - 40) +
                llabs(height - 40);
            if (!search->found || score < search->bestScore) {
                search->found = YES;
                search->bestScore = score;
                search->rect = (WCTQtRect){
                    .x1 = (int32_t)x1,
                    .y1 = (int32_t)y1,
                    .x2 = (int32_t)x2,
                    .y2 = (int32_t)y2,
                };
            }
        }

        WCTSearchAvatarDescendants(
            child,
            x1,
            y1,
            depth + 1,
            search
        );
    }
}

static BOOL WCTFindAvatarRect(void *chatItem, WCTQtRect *avatarRect) {
    if (avatarRect == NULL || !WCTIsLikelyPointer(chatItem)) {
        return NO;
    }

    WCTQtRect itemRect;
    if (!WCTReadWidgetRect(chatItem, &itemRect)) {
        return NO;
    }
    int32_t itemWidth = itemRect.x2 - itemRect.x1 + 1;
    WCTAvatarSearch search = {
        .found = NO,
        .bestScore = INT64_MAX,
        .itemWidth = itemWidth,
        .visitedCount = 0,
    };
    WCTSearchAvatarDescendants(chatItem, 0, 0, 0, &search);
    if (!search.found) {
        return NO;
    }
    *avatarRect = search.rect;
    return YES;
}

@interface WCTRecallMarkerLabel : NSTextField
@end

@implementation WCTRecallMarkerLabel

- (nullable NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

@end

@interface WCTRecallOverlayController : NSObject

@property(nonatomic, weak, nullable) NSView *overlayView;
@property(nonatomic, strong) NSMutableDictionary<NSValue *, WCTRecallMarkerLabel *> *labels;
@property(nonatomic, strong, nullable) NSTimer *refreshTimer;

- (void)start;
- (void)refresh;

@end

@implementation WCTRecallOverlayController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _labels = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSView *)mainQNSView {
    NSView *largest = nil;
    CGFloat largestArea = 0;

    for (NSWindow *window in NSApp.windows) {
        NSView *contentView = window.contentView;
        if (contentView == nil ||
            ![NSStringFromClass(contentView.class) isEqualToString:@"QNSView"]) {
            continue;
        }

        NSString *description = contentView.description;
        if ([description containsString:@"FramelessMainWindowClassWindow"]) {
            return contentView;
        }

        CGFloat area = NSWidth(contentView.bounds) * NSHeight(contentView.bounds);
        if (area > largestArea) {
            largest = contentView;
            largestArea = area;
        }
    }
    return largest;
}

- (void)start {
    if (self.refreshTimer != nil) {
        return;
    }

    [self refresh];
    NSTimer *refreshTimer =
        [NSTimer timerWithTimeInterval:(1.0 / 120.0)
                                target:self
                              selector:@selector(refresh)
                              userInfo:nil
                               repeats:YES];
    refreshTimer.tolerance = 1.0 / 480.0;
    [NSRunLoop.mainRunLoop addTimer:refreshTimer forMode:NSRunLoopCommonModes];
    self.refreshTimer = refreshTimer;
}

- (WCTRecallMarkerLabel *)labelForChatItem:(void *)chatItem {
    NSValue *key = [NSValue valueWithPointer:chatItem];
    WCTRecallMarkerLabel *label = self.labels[key];
    if (label != nil) {
        return label;
    }

    label = [WCTRecallMarkerLabel labelWithString:@"[已撤回]"];
    label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    label.textColor = [NSColor colorWithWhite:0.60 alpha:1.0];
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByClipping;
    label.maximumNumberOfLines = 1;
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    label.hidden = YES;
    [self.overlayView addSubview:label];
    self.labels[key] = label;
    return label;
}

- (void)refresh {
    NSAssert(NSThread.isMainThread, @"Recall marker refresh must run on the main thread");

    NSView *overlayView = [self mainQNSView];
    if (overlayView == nil) {
        return;
    }
    if (overlayView != self.overlayView) {
        for (NSTextField *label in self.labels.allValues) {
            [label removeFromSuperview];
        }
        [self.labels removeAllObjects];
        self.overlayView = overlayView;
    }

    void *items[WCTMaximumTrackedChatItems];
    size_t count = WCTSnapshotTrackedChatItems(
        items,
        WCTMaximumTrackedChatItems
    );
    NSMutableSet<NSValue *> *activeKeys = [NSMutableSet setWithCapacity:count];

    for (size_t index = 0; index < count; index++) {
        void *chatItem = items[index];
        NSValue *key = [NSValue valueWithPointer:chatItem];
        [activeKeys addObject:key];

        void *viewModel = NULL;
        if (!WCTReadMemory(
                (uint8_t *)chatItem + WCTChatItemViewModelOffset,
                &viewModel,
                sizeof(viewModel)
            ) ||
            !WCTIsLikelyPointer(viewModel)) {
            self.labels[key].hidden = YES;
            continue;
        }

        uint64_t serverID = 0;
        if (!WCTReadMemory(
                (uint8_t *)viewModel + WCTViewModelServerIDOffset,
                &serverID,
                sizeof(serverID)
            )) {
            self.labels[key].hidden = YES;
            continue;
        }
        if (!WCTIsRecalledServerID(serverID)) {
            self.labels[key].hidden = YES;
            continue;
        }

        WCTQtRect avatarRect;
        NSPoint itemOrigin;
        if (!WCTFindAvatarRect(chatItem, &avatarRect) ||
            !WCTWidgetOriginInWindow(chatItem, &itemOrigin)) {
            self.labels[key].hidden = YES;
            continue;
        }

        const CGFloat labelWidth = 60;
        const CGFloat labelHeight = 14;
        const CGFloat avatarWidth = avatarRect.x2 - avatarRect.x1 + 1;
        const CGFloat markerGap = 2;
        CGFloat x =
            itemOrigin.x + avatarRect.x1 + (avatarWidth - labelWidth) / 2.0;
        CGFloat y = itemOrigin.y + avatarRect.y1 + avatarWidth + markerGap;
        NSRect frame = NSMakeRect(x, y, labelWidth, labelHeight);

        WCTRecallMarkerLabel *label = [self labelForChatItem:chatItem];
        label.frame = frame;
        label.hidden = !NSIntersectsRect(frame, overlayView.bounds);
    }

    for (NSValue *key in self.labels.allKeys.copy) {
        if (![activeKeys containsObject:key]) {
            [self.labels[key] removeFromSuperview];
            [self.labels removeObjectForKey:key];
        }
    }
}

@end

#if defined(__x86_64__)

typedef struct {
    uint8_t *memory;
    size_t offset;
    size_t capacity;
} WCTX86Emitter;

static BOOL WCTEmitBytes(
    WCTX86Emitter *emitter,
    const void *bytes,
    size_t length
) {
    if (emitter->offset > emitter->capacity ||
        length > emitter->capacity - emitter->offset) {
        return NO;
    }
    memcpy(emitter->memory + emitter->offset, bytes, length);
    emitter->offset += length;
    return YES;
}

static BOOL WCTEmitByte(WCTX86Emitter *emitter, uint8_t byte) {
    return WCTEmitBytes(emitter, &byte, sizeof(byte));
}

static BOOL WCTEmitUInt64(WCTX86Emitter *emitter, uint64_t value) {
    return WCTEmitBytes(emitter, &value, sizeof(value));
}

static BOOL WCTEmitRelativeCall(
    WCTX86Emitter *emitter,
    uintptr_t destination
) {
    uintptr_t instruction = (uintptr_t)emitter->memory + emitter->offset;
    int64_t displacement = (int64_t)destination - (int64_t)(instruction + 5);
    if (displacement < INT32_MIN || displacement > INT32_MAX) {
        return NO;
    }

    uint8_t opcode = 0xe8;
    int32_t relative = (int32_t)displacement;
    return WCTEmitByte(emitter, opcode) &&
        WCTEmitBytes(emitter, &relative, sizeof(relative));
}

static BOOL WCTEmitMoveRegisterImmediate(
    WCTX86Emitter *emitter,
    const uint8_t opcode[2],
    uintptr_t value
) {
    return WCTEmitBytes(emitter, opcode, 2) &&
        WCTEmitUInt64(emitter, value);
}

static BOOL WCTEmitMoveRAXImmediate(
    WCTX86Emitter *emitter,
    uintptr_t value
) {
    const uint8_t opcode[] = {0x48, 0xb8};
    return WCTEmitMoveRegisterImmediate(emitter, opcode, value);
}

static BOOL WCTEmitAbsoluteJump(
    WCTX86Emitter *emitter,
    uintptr_t destination
) {
    // Use the caller-saved r11 register so constructor return values and the
    // destructor's reconstructed vtable value in rax survive the jump.
    const uint8_t moveR11[] = {0x49, 0xbb};
    const uint8_t jumpR11[] = {0x41, 0xff, 0xe3};
    return WCTEmitMoveRegisterImmediate(emitter, moveR11, destination) &&
        WCTEmitBytes(emitter, jumpR11, sizeof(jumpR11));
}

static BOOL WCTMakeRelativeCallPatch(
    uint8_t patch[5],
    uintptr_t instruction,
    uintptr_t destination
) {
    int64_t displacement = (int64_t)destination - (int64_t)(instruction + 5);
    if (displacement < INT32_MIN || displacement > INT32_MAX) {
        return NO;
    }
    patch[0] = 0xe8;
    int32_t relative = (int32_t)displacement;
    memcpy(&patch[1], &relative, sizeof(relative));
    return YES;
}

static BOOL WCTCanReachWithRelativeCall(
    uintptr_t instruction,
    uintptr_t destination
) {
    int64_t displacement = (int64_t)destination - (int64_t)(instruction + 5);
    return displacement >= INT32_MIN && displacement <= INT32_MAX;
}

static BOOL WCTWriteExecutableMemory(
    void *destination,
    const void *source,
    size_t length
) {
    vm_size_t pageSize = (vm_size_t)getpagesize();
    uintptr_t start = (uintptr_t)destination & ~(uintptr_t)(pageSize - 1);
    uintptr_t end =
        ((uintptr_t)destination + length + pageSize - 1) &
        ~(uintptr_t)(pageSize - 1);
    mach_vm_size_t protectedLength = end - start;

    kern_return_t result = mach_vm_protect(
        mach_task_self(),
        start,
        protectedLength,
        FALSE,
        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
    );
    if (result != KERN_SUCCESS) {
        if (mprotect(
                (void *)start,
                protectedLength,
                PROT_READ | PROT_WRITE | PROT_EXEC
            ) != 0) {
            return NO;
        }
    }

    memcpy(destination, source, length);
    __builtin___clear_cache(
        (char *)destination,
        (char *)destination + length
    );

    mach_vm_protect(
        mach_task_self(),
        start,
        protectedLength,
        FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE
    );
    return YES;
}

static void *WCTAllocateExecutablePage(uintptr_t imageBase) {
    size_t pageSize = (size_t)getpagesize();
    int flags = MAP_PRIVATE | MAP_ANON;
#if defined(MAP_JIT)
    flags |= MAP_JIT;
#endif

    uintptr_t patchAddresses[] = {
        imageBase + WCTRecallParserPatchOffset,
        imageBase + WCTChatItemConstructorEpilogueOffset,
        imageBase + WCTChatItemDestructorVTableOffset,
    };
    uintptr_t anchor = imageBase + WCTRecallParserPatchOffset;
    uintptr_t hints[] = {
        anchor + 0x10000000ULL,
        anchor - 0x10000000ULL,
        anchor + 0x20000000ULL,
        anchor - 0x20000000ULL,
        0,
    };

    for (size_t hintIndex = 0;
         hintIndex < sizeof(hints) / sizeof(hints[0]);
         hintIndex++) {
        uintptr_t hint = hints[hintIndex] & ~(uintptr_t)(pageSize - 1);
        void *memory = mmap(
            hint == 0 ? NULL : (void *)hint,
            pageSize,
            PROT_READ | PROT_WRITE | PROT_EXEC,
            flags,
            -1,
            0
        );
        if (memory == MAP_FAILED) {
            continue;
        }

        uintptr_t start = (uintptr_t)memory;
        uintptr_t end = start + pageSize - 1;
        BOOL reachable = YES;
        for (size_t patchIndex = 0;
             patchIndex <
                 sizeof(patchAddresses) / sizeof(patchAddresses[0]);
             patchIndex++) {
            if (!WCTCanReachWithRelativeCall(
                    patchAddresses[patchIndex],
                    start
                ) ||
                !WCTCanReachWithRelativeCall(
                    patchAddresses[patchIndex],
                    end
                )) {
                reachable = NO;
                break;
            }
        }

        if (reachable) {
            return memory;
        }
        munmap(memory, pageSize);
    }
    return NULL;
}

static BOOL WCTValidateBytes(
    uintptr_t address,
    const uint8_t *expected,
    size_t length
) {
    return memcmp((const void *)address, expected, length) == 0;
}

typedef struct {
    uintptr_t imageBase;
    uintptr_t imageEnd;
    void *items[WCTMaximumTrackedChatItems];
    size_t count;
} WCTChatItemDiscovery;

static kern_return_t WCTLocalMemoryReader(
    task_t task,
    vm_address_t address,
    vm_size_t size,
    void **localMemory
) {
    (void)task;
    (void)size;
    *localMemory = (void *)address;
    return KERN_SUCCESS;
}

static uintptr_t WCTMachOImageEnd(uintptr_t imageBase) {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)imageBase;
    if (header->magic != MH_MAGIC_64) {
        return imageBase;
    }

    uintptr_t imageEnd = imageBase;
    const uint8_t *commandBytes = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command =
            (const struct load_command *)commandBytes;
        if (command->cmdsize < sizeof(struct load_command)) {
            return imageBase;
        }

        if (command->cmd == LC_SEGMENT_64 &&
            command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            uintptr_t segmentEnd =
                imageBase + segment->vmaddr + segment->vmsize;
            imageEnd = MAX(imageEnd, segmentEnd);
        }
        commandBytes += command->cmdsize;
    }
    return imageEnd;
}

static BOOL WCTAddressIsInResourcesImage(
    uintptr_t address,
    const WCTChatItemDiscovery *discovery
) {
    return address >= discovery->imageBase &&
        address < discovery->imageEnd;
}

static BOOL WCTTypeInfoInheritsFrom(
    uintptr_t typeInfo,
    uintptr_t targetTypeInfo,
    const WCTChatItemDiscovery *discovery,
    NSUInteger depth
) {
    if (typeInfo == targetTypeInfo) {
        return YES;
    }
    if (depth >= 32 ||
        !WCTAddressIsInResourcesImage(typeInfo, discovery)) {
        return NO;
    }

    uintptr_t typeInfoVTable = *(const uintptr_t *)typeInfo;
    uintptr_t targetVMITypeInfoVTable =
        *(const uintptr_t *)targetTypeInfo;
    if (typeInfoVTable == targetVMITypeInfoVTable) {
        uint64_t flagsAndCount =
            *(const uint64_t *)(typeInfo + 2 * sizeof(uintptr_t));
        uint32_t baseCount = (uint32_t)(flagsAndCount >> 32);
        if (baseCount == 0 || baseCount > 32) {
            return NO;
        }

        const uintptr_t *baseEntries =
            (const uintptr_t *)(typeInfo + 3 * sizeof(uintptr_t));
        for (uint32_t index = 0; index < baseCount; index++) {
            uintptr_t baseTypeInfo = baseEntries[index * 2];
            if (WCTTypeInfoInheritsFrom(
                    baseTypeInfo,
                    targetTypeInfo,
                    discovery,
                    depth + 1
                )) {
                return YES;
            }
        }
        return NO;
    }

    // Single-inheritance type_info stores its direct base at +0x10. Plain
    // class_type_info has no base; the image-range check safely rejects it.
    uintptr_t baseTypeInfo =
        *(const uintptr_t *)(typeInfo + 2 * sizeof(uintptr_t));
    if (!WCTAddressIsInResourcesImage(baseTypeInfo, discovery)) {
        return NO;
    }
    return WCTTypeInfoInheritsFrom(
        baseTypeInfo,
        targetTypeInfo,
        discovery,
        depth + 1
    );
}

static BOOL WCTAllocationLooksLikeChatItem(
    const vm_range_t *range,
    const WCTChatItemDiscovery *discovery
) {
    if (range->size < (vm_size_t)(WCTChatItemViewModelOffset + sizeof(void *))) {
        return NO;
    }

    const uintptr_t *object = (const uintptr_t *)range->address;
    uintptr_t vtable = object[0];
    if (!WCTAddressIsInResourcesImage(vtable, discovery) ||
        vtable < discovery->imageBase + sizeof(uintptr_t)) {
        return NO;
    }

    uintptr_t typeInfo = *((const uintptr_t *)vtable - 1);
    if (!WCTAddressIsInResourcesImage(typeInfo, discovery)) {
        return NO;
    }

    uintptr_t targetTypeInfo =
        *(const uintptr_t *)(
            discovery->imageBase +
            WCTChatItemVTableHeaderOffset +
            sizeof(uintptr_t)
        );
    return WCTTypeInfoInheritsFrom(
        typeInfo,
        targetTypeInfo,
        discovery,
        0
    );
}

static void WCTRecordChatItemAllocations(
    task_t task,
    void *context,
    unsigned type,
    vm_range_t *ranges,
    unsigned count
) {
    (void)task;
    if ((type & MALLOC_PTR_IN_USE_RANGE_TYPE) == 0) {
        return;
    }

    WCTChatItemDiscovery *discovery = context;
    for (unsigned index = 0;
         index < count &&
             discovery->count < WCTMaximumTrackedChatItems;
         index++) {
        if (WCTAllocationLooksLikeChatItem(&ranges[index], discovery)) {
            discovery->items[discovery->count++] =
                (void *)ranges[index].address;
        }
    }
}

static void WCTDiscoverExistingChatItems(uintptr_t imageBase) {
    WCTChatItemDiscovery discovery = {
        .imageBase = imageBase,
        .imageEnd = WCTMachOImageEnd(imageBase),
        .count = 0,
    };
    if (discovery.imageEnd <= discovery.imageBase) {
        return;
    }

    vm_address_t *zoneAddresses = NULL;
    unsigned zoneCount = 0;
    kern_return_t result = malloc_get_all_zones(
        mach_task_self(),
        WCTLocalMemoryReader,
        &zoneAddresses,
        &zoneCount
    );
    if (result != KERN_SUCCESS || zoneAddresses == NULL) {
        return;
    }

    for (unsigned index = 0; index < zoneCount; index++) {
        malloc_zone_t *zone = (malloc_zone_t *)zoneAddresses[index];
        if (zone == NULL || zone->introspect == NULL ||
            zone->introspect->enumerator == NULL) {
            continue;
        }
        zone->introspect->enumerator(
            mach_task_self(),
            &discovery,
            MALLOC_PTR_IN_USE_RANGE_TYPE,
            (vm_address_t)zone,
            WCTLocalMemoryReader,
            WCTRecordChatItemAllocations
        );
    }

    for (size_t index = 0; index < discovery.count; index++) {
        WCTRegisterChatItem(discovery.items[index]);
    }
    NSLog(
        @"[WeChatTweak] Discovered %zu existing chat item views",
        discovery.count
    );
}

static BOOL WCTInstallX86RuntimeHooks(uintptr_t imageBase) {
    const uint8_t expectedRecallPatch[] = {0x31, 0xc0, 0x90, 0x90, 0x90};
    const uint8_t expectedConstructorPatch[] =
        {0x48, 0x83, 0xc4, 0x28, 0x5b};
    const uint8_t expectedDestructorInstruction[] =
        {0x48, 0x8d, 0x05, 0xf7, 0x2b, 0x61, 0x09};

    uintptr_t recallPatch = imageBase + WCTRecallParserPatchOffset;
    uintptr_t constructorPatch =
        imageBase + WCTChatItemConstructorEpilogueOffset;
    uintptr_t destructorPatch =
        imageBase + WCTChatItemDestructorVTableOffset;

    if (!WCTValidateBytes(
            recallPatch,
            expectedRecallPatch,
            sizeof(expectedRecallPatch)
        ) ||
        !WCTValidateBytes(
            constructorPatch,
            expectedConstructorPatch,
            sizeof(expectedConstructorPatch)
        ) ||
        !WCTValidateBytes(
            destructorPatch,
            expectedDestructorInstruction,
            sizeof(expectedDestructorInstruction)
        )) {
        NSLog(@"[WeChatTweak] Recall marker hooks do not match this WeChat binary");
        return NO;
    }

    uint8_t *code = WCTAllocateExecutablePage(imageBase);
    if (code == NULL) {
        NSLog(@"[WeChatTweak] Unable to allocate recall marker trampolines");
        return NO;
    }

    size_t pageSize = (size_t)getpagesize();
    WCTX86Emitter emitter = {
        .memory = code,
        .offset = 0,
        .capacity = pageSize,
    };

    uintptr_t recallStub = (uintptr_t)code + emitter.offset;
    const uint8_t recallPrefix[] = {0x55, 0x48, 0x89, 0xe5};
    const uint8_t moveRAXToRDI[] = {0x48, 0x89, 0xc7};
    const uint8_t callRAX[] = {0xff, 0xd0};
    const uint8_t recallSuffix[] = {0x31, 0xc0, 0x5d, 0xc3};
    if (!WCTEmitBytes(&emitter, recallPrefix, sizeof(recallPrefix)) ||
        !WCTEmitRelativeCall(
            &emitter,
            imageBase + WCTServerIDConverterOffset
        ) ||
        !WCTEmitBytes(&emitter, moveRAXToRDI, sizeof(moveRAXToRDI)) ||
        !WCTEmitMoveRAXImmediate(
            &emitter,
            (uintptr_t)&WCTRecordRecalledServerID
        ) ||
        !WCTEmitBytes(&emitter, callRAX, sizeof(callRAX)) ||
        !WCTEmitBytes(&emitter, recallSuffix, sizeof(recallSuffix))) {
        munmap(code, pageSize);
        return NO;
    }

    emitter.offset = (emitter.offset + 15) & ~(size_t)15;
    uintptr_t constructorStub = (uintptr_t)code + emitter.offset;
    const uint8_t pushRAX[] = {0x50};
    const uint8_t moveRBXToRDI[] = {0x48, 0x89, 0xdf};
    const uint8_t popRAXAndDiscardReturn[] =
        {0x58, 0x48, 0x83, 0xc4, 0x08};
    const uint8_t constructorEpilogue[] =
        {0x48, 0x83, 0xc4, 0x28, 0x5b};
    if (!WCTEmitBytes(&emitter, pushRAX, sizeof(pushRAX)) ||
        !WCTEmitBytes(&emitter, moveRBXToRDI, sizeof(moveRBXToRDI)) ||
        !WCTEmitMoveRAXImmediate(
            &emitter,
            (uintptr_t)&WCTRegisterChatItem
        ) ||
        !WCTEmitBytes(&emitter, callRAX, sizeof(callRAX)) ||
        !WCTEmitBytes(
            &emitter,
            popRAXAndDiscardReturn,
            sizeof(popRAXAndDiscardReturn)
        ) ||
        !WCTEmitBytes(
            &emitter,
            constructorEpilogue,
            sizeof(constructorEpilogue)
        ) ||
        !WCTEmitAbsoluteJump(&emitter, constructorPatch + 5)) {
        munmap(code, pageSize);
        return NO;
    }

    emitter.offset = (emitter.offset + 15) & ~(size_t)15;
    uintptr_t destructorStub = (uintptr_t)code + emitter.offset;
    if (!WCTEmitBytes(&emitter, pushRAX, sizeof(pushRAX)) ||
        !WCTEmitBytes(&emitter, moveRBXToRDI, sizeof(moveRBXToRDI)) ||
        !WCTEmitMoveRAXImmediate(
            &emitter,
            (uintptr_t)&WCTUnregisterChatItem
        ) ||
        !WCTEmitBytes(&emitter, callRAX, sizeof(callRAX)) ||
        !WCTEmitBytes(
            &emitter,
            popRAXAndDiscardReturn,
            sizeof(popRAXAndDiscardReturn)
        ) ||
        // The original destructor continues to address the object through
        // rdi immediately after the replaced LEA instruction.
        !WCTEmitBytes(&emitter, moveRBXToRDI, sizeof(moveRBXToRDI)) ||
        !WCTEmitMoveRAXImmediate(
            &emitter,
            imageBase + WCTChatItemVTableHeaderOffset
        ) ||
        !WCTEmitAbsoluteJump(
            &emitter,
            imageBase + WCTChatItemDestructorResumeOffset
        )) {
        munmap(code, pageSize);
        return NO;
    }

    __builtin___clear_cache((char *)code, (char *)code + emitter.offset);
    mprotect(code, pageSize, PROT_READ | PROT_EXEC);

    uint8_t recallCall[5];
    uint8_t constructorCall[5];
    uint8_t destructorCall[5];
    if (!WCTMakeRelativeCallPatch(
            recallCall,
            recallPatch,
            recallStub
        ) ||
        !WCTMakeRelativeCallPatch(
            constructorCall,
            constructorPatch,
            constructorStub
        ) ||
        !WCTMakeRelativeCallPatch(
            destructorCall,
            destructorPatch,
            destructorStub
        )) {
        munmap(code, pageSize);
        NSLog(@"[WeChatTweak] Recall marker trampolines are out of range");
        return NO;
    }

    if (!WCTWriteExecutableMemory(
            (void *)recallPatch,
            recallCall,
            sizeof(recallCall)
        ) ||
        !WCTWriteExecutableMemory(
            (void *)constructorPatch,
            constructorCall,
            sizeof(constructorCall)
        ) ||
        !WCTWriteExecutableMemory(
            (void *)destructorPatch,
            destructorCall,
            sizeof(destructorCall)
        )) {
        NSLog(@"[WeChatTweak] Unable to write recall marker hooks");
        return NO;
    }
    return YES;
}

#endif

static WCTRecallOverlayController *WCTOverlayController;
static BOOL WCTRuntimeHooksInstalled;

static void WCTTryInstallRuntimeHooks(NSUInteger remainingAttempts) {
    if (WCTRuntimeHooksInstalled) {
        return;
    }

#if defined(__x86_64__)
    uintptr_t imageBase = WCTResourcesDylibBase();
    if (imageBase != 0) {
        WCTRuntimeHooksInstalled = WCTInstallX86RuntimeHooks(imageBase);
        if (WCTRuntimeHooksInstalled) {
            WCTDiscoverExistingChatItems(imageBase);
            NSLog(@"[WeChatTweak] Recall marker runtime hooks installed");
            [WCTOverlayController refresh];
            return;
        }
        NSLog(@"[WeChatTweak] Recall marker runtime hooks are unavailable");
        return;
    }

    if (remainingAttempts > 0) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
            dispatch_get_main_queue(),
            ^{
                WCTTryInstallRuntimeHooks(remainingAttempts - 1);
            }
        );
        return;
    }
#else
    (void)remainingAttempts;
#endif

    NSLog(@"[WeChatTweak] Recall marker runtime hooks are unavailable");
}

void WCTRecallMarkerRegisterExistingItem(
    void *chatItem,
    uint64_t recalledServerID
) {
    WCTRegisterChatItem(chatItem);
    WCTRecordRecalledServerID(recalledServerID);
    dispatch_async(dispatch_get_main_queue(), ^{
        [WCTOverlayController refresh];
    });
}

void WCTRecallMarkerInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WCTLoadRecalledServerIDs();

        dispatch_async(dispatch_get_main_queue(), ^{
            WCTOverlayController = [[WCTRecallOverlayController alloc] init];
            [WCTOverlayController start];
            WCTTryInstallRuntimeHooks(100);
        });
    });
}

BOOL WCTRecallMarkerIsAvailable(void) {
    return WCTRuntimeHooksInstalled;
}
