#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDRuntimeDump : NSObject

/// Logs all Objective-C classes, methods, and ivars whose names mention
/// lyrics or now-playing, plus the live view hierarchy of Music's windows.
+ (void)logLyricsRuntimeInfo;

@end

NS_ASSUME_NONNULL_END
