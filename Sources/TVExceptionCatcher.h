#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`; if it raises an Objective-C exception, returns it (else nil).
NSException * _Nullable tv_try(void (^block)(void));

NS_ASSUME_NONNULL_END
