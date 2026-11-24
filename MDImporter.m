#import "MDImporter.h"
#import "MDHelperClient.h"
#import "MDHelperProtocol.h"
#import "MDLog.h"
#import "MDPreferences.h"
#import "MDServer.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>

// Declared locally so MusicDrop never links StoreServices. The classes are
// resolved at runtime inside the Music app process.
@interface SSDownloadMetadata : NSObject
- (id)initWithDictionary:(NSDictionary *)dictionary;
- (void)setPrimaryAssetURL:(NSURL *)url;
- (void)setShouldDownloadAutomatically:(BOOL)flag;
@end

@interface SSDownload : NSObject
- (id)initWithDownloadMetadata:(id)metadata;
@end

@interface SSDownloadQueue : NSObject
+ (id)mediaDownloadKinds;
- (id)initWithDownloadKinds:(id)kinds;
- (BOOL)addDownload:(id)download;
- (void)setShouldAutomaticallyFinishDownloads:(BOOL)flag;
@end

static NSString *const MDMediaRoot = @"/var/mobile/Media/MusicDrop";
static NSString *const MDInboxDirectory = @"/var/mobile/Media/MusicDrop/inbox";
static NSString *const MDArtworkDirectory = @"/var/mobile/Media/MusicDrop/artwork";

typedef NS_ENUM(NSInteger, MDMediaKind) {
	MDMediaKindSong,
	MDMediaKindRingtone,
	MDMediaKindMusicVideo,
};

@interface MDImporter ()

@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) SSDownloadQueue *downloadQueue;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, assign) NSUInteger keepAliveGeneration;

@end

