#import "LegacyRecallMarker.h"

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const WCTLegacySupportedBuild = @"28632";
static const NSInteger WCTLegacyRecallLabelTag = 9527;

typedef void (*WCTDeleteMessageIMP)(id, SEL, NSString *, id);
typedef void (*WCTPopulateMessageIMP)(id, SEL, id);
typedef void (*WCTLayoutIMP)(id, SEL);
typedef void (*WCTPromptMessageIMP)(id, SEL, NSString *, id);

static WCTDeleteMessageIMP WCTOriginalDeleteMessage;
static WCTPopulateMessageIMP WCTOriginalPopulateMessage;
static WCTLayoutIMP WCTOriginalLayout;
static WCTPromptMessageIMP WCTOriginalPromptMessage;
static BOOL WCTLegacyHooksInstalled;
static BOOL WCTLegacyInstallFinished;

static id WCTSendObject(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static id WCTSendObjectWithObject(id object, SEL selector, id value) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static uint32_t WCTSendUInt32(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return 0;
    }
    return ((uint32_t (*)(id, SEL))objc_msgSend)(object, selector);
}

static int64_t WCTSendInt64(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return 0;
    }
    return ((int64_t (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WCTSendBool(id object, SEL selector) {
    if (object == nil || ![object respondsToSelector:selector]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WCTLegacyMessageIsMarked(id message) {
    int64_t serverID = WCTSendInt64(message, NSSelectorFromString(@"mesSvrID"));
    uint32_t localID = WCTSendUInt32(message, NSSelectorFromString(@"mesLocalID"));
    return serverID != 0 && localID != 0 && serverID == (int64_t)localID;
}

static NSTextField *WCTLegacyRecallLabel(NSView *cell, BOOL create) {
    for (NSView *subview in cell.subviews) {
        if (subview.tag == WCTLegacyRecallLabelTag &&
            [subview isKindOfClass:NSTextField.class]) {
            return (NSTextField *)subview;
        }
    }

    if (!create) {
        return nil;
    }

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.hidden = YES;
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.usesSingleLineMode = YES;
    label.tag = WCTLegacyRecallLabelTag;
    label.stringValue = @"[已撤回]";
    label.font = [NSFont systemFontOfSize:7.0];
    label.textColor = NSColor.lightGrayColor;
    [label sizeToFit];
    [cell addSubview:label];
    return label;
}

static void WCTLegacyDeleteMessage(
    id self,
    SEL selector,
    NSString *session,
    id message
) {
    if (WCTSendBool(message, NSSelectorFromString(@"isSendFromSelf"))) {
        WCTOriginalDeleteMessage(self, selector, session, message);
        return;
    }

    uint32_t localID = WCTSendUInt32(message, NSSelectorFromString(@"mesLocalID"));
    if (localID == 0 ||
        ![message respondsToSelector:NSSelectorFromString(@"setMesSvrID:")]) {
        // An unknown message layout must fall back to WeChat instead of
        // corrupting its database.
        WCTOriginalDeleteMessage(self, selector, session, message);
        return;
    }

    ((void (*)(id, SEL, int64_t))objc_msgSend)(
        message,
        NSSelectorFromString(@"setMesSvrID:"),
        (int64_t)localID
    );

    SEL modify = NSSelectorFromString(@"ModifyMsgData:msgData:");
    if ([self respondsToSelector:modify]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(self, modify, session, message);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        SEL notifyDelete =
            NSSelectorFromString(@"notifyDelMsgOnMainThread:msgData:isRevoke:");
        SEL notifyAdd = NSSelectorFromString(@"notifyAddMsgOnMainThread:msgData:");
        if ([self respondsToSelector:notifyDelete]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                self,
                notifyDelete,
                session,
                message,
                YES
            );
        }
        if ([self respondsToSelector:notifyAdd]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                self,
                notifyAdd,
                session,
                message
            );
        }
    });
}

static void WCTLegacyPopulateMessage(id self, SEL selector, id tableItem) {
    WCTOriginalPopulateMessage(self, selector, tableItem);
    if (![self isKindOfClass:NSView.class]) {
        return;
    }

    id message = WCTSendObject(tableItem, NSSelectorFromString(@"message"));
    NSTextField *label = WCTLegacyRecallLabel((NSView *)self, YES);
    label.hidden = !WCTLegacyMessageIsMarked(message);
    if (!label.hidden) {
        [self setNeedsLayout:YES];
    }
}

static void WCTLegacyLayout(id self, SEL selector) {
    WCTOriginalLayout(self, selector);
    if (![self isKindOfClass:NSView.class]) {
        return;
    }

    NSView *cell = (NSView *)self;
    NSTextField *label = WCTLegacyRecallLabel(cell, NO);
    if (label == nil) {
        return;
    }

    id avatar = WCTSendObject(self, NSSelectorFromString(@"avatarImgView"));
    if (![avatar isKindOfClass:NSView.class]) {
        return;
    }

    NSRect avatarFrame = ((NSView *)avatar).frame;
    NSRect labelFrame = label.frame;
    labelFrame.origin.x = NSMidX(avatarFrame) - NSWidth(labelFrame) / 2.0;
    labelFrame.origin.y = NSMinY(avatarFrame) - NSHeight(labelFrame);
    label.frame = labelFrame;
}

static void WCTLegacyPromptMessage(
    id self,
    SEL selector,
    NSString *session,
    id message
) {
    SEL getMessage = NSSelectorFromString(@"GetMsgData:localId:");
    uint32_t localID = WCTSendUInt32(message, NSSelectorFromString(@"mesLocalID"));
    id localMessage = nil;
    if ([self respondsToSelector:getMessage] && localID != 0) {
        localMessage = ((id (*)(id, SEL, id, int64_t))objc_msgSend)(
            self,
            getMessage,
            session,
            (int64_t)localID
        );
    }

    if (!WCTLegacyMessageIsMarked(localMessage)) {
        WCTOriginalPromptMessage(self, selector, session, message);
    }
}

static BOOL WCTInstallHook(
    Class cls,
    SEL selector,
    IMP replacement,
    IMP _Nullable *original
) {
    if (cls == Nil) {
        return NO;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        return NO;
    }

    IMP previous = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) {
        *original = previous;
        return YES;
    }

    Method ownMethod = class_getInstanceMethod(cls, selector);
    *original = method_setImplementation(ownMethod, replacement);
    return YES;
}

static void WCTTryInstallLegacyHooks(NSUInteger remainingAttempts) {
    if (WCTLegacyInstallFinished) {
        return;
    }

    Class serviceClass = objc_getClass("FFProcessReqsvrZZ");
    Class cellClass = objc_getClass("MMMessageCellView");
    if (serviceClass == Nil || cellClass == Nil) {
        if (remainingAttempts > 0) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                dispatch_get_main_queue(),
                ^{ WCTTryInstallLegacyHooks(remainingAttempts - 1); }
            );
        } else {
            WCTLegacyInstallFinished = YES;
            NSLog(@"[WeChatTweak] WeChat 28632 classes were not loaded");
        }
        return;
    }

    BOOL deleteInstalled = WCTInstallHook(
        serviceClass,
        NSSelectorFromString(@"DelRevokedMsg:msgData:"),
        (IMP)WCTLegacyDeleteMessage,
        (IMP *)&WCTOriginalDeleteMessage
    );
    BOOL populateInstalled = WCTInstallHook(
        cellClass,
        NSSelectorFromString(@"populateWithMessage:"),
        (IMP)WCTLegacyPopulateMessage,
        (IMP *)&WCTOriginalPopulateMessage
    );
    BOOL layoutInstalled = WCTInstallHook(
        cellClass,
        NSSelectorFromString(@"layout"),
        (IMP)WCTLegacyLayout,
        (IMP *)&WCTOriginalLayout
    );

    // The prompt hook is optional. Recall preservation and the avatar marker
    // remain functional if a future maintenance build removes this method.
    WCTInstallHook(
        serviceClass,
        NSSelectorFromString(@"notifyAddRevokePromptMsgOnMainThread:msgData:"),
        (IMP)WCTLegacyPromptMessage,
        (IMP *)&WCTOriginalPromptMessage
    );

    WCTLegacyInstallFinished = YES;
    WCTLegacyHooksInstalled =
        deleteInstalled && populateInstalled && layoutInstalled;
    NSLog(
        WCTLegacyHooksInstalled
            ? @"[WeChatTweak] WeChat 28632 recall and avatar hooks installed"
            : @"[WeChatTweak] WeChat 28632 hooks are unavailable"
    );
}

BOOL WCTLegacyRecallMarkerSupportsCurrentBuild(void) {
    NSString *build =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return [build isEqualToString:WCTLegacySupportedBuild];
}

void WCTLegacyRecallMarkerInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WCTTryInstallLegacyHooks(100);
    });
}

BOOL WCTLegacyRecallMarkerIsAvailable(void) {
    return WCTLegacyHooksInstalled;
}
