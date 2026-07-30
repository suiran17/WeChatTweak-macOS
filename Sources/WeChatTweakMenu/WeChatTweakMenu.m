#import "WeChatTweakMenu.h"
#import "RecallMarker.h"

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>

NSString * const WeChatTweakMenuRuntimeVersion = @"2.3.6-269341";

static NSString * const WCTRootMenuIdentifier = @"com.sunnyyoung.WeChatTweak.menu";

static BOOL WCTUsesChinese(void) {
    NSArray<NSString *> *localizations = NSBundle.mainBundle.preferredLocalizations;
    NSString *language = localizations.firstObject ?: NSLocale.preferredLanguages.firstObject;
    return [language.lowercaseString hasPrefix:@"zh"];
}

static NSString *WCTText(NSString *chinese, NSString *english) {
    return WCTUsesChinese() ? chinese : english;
}

static NSString *WCTRecallStatusTitle(void) {
    if (WCTRecallMarkerIsAvailable()) {
        return WCTText(@"拦截撤回并显示「[已撤回]」",
                       @"Keep Recalled Messages and Show [Recalled]");
    }
    return WCTText(@"拦截撤回已启用；头像标记暂不可用",
                   @"Recall Prevention Enabled; Avatar Marker Unavailable");
}

static NSTextField *WCTLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = font;
    label.textColor = color;
    label.maximumNumberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

@interface WCTMenuController : NSObject

@property(nonatomic, strong, nullable) NSWindowController *settingsWindowController;
@property(nonatomic) NSInteger remainingInstallAttempts;

- (void)start;
- (void)installMenuIfPossible;
- (void)showSettings:(nullable id)sender;
- (void)launchAnotherAccount:(nullable id)sender;
- (void)showAbout:(nullable id)sender;

@end

@implementation WCTMenuController

- (void)start {
    self.remainingInstallAttempts = 80;

    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self
                      selector:@selector(applicationStateChanged:)
                          name:NSApplicationDidFinishLaunchingNotification
                        object:nil];
    [notifications addObserver:self
                      selector:@selector(applicationStateChanged:)
                          name:NSApplicationDidBecomeActiveNotification
                        object:nil];
    [notifications addObserver:self
                      selector:@selector(applicationStateChanged:)
                          name:NSApplicationDidUpdateNotification
                        object:nil];

    [self installMenuIfPossible];
}

- (void)applicationStateChanged:(NSNotification *)notification {
    (void)notification;
    self.remainingInstallAttempts = 80;
    [self installMenuIfPossible];
}

- (nullable NSMenuItem *)installedRootItemInMenu:(NSMenu *)mainMenu {
    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.identifier isEqualToString:WCTRootMenuIdentifier]) {
            return item;
        }
    }
    return nil;
}

- (NSMenuItem *)statusItemWithTitle:(NSString *)title {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(showSettings:)
                                           keyEquivalent:@""];
    item.target = self;
    item.state = NSControlStateValueOn;
    item.toolTip = WCTText(@"此功能已由 WeChatTweak 补丁启用",
                           @"Enabled by the WeChatTweak patch");
    return item;
}

- (NSMenuItem *)actionItemWithTitle:(NSString *)title
                             action:(SEL)action
                      keyEquivalent:(NSString *)keyEquivalent {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:keyEquivalent];
    item.target = self;
    return item;
}