static NSError *MDError(NSString *message) {
	return [NSError errorWithDomain:@"com.musiccc.musicdrop"
							   code:1
						   userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *MDSafeString(id value) {
	if ([value isKindOfClass:[NSString class]]) {
		return [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	}
	if ([value isKindOfClass:[NSNumber class]]) {
		return [(NSNumber *)value stringValue];
	}
	return nil;
}

typedef NS_ENUM(NSInteger, MDMetadataField) {
	MDMetadataFieldGenre,
	MDMetadataFieldComposer,
	MDMetadataFieldCopyright,
	MDMetadataFieldTrackNumber,
	MDMetadataFieldYear,
	MDMetadataFieldArtwork,
	MDMetadataFieldAlbumArtist,
};

static NSArray<NSString *> *MDIdentifiersForField(MDMetadataField field) {
	static NSDictionary<NSNumber *, NSArray<NSString *> *> *groups;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		groups = @{
			@(MDMetadataFieldGenre): @[
				AVMetadataIdentifierID3MetadataContentType,
				AVMetadataIdentifieriTunesMetadataUserGenre,
				AVMetadataIdentifierQuickTimeMetadataGenre,
				AVMetadataIdentifierQuickTimeUserDataGenre,
				AVMetadataIdentifier3GPUserDataGenre,
			],
			@(MDMetadataFieldComposer): @[
				AVMetadataIdentifierID3MetadataComposer,
				AVMetadataIdentifieriTunesMetadataComposer,
				AVMetadataIdentifierQuickTimeMetadataComposer,
				AVMetadataIdentifierQuickTimeUserDataComposer,
			],
			@(MDMetadataFieldCopyright): @[
				AVMetadataIdentifierID3MetadataCopyright,
				AVMetadataIdentifierID3MetadataCopyrightInformation,
				AVMetadataIdentifieriTunesMetadataCopyright,
				AVMetadataIdentifierQuickTimeMetadataCopyright,
				AVMetadataIdentifierQuickTimeUserDataCopyright,
				AVMetadataIdentifierISOUserDataCopyright,
				AVMetadataIdentifier3GPUserDataCopyright,
			],
			@(MDMetadataFieldTrackNumber): @[
				AVMetadataIdentifierID3MetadataTrackNumber,
				AVMetadataIdentifieriTunesMetadataTrackNumber,
				AVMetadataIdentifierQuickTimeUserDataTrack,
			],
			@(MDMetadataFieldYear): @[
				AVMetadataIdentifierID3MetadataYear,
				AVMetadataIdentifierID3MetadataDate,
				AVMetadataIdentifierID3MetadataRecordingDates,
				AVMetadataIdentifierID3MetadataRecordingTime,
				AVMetadataIdentifierID3MetadataReleaseTime,
				AVMetadataIdentifierID3MetadataOriginalReleaseTime,
				AVMetadataIdentifierID3MetadataOriginalReleaseYear,
				AVMetadataIdentifieriTunesMetadataReleaseDate,
				AVMetadataIdentifierQuickTimeMetadataYear,
				AVMetadataIdentifierQuickTimeMetadataCreationDate,
				AVMetadataIdentifierQuickTimeUserDataCreationDate,
				AVMetadataIdentifierISOUserDataDate,
				AVMetadataIdentifier3GPUserDataRecordingYear,
			],
			@(MDMetadataFieldArtwork): @[
				AVMetadataIdentifierID3MetadataAttachedPicture,
				AVMetadataIdentifierQuickTimeMetadataArtwork,
			],
			@(MDMetadataFieldAlbumArtist): @[
				AVMetadataIdentifieriTunesMetadataAlbumArtist,
			],
		};
	});
	return groups[@(field)] ?: @[];
}

static BOOL MDIdentifierMatchesField(NSString *identifier, MDMetadataField field) {
	return [MDIdentifiersForField(field) containsObject:identifier];
}

static NSData *MDArtworkDataFromItem(AVMetadataItem *item) {
	id value = item.value;
	NSData *data = [value isKindOfClass:[NSData class]] ? value : nil;
	if (!data && [value isKindOfClass:[NSDictionary class]]) {
		id inner = ((NSDictionary *)value)[@"data"];
		if ([inner isKindOfClass:[NSData class]]) {
			data = inner;
		}
	}
	if (!data && [item.dataValue isKindOfClass:[NSData class]]) {
		data = item.dataValue;
	}
	return data.length > 0 ? data : nil;
}

static int MDYearFromValue(id value) {
	if ([value isKindOfClass:[NSDate class]]) {
		NSDateComponents *components = [[NSCalendar currentCalendar] components:NSCalendarUnitYear
																	   fromDate:(NSDate *)value];
		return components.year > 0 ? (int)components.year : 0;
	}
	NSString *string = MDSafeString(value);
	if (string.length < 4) {
		return 0;
	}
	for (NSUInteger index = 0; index + 4 <= string.length; index++) {
		NSString *candidate = [string substringWithRange:NSMakeRange(index, 4)];
		if ([[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
			 [NSCharacterSet characterSetWithCharactersInString:candidate]]) {
			int year = candidate.intValue;
			if (year >= 1900 && year <= 2100) {
				return year;
			}
		}
	}
	return 0;
}

static void MDReadTrackNumbers(id value, int *track, int *count) {
	if ([value isKindOfClass:[NSData class]]) {
		NSData *data = (NSData *)value;
		if (data.length >= 8) {
			const uint8_t *bytes = data.bytes;
			int parsedTrack = (bytes[2] << 8) | bytes[3];
			int parsedCount = (bytes[4] << 8) | bytes[5];
			if (parsedTrack > 0) {
				*track = parsedTrack;
			}
			if (parsedCount > 0) {
				*count = parsedCount;
			}
		}
	} else if ([value isKindOfClass:[NSString class]]) {
		int parsedTrack = 0;
		int parsedCount = 0;
		if (sscanf([(NSString *)value UTF8String], "%d/%d", &parsedTrack, &parsedCount) >= 1) {
			if (parsedTrack > 0) {
				*track = parsedTrack;
			}
			if (parsedCount > 0) {
				*count = parsedCount;
			}
		}
	} else if ([value isKindOfClass:[NSNumber class]]) {
		int parsedTrack = [(NSNumber *)value intValue];
		if (parsedTrack > 0) {
			*track = parsedTrack;
		}
	}
}

static BOOL MDEnsureDirectories(void) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSArray<NSString *> *paths = @[MDMediaRoot, MDInboxDirectory, MDArtworkDirectory];
	for (NSString *path in paths) {
		NSError *error = nil;
		if (![manager createDirectoryAtPath:path
				withIntermediateDirectories:YES
								 attributes:@{NSFileProtectionKey: NSFileProtectionNone}
									  error:&error]) {
			MDLog(@"Could not create %@: %@", path, error.localizedDescription);
			return NO;
		}
	}
	return YES;
}

static NSString *MDRandomToken(void) {
	NSString *token = [[NSUUID UUID].UUIDString lowercaseString];
	return [token stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

static BOOL MDIsSupportedExtension(NSString *extension) {
	static NSSet<NSString *> *supported;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		supported = [NSSet setWithArray:@[
			@"mp3", @"m4a", @"m4r", @"m4b", @"aac", @"wav", @"aif", @"aiff",
			@"aifc", @"caf", @"flac", @"alac", @"mp4", @"m4v", @"mov",
		]];
	});
	return [supported containsObject:extension.lowercaseString];
}

static MDMediaKind MDKindForExtension(NSString *extension) {
	if ([extension isEqualToString:@"m4r"]) {
		return MDMediaKindRingtone;
	}
	if ([extension isEqualToString:@"mp4"] ||
		[extension isEqualToString:@"m4v"] ||
		[extension isEqualToString:@"mov"]) {
		return MDMediaKindMusicVideo;
	}
	return MDMediaKindSong;
}

static NSString *MDKindString(MDMediaKind kind) {
	switch (kind) {
		case MDMediaKindRingtone: return @"ringtone";
		case MDMediaKindMusicVideo: return @"music-video";
		default: return @"song";
	}
}

static NSData *MDResizedJPEG(NSData *data, CGFloat maxSide) {
	UIImage *image = [UIImage imageWithData:data];
	if (!image || image.size.width <= 0 || image.size.height <= 0) {
		return nil;
	}

	CGFloat scale = 1.0;
	if (image.size.width > maxSide || image.size.height > maxSide) {
		scale = maxSide / MAX(image.size.width, image.size.height);
	}
	CGSize target = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));
	if (target.width < 1 || target.height < 1) {
		return nil;
	}

	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
	format.scale = 1.0;
	format.opaque = YES;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
	UIImage *resized = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[[UIColor blackColor] setFill];
		UIRectFill(CGRectMake(0, 0, target.width, target.height));
		[image drawInRect:CGRectMake(0, 0, target.width, target.height)];
	}];
	return UIImageJPEGRepresentation(resized, 0.92);
}

