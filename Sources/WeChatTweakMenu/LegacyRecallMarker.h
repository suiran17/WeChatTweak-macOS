#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns YES only for legacy WeChat builds whose Objective-C interfaces
/// have been verified by this runtime.
FOUNDATION_EXPORT BOOL WCTLegacyRecallMarkerSupportsCurrentBuild(void);

/// Installs the WeChat 3.8.10.17 (28632) recall and message-cell hooks.
FOUNDATION_EXPORT void WCTLegacyRecallMarkerInstall(void);

/// Returns whether the three hooks required for recall preservation and the
/// avatar marker are active.
FOUNDATION_EXPORT BOOL WCTLegacyRecallMarkerIsAvailable(void);

NS_ASSUME_NONNULL_END