- (void)installMenuIfPossible {
    NSAssert(NSThread.isMainThread, @"WeChatTweak menu installation must run on the main thread");

    NSMenu *mainMenu = NSApp.mainMenu;
    if (mainMenu == nil) {
        if (self.remainingInstallAttempts-- > 0) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                dispatch_get_main_queue(),
                ^{
                    [self installMenuIfPossible];
                }
            );
        }
        return;
    }

    if ([self installedRootItemInMenu:mainMenu] != nil) {
        return;
    }

    NSMenu *tweakMenu = [[NSMenu alloc] initWithTitle:@"Tweak"];
    [tweakMenu addItem:[self statusItemWithTitle:WCTRecallStatusTitle()]];
    [tweakMenu addItem:[self statusItemWithTitle:
        WCTText(@"禁止自动更新", @"Disable Automatic Updates")]];
    [tweakMenu addItem:NSMenuItem.separatorItem];
    [tweakMenu addItem:[self actionItemWithTitle:
        WCTText(@"登录另一个微信账号…", @"Log In to Another Account…")
                                         action:@selector(launchAnotherAccount:)
                                  keyEquivalent:@""]];
    [tweakMenu addItem:NSMenuItem.separatorItem];
    [tweakMenu addItem:[self actionItemWithTitle:
        WCTText(@"Tweak 设置…", @"Tweak Settings…")
                                         action:@selector(showSettings:)
                                  keyEquivalent:@","]];
    [tweakMenu addItem:[self actionItemWithTitle:
        WCTText(@"关于 WeChatTweak…", @"About WeChatTweak…")
                                         action:@selector(showAbout:)
                                  keyEquivalent:@""]];

    NSMenuItem *rootItem = [[NSMenuItem alloc] initWithTitle:@"Tweak"
                                                      action:nil
                                               keyEquivalent:@""];
    rootItem.identifier = WCTRootMenuIdentifier;
    rootItem.submenu = tweakMenu;
    [mainMenu addItem:rootItem];
}

- (NSView *)statusRowWithTitle:(NSString *)title detail:(NSString *)detail {
    NSImage *image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                              accessibilityDescription:nil];
    NSImageView *icon = [NSImageView imageViewWithImage:image ?: NSImage.new];
    icon.contentTintColor = NSColor.systemGreenColor;
    icon.symbolConfiguration =
        [NSImageSymbolConfiguration configurationWithPointSize:20
                                                         weight:NSFontWeightSemibold];
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;

    NSTextField *titleLabel = WCTLabel(
        title,
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold],
        NSColor.labelColor
    );
    NSTextField *detailLabel = WCTLabel(
        detail,
        [NSFont systemFontOfSize:12],
        NSColor.secondaryLabelColor
    );

    NSStackView *text = [NSStackView stackViewWithViews:@[titleLabel, detailLabel]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 4;

    NSStackView *row = [NSStackView stackViewWithViews:@[icon, text]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:58].active = YES;
    return row;
}

