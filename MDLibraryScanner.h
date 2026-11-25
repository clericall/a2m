#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MDLibraryScanner : NSObject

/// Audio files found in the Music library folders and MusicDrop folders.
/// Each item is a dictionary with path/title/artist/album/duration keys.
+ (NSArray<NSDictionary *> *)audioFilesInLibrary;

/// Reads basic tags and duration from a local audio file.
+ (nullable NSDictionary *)metadataForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
