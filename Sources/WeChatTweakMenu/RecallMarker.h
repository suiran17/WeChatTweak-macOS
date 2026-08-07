#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the recall-ID and chat-item runtime hooks selected for the current
/// supported WeChat build.
/// Calling this function more than once is safe.
FOUNDATION_EXPORT void WCTRecallMarkerInstall(void);

/// Returns whether the avatar marker hooks were installed for this process.
FOUNDATION_EXPORT BOOL WCTRecallMarkerIsAvailable(void);

/// Runtime-only entry point used to register an item that predates hook
/// installation. It is also useful for validating a known recalled message
/// without changing WeChat's message database.
FOUNDATION_EXPORT void WCTRecallMarkerRegisterExistingItem(
    void *chatItem,
    uint64_t recalledServerID
);

NS_ASSUME_NONNULL_END