- (NSWindowController *)makeSettingsWindowController {
    NSRect frame = NSMakeRect(0, 0, 580, 430);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = WCTText(@"WeChatTweak 设置", @"WeChatTweak Settings");
    window.releasedWhenClosed = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSView *content = [[NSView alloc] initWithFrame:frame];
    window.contentView = content;

    NSString *build =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    NSString *version =
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";

    NSTextField *title = WCTLabel(
        @"WeChatTweak",
        [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold],
        NSColor.labelColor
    );
    NSTextField *subtitle = WCTLabel(
        [NSString stringWithFormat:
            WCTText(@"微信 %@（构建 %@）", @"WeChat %@ (build %@)"),
            version,
            build],
        [NSFont systemFontOfSize:12],
        NSColor.secondaryLabelColor
    );

    NSString *recallTitle;
    NSString *recallDetail;
    if (WCTRecallMarkerIsAvailable()) {
        recallTitle =
            WCTText(@"拦截撤回与撤回标记 · 已启用",
                    @"Recall Prevention and Recall Marker · Enabled");
        recallDetail =
            WCTText(@"原消息会保留，并在发送者头像下方显示「[已撤回]」标识。",
                    @"The original remains with a [Recalled] marker below the sender's avatar.");
    } else {
        recallTitle =
            WCTText(@"拦截撤回 · 已启用",
                    @"Recall Prevention · Enabled");
        recallDetail =
            WCTText(@"当前架构仍会保留原消息，但头像下方的撤回标识暂不可用。",
                    @"The original remains, but the avatar marker is unavailable on this architecture.");
    }
    NSView *revoke = [self statusRowWithTitle:recallTitle
                                       detail:recallDetail];
    NSView *updates = [self
        statusRowWithTitle:
            WCTText(@"禁止自动更新 · 已启用", @"Automatic Updates · Disabled")
                    detail:
            WCTText(@"微信的后台更新检查与自动下载已被禁用。",
                    @"Background update checks and automatic downloads are disabled.")];
    NSView *instances = [self
        statusRowWithTitle:
            WCTText(@"微信多开入口 · 已启用", @"Multiple-Account Launcher · Enabled")
                    detail:
            WCTText(@"可从 Tweak 菜单启动另一个独立微信实例。",
                    @"Use the Tweak menu to start another WeChat instance.")];

    NSButton *launchButton =
        [NSButton buttonWithTitle:
            WCTText(@"登录另一个账号…", @"Log In to Another Account…")
                          target:self
                          action:@selector(launchAnotherAccount:)];
    launchButton.bezelStyle = NSBezelStyleRounded;

    NSTextField *note = WCTLabel(
        WCTText(@"适配微信 4.1.12（构建 269341）。补丁或菜单运行时更新后需要重新启动微信。",
                @"Adapted for WeChat 4.1.12 (build 269341). Restart WeChat after updating the patch or menu runtime."),
        [NSFont systemFontOfSize:11],
        NSColor.tertiaryLabelColor
    );

    NSStackView *stack = [NSStackView stackViewWithViews:@[
        title,
        subtitle,
        revoke,
        updates,
        instances,
        launchButton,
        note
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.distribution = NSStackViewDistributionGravityAreas;

    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-28],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-24],
        [revoke.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [updates.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [instances.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [note.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];

    [window center];
    return [[NSWindowController alloc] initWithWindow:window];
}

- (void)showSettings:(nullable id)sender {
    (void)sender;
    if (self.settingsWindowController == nil) {
        self.settingsWindowController = [self makeSettingsWindowController];
    }

    [self.settingsWindowController showWindow:nil];
    [self.settingsWindowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showError:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText =
        WCTText(@"无法启动另一个微信", @"Unable to Start Another WeChat");
    alert.informativeText =
        error.localizedDescription ?: WCTText(@"发生未知错误。", @"An unknown error occurred.");
    [alert addButtonWithTitle:WCTText(@"好", @"OK")];

    NSWindow *window = self.settingsWindowController.window ?: NSApp.keyWindow;
    if (window != nil) {
        [alert beginSheetModalForWindow:window completionHandler:nil];
    } else {
        [alert runModal];
    }
}

- (void)launchAnotherAccount:(nullable id)sender {
    (void)sender;
    NSURL *applicationURL = NSBundle.mainBundle.bundleURL;
    NSWorkspaceOpenConfiguration *configuration =
        NSWorkspaceOpenConfiguration.configuration;
    configuration.createsNewApplicationInstance = YES;
    configuration.activates = YES;

    [NSWorkspace.sharedWorkspace
        openApplicationAtURL:applicationURL
               configuration:configuration
           completionHandler:
               ^(NSRunningApplication *application, NSError *error) {
                   (void)application;
                   if (error != nil) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                           [self showError:error];
                       });
                   }
               }];
}

- (void)showAbout:(nullable id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"WeChatTweak";
    NSString *capabilities = WCTRecallMarkerIsAvailable()
        ? WCTText(@"拦截撤回、头像撤回标识、禁止自动更新与多开入口已启用。",
                  @"Recall prevention, avatar recall markers, update blocking, and the multi-account launcher are enabled.")
        : WCTText(@"拦截撤回、禁止自动更新与多开入口已启用；头像撤回标识在当前架构暂不可用。",
                  @"Recall prevention, update blocking, and the multi-account launcher are enabled; avatar recall markers are unavailable on this architecture.");
    alert.informativeText = [NSString stringWithFormat:
        WCTText(@"菜单运行时 %@\n适配微信 4.1.12（构建 269341）\n\n%@",
                @"Menu runtime %@\nAdapted for WeChat 4.1.12 (build 269341)\n\n%@"),
        WeChatTweakMenuRuntimeVersion,
        capabilities];
    [alert addButtonWithTitle:WCTText(@"好", @"OK")];
    [alert runModal];
}

@end

void WeChatTweakMenuInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static WCTMenuController *controller;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            controller = [[WCTMenuController alloc] init];
            [controller start];
        });
        [controller installMenuIfPossible];
    });
}

__attribute__((constructor))
static void WCTBootstrapMenu(void) {
    WCTRecallMarkerInstall();
    WeChatTweakMenuInstall();
}
