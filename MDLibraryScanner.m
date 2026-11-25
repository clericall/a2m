#import "MDLibraryScanner.h"
#import "MDLog.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>

static NSString *const MDLibraryMusicRoot = @"/var/mobile/Media/iTunes_Control/Music";
static NSString *const MDLibraryDropRoot = @"/var/mobile/Media/MusicDrop";
static NSUInteger const MDLibraryScanLimit = 500;

static BOOL MDLibrarySupportedExtension(NSString *extension) {
	static NSSet<NSString *> *supported;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		supported = [NSSet setWithArray:@[
			@"mp3", @"m4a", @"m4b", @"m4r", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac",
		]];
	});
	return [supported containsObject:extension.lowercaseString];
}

@implementation MDLibraryScanner

+ (nullable NSDictionary *)metadataForPath:(NSString *)path {
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
										  options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
	if (!asset) {
		return nil;
	}

	NSString *title = nil;
	NSString *artist = nil;
	NSString *album = nil;
	for (NSString *format in asset.availableMetadataFormats) {
		for (AVMetadataItem *item in [asset metadataForFormat:format]) {
			id value = item.value;
			if (![value isKindOfClass:[NSString class]]) {
				continue;
			}
			NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (text.length == 0) {
				continue;
			}
			if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle] && title.length == 0) {
				title = text;
			} else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist] && artist.length == 0) {
				artist = text;
			} else if ([item.commonKey isEqualToString:AVMetadataCommonKeyAlbumName] && album.length == 0) {
				album = text;
			}
		}
	}

	NSString *base = [path.lastPathComponent stringByDeletingPathExtension];
	if (title.length == 0) {
		title = base.length > 0 ? base : @"Unknown Title";
	}

	double duration = CMTimeGetSeconds(asset.duration);
	if (!isfinite(duration) || duration < 0) {
		duration = 0;
	}

	return @{
		@"path": path,
		@"title": title,
		@"artist": artist ?: @"",
		@"album": album ?: @"",
		@"duration": @(duration),
	};
}

+ (NSArray<NSDictionary *> *)audioFilesInLibrary {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSMutableArray<NSString *> *directories = [NSMutableArray array];
	BOOL musicExists = NO;
	[manager fileExistsAtPath:MDLibraryMusicRoot isDirectory:&musicExists];
	if (musicExists) {
		[directories addObject:MDLibraryMusicRoot];
	}
	[directories addObject:[MDLibraryDropRoot stringByAppendingPathComponent:@"inbox"]];
	[directories addObject:[MDLibraryDropRoot stringByAppendingPathComponent:@"downloads"]];

	NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];

	for (NSString *directory in directories) {
		NSArray<NSString *> *subpaths = [manager subpathsOfDirectoryAtPath:directory error:nil];
		for (NSString *relative in subpaths) {
			if (results.count >= MDLibraryScanLimit) {
				break;
			}
			if (!MDLibrarySupportedExtension(relative.pathExtension)) {
				continue;
			}
			NSString *path = [directory stringByAppendingPathComponent:relative];
			NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
			unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
			if (size == 0 || size > 200 * 1024 * 1024) {
				continue;
			}
			if ([seen containsObject:path]) {
				continue;
			}
			[seen addObject:path];
			NSDictionary *metadata = [self metadataForPath:path];
			if (metadata) {
				[results addObject:metadata];
			}
		}
	}

	MDLog(@"Library scan found %lu audio files", (unsigned long)results.count);
	return results;
}

@end