static NSData *MDDefaultArtwork(void) {
	static NSData *artwork;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		CGSize size = CGSizeMake(600, 600);
		UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
		format.scale = 1.0;
		format.opaque = YES;
		UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
		UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
			CGContextRef c = context.CGContext;

			CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
			CGFloat colors[8] = {
				1.00f, 0.23f, 0.36f, 1.0f,
				0.52f, 0.00f, 0.24f, 1.0f,
			};
			CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
			CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
			CGGradientRelease(gradient);
			CGColorSpaceRelease(space);

			CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:1.0 alpha:0.10].CGColor);
			CGContextFillEllipseInRect(c, CGRectMake(50, 50, 500, 500));

			CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);

			// Two beamed eighth notes.
			CGContextFillEllipseInRect(c, CGRectMake(130, 380, 130, 95));
			CGContextFillEllipseInRect(c, CGRectMake(315, 345, 130, 95));
			CGContextFillRect(c, CGRectMake(238, 150, 22, 270));
			CGContextFillRect(c, CGRectMake(423, 115, 22, 270));

			CGContextBeginPath(c);
			CGContextMoveToPoint(c, 238, 150);
			CGContextAddLineToPoint(c, 445, 115);
			CGContextAddLineToPoint(c, 445, 165);
			CGContextAddLineToPoint(c, 238, 200);
			CGContextClosePath(c);
			CGContextFillPath(c);

			// Small download arrow, bottom-right.
			CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:1.0 alpha:0.92].CGColor);
			CGContextFillRect(c, CGRectMake(470, 380, 22, 95));
			CGContextBeginPath(c);
			CGContextMoveToPoint(c, 440, 465);
			CGContextAddLineToPoint(c, 522, 465);
			CGContextAddLineToPoint(c, 481, 520);
			CGContextClosePath(c);
			CGContextFillPath(c);
		}];
		artwork = UIImageJPEGRepresentation(image, 0.92);
	});
	return artwork;
}

