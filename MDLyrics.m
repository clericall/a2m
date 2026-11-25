#import "MDLyrics.h"
#import "MDLog.h"

#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *const MDLyricsEndpoint = @"https://lrclib.net/api/search";
static NSString *const MDLyricsCacheRoot = @"/var/mobile/Media/MusicDrop/lyrics";
static NSUInteger const MDLyricsMaximumCharacters = 20000;

static BOOL MDCanEmbedLyrics(NSString *extension) {
	static NSSet<NSString *> *supported;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		supported = [NSSet setWithArray:@[
			@"mp3", @"m4a", @"m4b", @"m4r", @"mp4", @"m4v", @"mov",
		]];
	});
	return [supported containsObject:extension.lowercaseString];
}

static NSString *MDFindFFmpeg(void) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSArray<NSString *> *paths = @[
		@"/var/jb/usr/bin/ffmpeg",
		@"/var/jb/usr/local/bin/ffmpeg",
		@"/var/jb/bin/ffmpeg",
		@"/usr/bin/ffmpeg",
		@"/usr/local/bin/ffmpeg",
	];
	for (NSString *path in paths) {
		if ([manager isExecutableFileAtPath:path]) {
			return path;
		}
	}
	return nil;
}

/// Runs ffmpeg with stdout kept and stderr discarded. Returns the exit status,
/// or -1 when the process could not be started.
static NSInteger MDRunFFmpeg(NSArray<NSString *> *arguments) {
	char **argv = calloc(arguments.count + 1, sizeof(char *));
	if (!argv) {
		return -1;
	}
	for (NSUInteger index = 0; index < arguments.count; index++) {
		argv[index] = (char *)arguments[index].UTF8String;
	}

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

	pid_t process = 0;
	int spawnResult = posix_spawn(&process, arguments[0].fileSystemRepresentation,
								  &actions, NULL, argv, NULL);
	posix_spawn_file_actions_destroy(&actions);
	free(argv);

	if (spawnResult != 0) {
		MDLog(@"Lyrics: could not start ffmpeg: %s", strerror(spawnResult));
		return -1;
	}

	int status = 0;
	while (waitpid(process, &status, 0) < 0 && errno == EINTR) {
	}
	if (WIFEXITED(status)) {
		return WEXITSTATUS(status);
	}
	return -1;
}

@implementation MDLyrics

+ (instancetype)sharedLyrics {
	static MDLyrics *lyrics;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		lyrics = [[MDLyrics alloc] init];
	});
	return lyrics;
}

+ (NSString *)lyricsKeyForTitle:(NSString *)title artist:(NSString *)artist {
	NSString *base = [NSString stringWithFormat:@"%@|%@",
		title.lowercaseString ?: @"", artist.lowercaseString ?: @""];
	unsigned char digest[CC_MD5_DIGEST_LENGTH];
	CC_MD5(base.UTF8String, (CC_LONG)[base lengthOfBytesUsingEncoding:NSUTF8StringEncoding], digest);
	NSMutableString *key = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
	for (NSUInteger index = 0; index < CC_MD5_DIGEST_LENGTH; index++) {
		[key appendFormat:@"%02x", digest[index]];
	}
	return key;
}

+ (nullable NSString *)readSidecarWithExtension:(NSString *)extension title:(NSString *)title artist:(NSString *)artist {
	NSString *path = [MDLyricsCacheRoot stringByAppendingPathComponent:
		[NSString stringWithFormat:@"%@.%@", [self lyricsKeyForTitle:title artist:artist], extension]];
	NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
	return text.length > 0 ? text : nil;
}

+ (nullable NSString *)plainLyricsForTitle:(NSString *)title artist:(NSString *)artist {
	return [self readSidecarWithExtension:@"plain" title:title artist:artist];
}

+ (nullable NSString *)syncedLyricsForTitle:(NSString *)title artist:(NSString *)artist {
	return [self readSidecarWithExtension:@"lrc" title:title artist:artist];
}

