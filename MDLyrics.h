#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDLyrics : NSObject

+ (instancetype)sharedLyrics;

/// Stable key used for the on-disk lyric sidecars.
+ (NSString *)lyricsKeyForTitle:(NSString *)title artist:(NSString *)artist;

/// Plain/synced lyrics saved when a track was fetched. Nil when unavailable.
+ (nullable NSString *)plainLyricsForTitle:(NSString *)title artist:(NSString *)artist;
+ (nullable NSString *)syncedLyricsForTitle:(NSString *)title artist:(NSString *)artist;

/// Fetches lyrics from LRCLIB using track metadata and embeds them into the
/// audio file so iOS Music can show them in the Now Playing lyrics view.
/// Returns YES when lyrics were written. Never throws; failures are logged
/// and leave the original file untouched.
- (BOOL)embedLyricsForTitle:(NSString *)title
                     artist:(NSString *)artist
                      album:(nullable NSString *)album
                   duration:(double)duration
              intoFileAtPath:(NSString *)path
                  extension:(NSString *)extension;

@end

NS_ASSUME_NONNULL_END
