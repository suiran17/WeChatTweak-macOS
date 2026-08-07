#import <AppKit/AppKit.h>
#import <objc/message.h>

#import "LegacyRecallMarker.h"

@interface WCTTestMessage : NSObject
@property(nonatomic) BOOL sendFromSelf;
@property(nonatomic) uint32_t mesLocalID;
@property(nonatomic) int64_t mesSvrID;
@end

@implementation WCTTestMessage
- (BOOL)isSendFromSelf { return self.sendFromSelf; }
@end

@interface WCTTestTableItem : NSObject
@property(nonatomic, strong) WCTTestMessage *message;
@end

@implementation WCTTestTableItem
@end

@interface FFProcessReqsvrZZ : NSObject
@property(nonatomic) NSUInteger originalDeleteCount;
@property(nonatomic) NSUInteger modifiedCount;
@property(nonatomic) NSUInteger notifiedDeleteCount;
@property(nonatomic) NSUInteger notifiedAddCount;
@property(nonatomic) NSUInteger originalPromptCount;
@property(nonatomic, strong) WCTTestMessage *storedMessage;
- (void)DelRevokedMsg:(NSString *)session msgData:(WCTTestMessage *)message;
- (void)notifyAddRevokePromptMsgOnMainThread:(NSString *)session
                                     msgData:(WCTTestMessage *)message;
@end

@implementation FFProcessReqsvrZZ
- (void)DelRevokedMsg:(NSString *)session msgData:(WCTTestMessage *)message {
    (void)session;
    (void)message;
    self.originalDeleteCount++;
}
- (void)ModifyMsgData:(NSString *)session msgData:(WCTTestMessage *)message {
    (void)session;
    self.storedMessage = message;
    self.modifiedCount++;
}
- (void)notifyDelMsgOnMainThread:(NSString *)session
                         msgData:(WCTTestMessage *)message
                        isRevoke:(BOOL)isRevoke {
    (void)session;
    (void)message;
    if (isRevoke) {
        self.notifiedDeleteCount++;
    }
}
- (void)notifyAddMsgOnMainThread:(NSString *)session
                         msgData:(WCTTestMessage *)message {
    (void)session;
    (void)message;
    self.notifiedAddCount++;
}
- (WCTTestMessage *)GetMsgData:(NSString *)session localId:(int64_t)localID {
    (void)session;
    (void)localID;
    return self.storedMessage;
}
- (void)notifyAddRevokePromptMsgOnMainThread:(NSString *)session
                                     msgData:(WCTTestMessage *)message {
    (void)session;
    (void)message;
    self.originalPromptCount++;
}
@end

@interface MMMessageCellView : NSView
@property(nonatomic, strong) NSView *avatarImgView;
@property(nonatomic, strong) WCTTestTableItem *tableItem;
@end

@implementation MMMessageCellView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        _avatarImgView = [[NSView alloc] initWithFrame:NSMakeRect(20, 30, 36, 36)];
        [self addSubview:_avatarImgView];
    }
    return self;
}
- (void)populateWithMessage:(WCTTestTableItem *)tableItem {
    self.tableItem = tableItem;
}
- (void)layout {
    [super layout];
}
@end

static void WCTRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        WCTLegacyRecallMarkerInstall();
        WCTRequire(WCTLegacyRecallMarkerIsAvailable(), @"hooks did not install");

        FFProcessReqsvrZZ *service = [[FFProcessReqsvrZZ alloc] init];
        WCTTestMessage *remote = [[WCTTestMessage alloc] init];
        remote.mesLocalID = 42;
        remote.mesSvrID = 9001;
        [service DelRevokedMsg:@"friend" msgData:remote];

        WCTRequire(service.originalDeleteCount == 0, @"remote recall was deleted");
        WCTRequire(remote.mesSvrID == 42, @"remote recall was not marked");
        WCTRequire(service.modifiedCount == 1, @"marked message was not persisted");

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];
        while (service.notifiedAddCount == 0 &&
               [deadline timeIntervalSinceNow] > 0) {
            [NSRunLoop.currentRunLoop runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        WCTRequire(service.notifiedDeleteCount == 1, @"cell deletion refresh missing");
        WCTRequire(service.notifiedAddCount == 1, @"cell insertion refresh missing");

        WCTTestTableItem *item = [[WCTTestTableItem alloc] init];
        item.message = remote;
        MMMessageCellView *cell =
            [[MMMessageCellView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)];
        [cell populateWithMessage:item];
        [cell layout];

        NSTextField *marker = nil;
        for (NSView *view in cell.subviews) {
            if (view.tag == 9527) {
                marker = (NSTextField *)view;
            }
        }
        WCTRequire(marker != nil, @"avatar marker was not created");
        WCTRequire(!marker.hidden, @"avatar marker was hidden");
        WCTRequire([marker.stringValue isEqualToString:@"[已撤回]"],
                   @"avatar marker text is wrong");
        WCTRequire(NSMaxY(marker.frame) <= NSMinY(cell.avatarImgView.frame),
                   @"avatar marker is not below the avatar");

        WCTTestMessage *own = [[WCTTestMessage alloc] init];
        own.sendFromSelf = YES;
        own.mesLocalID = 7;
        own.mesSvrID = 7001;
        [service DelRevokedMsg:@"friend" msgData:own];
        WCTRequire(service.originalDeleteCount == 1,
                   @"the user's own recall should remain functional");

        [service notifyAddRevokePromptMsgOnMainThread:@"friend" msgData:remote];
        WCTRequire(service.originalPromptCount == 0,
                   @"WeChat's duplicate recall prompt was not suppressed");

        puts("LegacyRecallMarkerHarness: recall preservation and avatar marker passed");
    }
    return 0;
}