@implementation MDImporter

+ (instancetype)sharedImporter {
	static MDImporter *importer;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		importer = [[MDImporter alloc] init];
	});
	return importer;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_workQueue = dispatch_queue_create("com.musiccc.musicdrop.importer", DISPATCH_QUEUE_SERIAL);
		_backgroundTask = UIBackgroundTaskInvalid;
		MDEnsureDirectories();
		__weak MDImporter *weakSelf = self;
		dispatch_async(_workQueue, ^{
			[weakSelf pruneOldFiles];
		});
	}
	return self;
}

- (void)pruneOldFiles {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - (7 * 24 * 60 * 60);
	NSArray<NSString *> *directories = @[MDInboxDirectory, MDArtworkDirectory];

	for (NSString *directory in directories) {
		NSArray<NSString *> *contents = [manager contentsOfDirectoryAtPath:directory error:nil];
		for (NSString *name in contents) {
			NSString *path = [directory stringByAppendingPathComponent:name];
			NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
			NSDate *modified = attributes[NSFileModificationDate];
			if (modified && modified.timeIntervalSince1970 < cutoff) {
				[manager removeItemAtPath:path error:nil];
			}
		}
	}
}

- (void)beginKeepAlive {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIApplication *application = [UIApplication sharedApplication];
		if (self.backgroundTask == UIBackgroundTaskInvalid) {
			__weak MDImporter *weakSelf = self;
			self.backgroundTask = [application beginBackgroundTaskWithName:@"MusicDropImport"
														 expirationHandler:^{
				dispatch_async(dispatch_get_main_queue(), ^{
					[weakSelf endKeepAlive];
				});
			}];
			MDLog(@"Started background task %lu", (unsigned long)self.backgroundTask);
		}

		self.keepAliveGeneration++;
		NSUInteger generation = self.keepAliveGeneration;
		__weak MDImporter *weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180.0 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			if (weakSelf.keepAliveGeneration == generation) {
				[weakSelf endKeepAlive];
			}
		});
	});
}

