#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const WeChatTweakMenuRuntimeVersion;

/// Installs the menu when an AppKit main menu becomes available.
/// Calling this function more than once is safe.
FOUNDATION_EXPORT void WeChatTweakMenuInstall(void);

NS_ASSUME_NONNULL_END