+ (void)saveLyricsForTitle:(NSString *)title artist:(NSString *)artist result:(NSDictionary *)result {
	NSFileManager *manager = [NSFileManager defaultManager];
	if (![manager fileExistsAtPath:MDLyricsCacheRoot]) {
		[manager createDirectoryAtPath:MDLyricsCacheRoot withIntermediateDirectories:YES
							attributes:@{NSFileProtectionKey: NSFileProtectionNone} error:nil];
	}
	NSString *key = [self lyricsKeyForTitle:title artist:artist];
	NSDictionary *files = @{
		@"plain": result[@"plainLyrics"] ?: @"",
		@"lrc": result[@"syncedLyrics"] ?: @"",
	};
	for (NSString *extension in files) {
		NSString *text = files[extension];
		if (text.length == 0) {
			continue;
		}
		NSString *path = [MDLyricsCacheRoot stringByAppendingPathComponent:
			[NSString stringWithFormat:@"%@.%@", key, extension]];
		[text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
}

- (nullable NSString *)fetchLyricsForTitle:(NSString *)title
									 artist:(NSString *)artist
									  album:(nullable NSString *)album
								   duration:(double)duration {
	NSURLComponents *components = [NSURLComponents componentsWithString:MDLyricsEndpoint];
	NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
	[items addObject:[NSURLQueryItem queryItemWithName:@"track_name" value:title]];
	if (artist.length > 0 && ![artist isEqualToString:@"Unknown Artist"]) {
		[items addObject:[NSURLQueryItem queryItemWithName:@"artist_name" value:artist]];
	}
	components.queryItems = items;

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL
													  cachePolicy:NSURLRequestUseProtocolCachePolicy
												  timeoutInterval:10.0];
	[request setValue:@"MusicDrop/1.2" forHTTPHeaderField:@"User-Agent"];

	__block NSData *responseData = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
		completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
		responseData = data;
		dispatch_semaphore_signal(semaphore);
	}];
	[task resume];
	dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC));
	if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
		[task cancel];
		MDLog(@"Lyrics: request timed out for '%@'", title);
		return nil;
	}

	if (responseData.length == 0) {
		return nil;
	}

	NSArray *results = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
	if (![results isKindOfClass:[NSArray class]]) {
		MDLog(@"Lyrics: unexpected response for '%@'", title);
		return nil;
	}

	NSDictionary *best = nil;
	NSInteger bestScore = NSIntegerMax;
	for (id rawCandidate in results) {
		if (![rawCandidate isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		NSDictionary *candidate = (NSDictionary *)rawCandidate;
		NSString *synced = candidate[@"syncedLyrics"];
		NSString *plain = candidate[@"plainLyrics"];
		NSString *text = synced.length > 0 ? synced : plain;
		if (text.length == 0) {
			continue;
		}

		NSInteger score = 0;
		if (duration > 0) {
			double candidateDuration = [candidate[@"duration"] doubleValue];
			double delta = fabs(candidateDuration - duration);
			if (delta > 15.0) {
				continue;
			}
			score += (NSInteger)delta;
		}
		if (synced.length == 0) {
			score += 5;
		}
		if (album.length > 0 && [candidate[@"albumName"] isKindOfClass:[NSString class]] &&
			![candidate[@"albumName"] isEqualToString:album]) {
			score += 2;
		}
		if (score < bestScore) {
			bestScore = score;
			best = candidate;
		}
	}

	NSString *syncedLyrics = best[@"syncedLyrics"];
	NSString *plainLyrics = best[@"plainLyrics"];
	[self saveLyricsForTitle:title artist:artist result:best];
	NSString *lyrics = syncedLyrics.length > 0 ? syncedLyrics : plainLyrics;
	if (![lyrics isKindOfClass:[NSString class]] || lyrics.length == 0) {
		MDLog(@"Lyrics: no match for '%@' by '%@'", title, artist);
		return nil;
	}
	if (lyrics.length > MDLyricsMaximumCharacters) {
		lyrics = [lyrics substringToIndex:MDLyricsMaximumCharacters];
	}
	return lyrics;
}

- (BOOL)embedLyricsForTitle:(NSString *)title
					  artist:(NSString *)artist
					   album:(NSString *)album
					duration:(double)duration
			   intoFileAtPath:(NSString *)path
				   extension:(NSString *)extension {
	if (!MDCanEmbedLyrics(extension)) {
		return NO;
	}

	NSString *ffmpeg = MDFindFFmpeg();
	if (!ffmpeg) {
		MDLog(@"Lyrics: FFmpeg is not installed; skipping lyrics for '%@'", title);
		return NO;
	}

	NSString *lyrics = [self fetchLyricsForTitle:title artist:artist album:album duration:duration];
	if (!lyrics) {
		return NO;
	}

	NSString *token = [[NSUUID UUID].UUIDString lowercaseString];
	token = [token stringByReplacingOccurrencesOfString:@"-" withString:@""];
	NSString *temporaryPath = [path stringByAppendingFormat:@".lyrics-%@.%@", token, extension];

	// .m4r is not a registered FFmpeg extension, so force the container.
	NSString *outputFormat = [extension.lowercaseString isEqualToString:@"mp3"] ? @"mp3" : @"mp4";
	NSArray<NSString *> *arguments = @[
		ffmpeg,
		@"-hide_banner", @"-loglevel", @"error", @"-nostdin", @"-y",
		@"-i", path,
		@"-map", @"0",
		@"-c", @"copy",
		@"-metadata", [NSString stringWithFormat:@"lyrics=%@", lyrics],
		@"-f", outputFormat,
		temporaryPath,
	];

	NSInteger status = MDRunFFmpeg(arguments);
	if (status != 0) {
		MDLog(@"Lyrics: ffmpeg failed with status %ld for '%@'", (long)status, title);
		[[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
		return NO;
	}

	NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:temporaryPath error:nil];
	unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
	if (size == 0) {
		MDLog(@"Lyrics: ffmpeg produced an empty file for '%@'", title);
		[[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
		return NO;
	}

	NSError *replaceError = nil;
	BOOL replaced = [[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:path]
								withItemAtURL:[NSURL fileURLWithPath:temporaryPath]
							   backupItemName:nil
									  options:NSFileManagerItemReplacementUsingNewMetadataOnly
							 resultingItemURL:nil
										error:&replaceError];
	if (!replaced) {
		MDLog(@"Lyrics: could not replace file for '%@: %@'", title, replaceError.localizedDescription);
		[[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
		return NO;
	}

	[[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
									 ofItemAtPath:path
											error:nil];
	MDLog(@"Lyrics: embedded %lu characters into '%@'", (unsigned long)lyrics.length, title);
	return YES;
}

@end