- (void)endKeepAlive {
	if (self.backgroundTask != UIBackgroundTaskInvalid) {
		[[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
		MDLog(@"Ended background task %lu", (unsigned long)self.backgroundTask);
		self.backgroundTask = UIBackgroundTaskInvalid;
	}
}

- (BOOL)copyURL:(NSURL *)source toPath:(NSString *)destination error:(NSError **)error {
	BOOL scoped = [source startAccessingSecurityScopedResource];
	__block BOOL copied = NO;
	__block NSError *copyError = nil;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	[coordinator coordinateReadingItemAtURL:source
									options:NSFileCoordinatorReadingWithoutChanges
									  error:&copyError
								 byAccessor:^(NSURL *newURL) {
		NSError *innerError = nil;
		copied = [[NSFileManager defaultManager] copyItemAtURL:newURL toURL:[NSURL fileURLWithPath:destination] error:&innerError];
		if (!copied) {
			copyError = innerError;
		}
	}];
	if (scoped) {
		[source stopAccessingSecurityScopedResource];
	}
	if (!copied) {
		[[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
		if (error) {
			*error = copyError ?: MDError(@"Could not copy the file into MusicDrop's inbox.");
		}
	}
	return copied;
}

- (NSDictionary *)metadataForAssetAtPath:(NSString *)path seed:(NSDictionary *)seed {
	NSMutableDictionary *result = [seed mutableCopy];
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
										   options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
	@try {
		double duration = CMTimeGetSeconds(asset.duration);
		if (isfinite(duration) && duration > 0) {
			result[@"duration"] = @(duration);
		}

		for (NSString *format in asset.availableMetadataFormats) {
			for (AVMetadataItem *item in [asset metadataForFormat:format]) {
				NSString *commonKey = item.commonKey;
				NSString *identifier = item.identifier ?: @"";
				id value = item.value;

				if ([commonKey isEqualToString:AVMetadataCommonKeyTitle] && [result[@"title"] length] == 0) {
					result[@"title"] = MDSafeString(value);
				} else if ([commonKey isEqualToString:AVMetadataCommonKeyArtist] && [result[@"artist"] length] == 0) {
					result[@"artist"] = MDSafeString(value);
				} else if ([commonKey isEqualToString:AVMetadataCommonKeyAlbumName] && [result[@"album"] length] == 0) {
					result[@"album"] = MDSafeString(value);
				} else if ([commonKey isEqualToString:AVMetadataCommonKeyCopyrights]) {
					NSString *copyright = MDSafeString(value);
					if (copyright.length > 0 && [result[@"copyright"] length] == 0) {
						result[@"copyright"] = copyright;
					}
				} else if ([commonKey isEqualToString:AVMetadataCommonKeyCreationDate]) {
					int year = MDYearFromValue(value);
					if (year > 0 && !result[@"year"]) {
						result[@"year"] = @(year);
					}
				} else if ([commonKey isEqualToString:AVMetadataCommonKeyArtwork]) {
					NSData *data = MDArtworkDataFromItem(item);
					if (data && !result[@"artworkData"]) {
						result[@"artworkData"] = data;
					}
				}

				if (MDIdentifierMatchesField(identifier, MDMetadataFieldGenre) ||
					[identifier containsString:@"TCON"]) {
					NSString *genre = MDSafeString(value);
					if (genre.length > 0 && [result[@"genre"] length] == 0) {
						result[@"genre"] = genre;
					}
				} else if (MDIdentifierMatchesField(identifier, MDMetadataFieldComposer) ||
						   [identifier containsString:@"TCOM"]) {
					NSString *composer = MDSafeString(value);
					if (composer.length > 0 && [result[@"composer"] length] == 0) {
						result[@"composer"] = composer;
					}
				} else if (MDIdentifierMatchesField(identifier, MDMetadataFieldCopyright)) {
					NSString *copyright = MDSafeString(value);
					if (copyright.length > 0 && [result[@"copyright"] length] == 0) {
						result[@"copyright"] = copyright;
					}
				} else if (MDIdentifierMatchesField(identifier, MDMetadataFieldTrackNumber) ||
						   [identifier containsString:@"trkn"] ||
						   [identifier containsString:@"TRCK"]) {
					int track = [result[@"trackNumber"] intValue];
					int count = [result[@"trackCount"] intValue];
					MDReadTrackNumbers(value, &track, &count);
					result[@"trackNumber"] = @(track);
					result[@"trackCount"] = @(count);
				} else if (MDIdentifierMatchesField(identifier, MDMetadataFieldYear)) {
					int year = MDYearFromValue(value);
					if (year > 0 && !result[@"year"]) {
						result[@"year"] = @(year);
					}
				} else if (MDIdentifierMatchesField(identifier, MDMetadataFieldArtwork) ||
						   [identifier containsString:@"covr"] ||
						   [identifier containsString:@"APIC"]) {
					NSData *data = MDArtworkDataFromItem(item);
					if (data && !result[@"artworkData"]) {
						result[@"artworkData"] = data;
					}
				} else if (MDIdentifierMatchesField(identifier, MDMetadataFieldAlbumArtist) ||
						   [identifier containsString:@"aART"] ||
						   [identifier containsString:@"TPE2"]) {
					NSString *albumArtist = MDSafeString(value);
					if (albumArtist.length > 0 && [result[@"albumArtist"] length] == 0) {
						result[@"albumArtist"] = albumArtist;
					}
				}
			}
		}
	} @catch (NSException *exception) {
		MDLog(@"Metadata read failed for %@: %@", path.lastPathComponent, exception.reason);
	}
	return result;
}

- (NSDictionary *)prepareItemAtURL:(NSURL *)url error:(NSError **)error {
	NSString *extension = url.pathExtension.lowercaseString;
	if (!MDIsSupportedExtension(extension)) {
		NSString *reason = extension.length > 0
			? [NSString stringWithFormat:@"%@: .%@ files are not supported by the Music app. Convert to MP3 or M4A first.", url.lastPathComponent, extension]
			: [NSString stringWithFormat:@"%@: the file has no recognizable audio extension.", url.lastPathComponent];
		if (error) {
			*error = MDError(reason);
		}
		return nil;
	}

	NSString *token = MDRandomToken();
	NSString *fileName = [NSString stringWithFormat:@"%@.%@", token, extension];
	NSString *destination = [MDInboxDirectory stringByAppendingPathComponent:fileName];

	NSError *copyError = nil;
	if (![self copyURL:url toPath:destination error:&copyError]) {
		if (error) {
			*error = copyError;
		}
		return nil;
	}
	[[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
									 ofItemAtPath:destination
											error:nil];

	NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
	NSNumber *fileSize = attributes[NSFileSize];
	if (fileSize && fileSize.unsignedLongLongValue == 0) {
		[[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
		if (error) {
			*error = MDError([NSString stringWithFormat:@"%@ is empty.", url.lastPathComponent]);
		}
		return nil;
	}

	NSString *baseName = [url.lastPathComponent stringByDeletingPathExtension];
	NSMutableDictionary *metadata = [@{
		@"trackNumber": @1,
		@"trackCount": @1,
	} mutableCopy];

	metadata = [[self metadataForAssetAtPath:destination seed:metadata] mutableCopy];

	NSString *artist = MDSafeString(metadata[@"artist"]);
	NSString *title = MDSafeString(metadata[@"title"]);
	if (artist.length == 0 && [baseName containsString:@" - "]) {
		NSRange separator = [baseName rangeOfString:@" - "];
		NSString *possibleArtist = [[baseName substringToIndex:separator.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSString *possibleTitle = [[baseName substringFromIndex:NSMaxRange(separator)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		if (possibleArtist.length > 0 && possibleTitle.length > 0) {
			artist = possibleArtist;
			if (title.length == 0) {
				title = possibleTitle;
			}
		}
	}
	if (title.length == 0) {
		title = baseName.length > 0 ? baseName : @"Unknown Title";
	}
	if (artist.length == 0) {
		artist = @"Unknown Artist";
	}

	NSString *album = MDSafeString(metadata[@"album"]);
	if (album.length == 0) {
		album = @"Unknown Album";
	}
	NSString *albumArtist = MDSafeString(metadata[@"albumArtist"]);
	if (albumArtist.length == 0) {
		albumArtist = artist;
	}

	NSData *artworkData = metadata[@"artworkData"];
	NSData *artworkJPEG = artworkData.length > 0 ? MDResizedJPEG(artworkData, 1200) : nil;
	artworkJPEG = artworkJPEG ?: MDDefaultArtwork();
	NSString *artworkPath = [MDArtworkDirectory stringByAppendingPathComponent:
							 [NSString stringWithFormat:@"%@.jpg", token]];
	if (artworkJPEG.length > 0) {
		[artworkJPEG writeToFile:artworkPath atomically:YES];
		[[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
										 ofItemAtPath:artworkPath
												error:nil];
	} else {
		MDLog(@"Could not produce artwork for %@", url.lastPathComponent);
	}

	int year = [metadata[@"year"] intValue];
	if (year <= 0) {
		year = (int)[[NSCalendar currentCalendar] component:NSCalendarUnitYear fromDate:[NSDate date]];
	}

	// Lyrics are embedded by the unsandboxed helper (FFmpeg cannot be spawned
	// from inside Music). Failure is non-fatal; the file imports without lyrics.
	if ([MDPreferences embedLyrics]) {
		NSError *lyricsError = nil;
		[MDHelperClient runOperation:@{
			MDHelperOperationKey: MDHelperOperationLyrics,
			MDHelperPathKey: destination,
			MDHelperTitleKey: title,
			MDHelperArtistKey: artist,
			MDHelperAlbumKey: album,
			MDHelperDurationKey: metadata[@"duration"] ?: @0,
		} progress:nil error:&lyricsError];
		if (lyricsError) {
			MDLog(@"Lyrics: helper failed for '%@': %@", title, lyricsError.localizedDescription);
		}
	}

	return @{
		@"filePath": destination,
		@"artworkPath": artworkPath,
		@"extension": extension,
		@"kind": @(MDKindForExtension(extension)),
		@"title": title,
		@"artist": artist,
		@"album": album,
		@"albumArtist": albumArtist,
		@"genre": MDSafeString(metadata[@"genre"]) ?: @"",
		@"composer": MDSafeString(metadata[@"composer"]) ?: @"",
		@"copyright": MDSafeString(metadata[@"copyright"]) ?: @"",
		@"year": @(year),
		@"trackNumber": @(MAX(1, [metadata[@"trackNumber"] intValue])),
		@"trackCount": @(MAX(1, [metadata[@"trackCount"] intValue])),
		@"duration": @([metadata[@"duration"] doubleValue]),
	};
}

- (BOOL)loadStoreServices {
	static BOOL available;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void *handle = dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices",
							  RTLD_NOW | RTLD_GLOBAL);
		if (!handle) {
			const char *reason = dlerror();
			MDLog(@"StoreServices dlopen failed: %s", reason ?: "unknown");
		}
		available = NSClassFromString(@"SSDownloadMetadata") != nil &&
					NSClassFromString(@"SSDownload") != nil &&
					NSClassFromString(@"SSDownloadQueue") != nil;
		MDLog(@"StoreServices available: %@", available ? @"yes" : @"no");
	});
	return available;
}

- (BOOL)enqueueItem:(NSDictionary *)item error:(NSError **)error {
	if (![self loadStoreServices]) {
		if (error) {
			*error = MDError(@"Music's private StoreServices framework could not be loaded.");
		}
		return NO;
	}

	MDServer *server = [MDServer sharedServer];
	NSURL *audioURL = [server registerFilePath:item[@"filePath"] extension:item[@"extension"]];
	NSURL *artworkURL = [server registerFilePath:item[@"artworkPath"] extension:@"jpg"];
	if (!audioURL || !artworkURL) {
		if (error) {
			*error = MDError(@"The on-device file server could not start.");
		}
		return NO;
	}

	int itemID = (int)(arc4random_uniform(100000000) + 1);
	int durationMS = (int)llround([item[@"duration"] doubleValue] * 1000.0);
	if (durationMS < 0) {
		durationMS = 0;
	}

	NSString *title = item[@"title"];
	NSString *artist = item[@"artist"];
	NSString *album = item[@"album"];
	NSString *genre = item[@"genre"];
	NSString *composer = item[@"composer"];
	NSString *copyright = item[@"copyright"];
	NSString *kind = MDKindString([item[@"kind"] integerValue]);

	NSDictionary *payload = @{
		@"purchaseDate": [NSDate date],
		@"is-purchased-redownload": @YES,
		@"URL": audioURL.absoluteString,
		@"artworkURL": artworkURL.absoluteString,
		@"artwork-urls": @{
			@"default": @{@"url": artworkURL.absoluteString},
			@"image-type": @"download-queue-item",
		},
		@"songId": @(itemID),
		@"metadata": @{
			@"artistName": artist,
			@"compilation": @NO,
			@"composerName": composer,
			@"copyright": copyright,
			@"description": copyright,
			@"longDescription": copyright,
			@"drmVersionNumber": @0,
			@"duration": @(durationMS),
			@"explicit": @0,
			@"fileExtension": item[@"extension"],
			@"gapless": @NO,
			@"genre": genre,
			@"isMasteredForItunes": @NO,
			@"itemId": @(itemID),
			@"itemName": title,
			@"kind": kind,
			@"playlistArtistName": artist,
			@"playlistName": album,
			@"releaseDate": [NSDate date],
			@"sort-album": album,
			@"sort-artist": artist,
			@"sort-composer": composer,
			@"sort-name": title,
			@"trackCount": item[@"trackCount"],
			@"trackNumber": item[@"trackNumber"],
			@"year": item[@"year"],
		},
	};

	@try {
		Class metadataClass = NSClassFromString(@"SSDownloadMetadata");
		Class downloadClass = NSClassFromString(@"SSDownload");
		Class queueClass = NSClassFromString(@"SSDownloadQueue");
		if (!metadataClass || !downloadClass || !queueClass) {
			if (error) {
				*error = MDError(@"Music's private StoreServices classes are unavailable.");
			}
			return NO;
		}

		SSDownloadMetadata *metadata = [[metadataClass alloc] initWithDictionary:payload];
		if (!metadata) {
			if (error) {
				*error = MDError(@"Music rejected the import metadata.");
			}
			return NO;
		}

		if ([metadata respondsToSelector:@selector(setPrimaryAssetURL:)]) {
			[metadata setPrimaryAssetURL:audioURL];
		}
		if ([metadata respondsToSelector:@selector(setShouldDownloadAutomatically:)]) {
			[metadata setShouldDownloadAutomatically:YES];
		}

		SSDownload *download = [[downloadClass alloc] initWithDownloadMetadata:metadata];
		if (!download) {
			if (error) {
				*error = MDError(@"Music could not create a download for this file.");
			}
			return NO;
		}

		if (!self.downloadQueue) {
			id (*sendClassId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
			id kinds = sendClassId((id)queueClass, @selector(mediaDownloadKinds));
			if (!kinds) {
				if (error) {
					*error = MDError(@"Music did not report any supported download kinds.");
				}
				return NO;
			}
			self.downloadQueue = [[queueClass alloc] initWithDownloadKinds:kinds];
			if ([self.downloadQueue respondsToSelector:@selector(setShouldAutomaticallyFinishDownloads:)]) {
				[self.downloadQueue setShouldAutomaticallyFinishDownloads:YES];
			}
		}

		if (!self.downloadQueue) {
			if (error) {
				*error = MDError(@"Music's import queue could not be created.");
			}
			return NO;
		}

		BOOL added = [self.downloadQueue addDownload:download];
		if (!added) {
			if (error) {
				*error = MDError(@"Music declined to enqueue this file.");
			}
			return NO;
		}

		MDLog(@"Enqueued '%@' by '%@' (%@ -> %@)", title, artist,
			  [(NSString *)item[@"filePath"] lastPathComponent], audioURL.absoluteString);
		return YES;
	} @catch (NSException *exception) {
		MDLog(@"Import exception: %@", exception.reason);
		if (error) {
			*error = MDError([NSString stringWithFormat:@"Music's importer threw an error: %@",
							  exception.reason ?: @"unknown"]);
		}
		return NO;
	}
}

- (void)importURLs:(NSArray<NSURL *> *)urls
		  progress:(MDImportProgressBlock)progress
		completion:(MDImportCompletionBlock)completion {
	NSArray<NSURL *> *snapshot = [urls copy];
	if (snapshot.count == 0) {
		if (completion) {
			completion(0, @[]);
		}
		return;
	}

	[self beginKeepAlive];

	__weak MDImporter *weakSelf = self;
	dispatch_async(self.workQueue, ^{
		__block NSUInteger imported = 0;
		NSMutableArray<NSString *> *errors = [NSMutableArray array];

		for (NSUInteger index = 0; index < snapshot.count; index++) {
			@autoreleasepool {
				NSString *status = [NSString stringWithFormat:@"Importing %lu of %lu…",
									(unsigned long)(index + 1), (unsigned long)snapshot.count];
				dispatch_async(dispatch_get_main_queue(), ^{
					if (progress) {
						progress(status);
					}
				});

				NSError *prepareError = nil;
				NSDictionary *item = [weakSelf prepareItemAtURL:snapshot[index] error:&prepareError];
				if (!item) {
					NSString *message = prepareError.localizedDescription ?: @"Unknown error";
					[errors addObject:message];
					MDLog(@"Prepare failed: %@", message);
					continue;
				}

				dispatch_sync(dispatch_get_main_queue(), ^{
					NSError *enqueueError = nil;
					if ([weakSelf enqueueItem:item error:&enqueueError]) {
						imported++;
					} else {
						NSString *message = [NSString stringWithFormat:@"%@: %@",
											 snapshot[index].lastPathComponent,
											 enqueueError.localizedDescription ?: @"Unknown error"];
						[errors addObject:message];
						MDLog(@"Enqueue failed: %@", message);
					}
				});
			}
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf beginKeepAlive]; // Extend the server's lifetime while Music downloads.
			if (completion) {
				completion(imported, errors);
			}
		});
	});
}

@end
