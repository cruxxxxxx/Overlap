#import "TVExceptionCatcher.h"

NSException * tv_try(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e;
    }
}
