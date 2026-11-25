#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDPreferences : NSObject

+ (BOOL)embedLyrics;
+ (void)setEmbedLyrics:(BOOL)enabled;

+ (BOOL)embedArtwork;
+ (void)setEmbedArtwork:(BOOL)enabled;

+ (NSString *)downloadFormat;
+ (void)setDownloadFormat:(NSString *)format;

+ (BOOL)showProgressDetails;
+ (void)setShowProgressDetails:(BOOL)enabled;

+ (BOOL)nativeLyricsPatch;
+ (void)setNativeLyricsPatch:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
