#import "MDDownloadManager.h"
#import "MDHelperClient.h"
#import "MDHelperProtocol.h"
#import "MDLog.h"
#import "MDPreferences.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <spawn.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *const MDDownloadRoot = @"/var/mobile/Media/MusicDrop/downloads";
static NSString *const MDDownloadTemporaryRoot = @"/var/mobile/Media/MusicDrop/tmp";
static unsigned long long const MDMaximumDownloadBytes = 500ULL * 1024ULL * 1024ULL;

@interface MDDownloadManager ()

@property (nonatomic, strong) dispatch_queue_t workQueue;

@end


static NSError *MDDownloadError(NSInteger code, NSString *message) {
	return [NSError errorWithDomain:@"com.musiccc.musicdrop.downloader"
							   code:code
						   userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void MDReportProgress(MDDownloadProgressBlock progress, NSString *status) {
	if (!progress) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		progress(status);
	});
}

static void MDFinishDownload(MDDownloadCompletionBlock completion,
							 NSURL *fileURL,
							 NSError *error) {
	if (!completion) {
		return;
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		completion(fileURL, error);
	});
}

static BOOL MDHostMatchesDomain(NSString *host, NSString *domain) {
	NSString *normalizedHost = host.lowercaseString;
	NSString *normalizedDomain = domain.lowercaseString;
	return [normalizedHost isEqualToString:normalizedDomain] ||
		   [normalizedHost hasSuffix:[@"." stringByAppendingString:normalizedDomain]];
}

static BOOL MDIsYouTubeHost(NSString *host) {
	return MDHostMatchesDomain(host, @"youtube.com") ||
		   MDHostMatchesDomain(host, @"youtu.be") ||
		   MDHostMatchesDomain(host, @"youtube-nocookie.com");
}

static BOOL MDIsSpotifyHost(NSString *host) {
	return MDHostMatchesDomain(host, @"spotify.com") ||
		   MDHostMatchesDomain(host, @"spotify.link");
}

static BOOL MDIsPrivateOrLocalHost(NSString *host) {
	NSString *normalized = host.lowercaseString;
	if ([normalized isEqualToString:@"localhost"] ||
		[normalized hasSuffix:@".localhost"] ||
		[normalized hasSuffix:@".local"]) {
		return YES;
	}

	struct in_addr ipv4;
	if (inet_pton(AF_INET, normalized.UTF8String, &ipv4) == 1) {
		uint32_t address = ntohl(ipv4.s_addr);
		uint8_t first = (uint8_t)(address >> 24);
		uint8_t second = (uint8_t)(address >> 16);
		return first == 0 || first == 10 || first == 127 ||
			   (first == 169 && second == 254) ||
			   (first == 172 && second >= 16 && second <= 31) ||
			   (first == 192 && second == 168) || first >= 224;
	}

	struct in6_addr ipv6;
	if (inet_pton(AF_INET6, normalized.UTF8String, &ipv6) == 1) {
		const uint8_t *bytes = ipv6.s6_addr;
		return IN6_IS_ADDR_UNSPECIFIED(&ipv6) ||
			   IN6_IS_ADDR_LOOPBACK(&ipv6) ||
			   IN6_IS_ADDR_LINKLOCAL(&ipv6) ||
			   (bytes[0] & 0xfe) == 0xfc;
	}

	return NO;
}

static BOOL MDIsSupportedMediaExtension(NSString *extension) {
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

static NSString *MDExtensionForMIMEType(NSString *MIMEType) {
	static NSDictionary<NSString *, NSString *> *extensions;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		extensions = @{
			@"audio/mpeg": @"mp3",
			@"audio/mp3": @"mp3",
			@"audio/mp4": @"m4a",
			@"audio/x-m4a": @"m4a",
			@"audio/aac": @"aac",
			@"audio/wav": @"wav",
			@"audio/x-wav": @"wav",
			@"audio/aiff": @"aiff",
			@"audio/x-aiff": @"aiff",
			@"audio/x-caf": @"caf",
			@"audio/flac": @"flac",
			@"audio/x-flac": @"flac",
			@"video/mp4": @"mp4",
			@"video/quicktime": @"mov",
		};
	});
	NSString *normalized = [[MIMEType componentsSeparatedByString:@";"] firstObject].lowercaseString;
	return extensions[normalized ?: @""];
}

static NSString *MDSafeBaseName(NSString *name) {
	NSString *base = [name.lastPathComponent stringByDeletingPathExtension];
	base = [base stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
	base = [[base componentsSeparatedByCharactersInSet:forbidden] componentsJoinedByString:@"_"];
	while ([base hasPrefix:@"."]) {
		base = [base substringFromIndex:1];
	}
	if (base.length == 0) {
		base = @"download";
	}
	if (base.length > 100) {
		base = [base substringToIndex:100];
	}
	return base;
}

static BOOL MDEnsureDownloadDirectories(NSError **error) {
	NSFileManager *manager = [NSFileManager defaultManager];
	for (NSString *path in @[MDDownloadRoot, MDDownloadTemporaryRoot]) {
		NSError *directoryError = nil;
		if (![manager createDirectoryAtPath:path
				 withIntermediateDirectories:YES
							  attributes:@{NSFileProtectionKey: NSFileProtectionNone}
								   error:&directoryError]) {
			if (error) {
				*error = directoryError ?: MDDownloadError(2, @"Could not create MusicDrop's download folder.");
			}
			return NO;
		}
	}
	return YES;
}

static NSString *MDUniqueDestination(NSString *suggestedName, NSString *extension) {
	NSString *base = MDSafeBaseName(suggestedName.length > 0 ? suggestedName : @"download");
	NSFileManager *manager = [NSFileManager defaultManager];
	for (NSUInteger index = 0; index < 1000; index++) {
		NSString *suffix = index == 0 ? @"" : [NSString stringWithFormat:@" (%lu)", (unsigned long)(index + 1)];
		NSString *name = [NSString stringWithFormat:@"%@%@.%@", base, suffix, extension];
		NSString *path = [MDDownloadRoot stringByAppendingPathComponent:name];
		if (![manager fileExistsAtPath:path]) {
			return path;
		}
	}
	return [MDDownloadRoot stringByAppendingPathComponent:
			[NSString stringWithFormat:@"%@.%@", [NSUUID UUID].UUIDString.lowercaseString, extension]];
}

static NSString *MDExecutableAtPaths(NSArray<NSString *> *paths) {
	NSFileManager *manager = [NSFileManager defaultManager];
	for (NSString *path in paths) {
		if ([manager isExecutableFileAtPath:path]) {
			return path;
		}
	}
	return nil;
}

static NSString *const MDYouTubeToolsDirectory = @"/var/mobile/Media/MusicDrop/bin";
static NSString *const MDYouTubeBinaryPath = @"/var/mobile/Media/MusicDrop/bin/yt-dlp";
static NSString *const MDYouTubeBinaryURL = @"https://github.com/yt-dlp/yt-dlp/releases/download/2025.10.14/yt-dlp";

/// Keeps a current pure-Python yt-dlp zipapp in the writable MusicDrop
/// folder. A Mach-O/PyInstaller binary is killed by iOS; the zipapp runs
/// under the installed python3 instead.
static BOOL MDRefreshYouTubeBinary(MDDownloadProgressBlock progress) {
	NSFileManager *manager = [NSFileManager defaultManager];
	NSError *directoryError = nil;
	if (![manager createDirectoryAtPath:MDYouTubeToolsDirectory
			withIntermediateDirectories:YES
						attributes:@{NSFileProtectionKey: NSFileProtectionNone}
							 error:&directoryError]) {
		MDLog(@"YouTube: could not create bin directory: %@", directoryError.localizedDescription);
		return NO;
	}

	NSDictionary *attributes = [manager attributesOfItemAtPath:MDYouTubeBinaryPath error:nil];
	NSDate *modified = attributes[NSFileModificationDate];
	BOOL isZipapp = NO;
	FILE *cached = fopen(MDYouTubeBinaryPath.UTF8String, "rb");
	if (cached) {
		char header[32] = {0};
		size_t count = fread(header, 1, sizeof(header) - 1, cached);
		fclose(cached);
		isZipapp = count >= 21 && strncmp(header, "#!/usr/bin/env python", 21) == 0;
	}
	BOOL fresh = isZipapp && modified && modified.timeIntervalSinceNow > -(7 * 24 * 60 * 60);
	if (fresh) {
		MDLog(@"YouTube: using cached yt-dlp zipapp");
		return YES;
	}

	MDLog(@"YouTube: downloading current yt-dlp");
	MDReportProgress(progress, @"Downloading current yt-dlp…");
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:MDYouTubeBinaryURL]
													  cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
													  timeoutInterval:180.0];
	[request setValue:@"MusicDrop/1.5" forHTTPHeaderField:@"User-Agent"];

	__block NSURL *downloadedFile = nil;
	__block NSError *downloadError = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	NSURLSession *session = [NSURLSession sharedSession];
	NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request
		completionHandler:^(NSURL *location, __unused NSURLResponse *response, NSError *error) {
		downloadedFile = location;
		downloadError = error;
		dispatch_semaphore_signal(semaphore);
	}];
	[task resume];
	dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(190.0 * NSEC_PER_SEC));
	if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
		[task cancel];
		MDLog(@"YouTube: timed out downloading yt-dlp.");
		return NO;
	}
	if (downloadError || !downloadedFile) {
		MDLog(@"YouTube: yt-dlp download error: %@", downloadError.localizedDescription);
		return NO;
	}

	NSDictionary *downloadAttributes = [manager attributesOfItemAtPath:downloadedFile.path error:nil];
	unsigned long long size = [downloadAttributes[NSFileSize] unsignedLongLongValue];
	if (size < 1 * 1024 * 1024 || size > 100 * 1024 * 1024) {
		MDLog(@"YouTube: refusing suspicious yt-dlp download (%llu bytes).", size);
		return NO;
	}

	NSString *temporaryPath = [MDYouTubeToolsDirectory stringByAppendingPathComponent:
		[NSString stringWithFormat:@"yt-dlp.%@.download", [NSUUID UUID].UUIDString]];
	if (![manager moveItemAtURL:downloadedFile toURL:[NSURL fileURLWithPath:temporaryPath] error:nil]) {
		MDLog(@"YouTube: could not move downloaded yt-dlp into place.");
		return NO;
	}
	chmod(temporaryPath.UTF8String, 0755);

	NSError *replaceError = nil;
	BOOL replaced = [manager replaceItemAtURL:[NSURL fileURLWithPath:MDYouTubeBinaryPath]
							   withItemAtURL:[NSURL fileURLWithPath:temporaryPath]
							  backupItemName:nil
									 options:NSFileManagerItemReplacementUsingNewMetadataOnly
							resultingItemURL:nil
									   error:&replaceError];
	if (!replaced) {
		MDLog(@"YouTube: could not install yt-dlp: %@", replaceError.localizedDescription);
		[manager removeItemAtPath:temporaryPath error:nil];
		return NO;
	}
	MDLog(@"YouTube: installed yt-dlp (%llu bytes)", size);
	MDReportProgress(progress, @"yt-dlp ready.");
	return YES;
}

static NSArray<NSString *> *MDYouTubeLauncher(MDDownloadProgressBlock progress) {
	NSString *python = MDExecutableAtPaths(@[
		@"/var/jb/usr/bin/python3",
		@"/var/jb/bin/python3",
		@"/usr/bin/python3",
		@"/usr/local/bin/python3",
	]);
	if (MDRefreshYouTubeBinary(progress) && python) {
		return @[python, MDYouTubeBinaryPath];
	}
	NSString *installed = MDExecutableAtPaths(@[
		@"/var/jb/usr/bin/yt-dlp",
		@"/var/jb/usr/local/bin/yt-dlp",
		@"/usr/bin/yt-dlp",
		@"/usr/local/bin/yt-dlp",
	]);
	return installed ? @[installed] : nil;
}

static NSString *MDLastUsefulOutputLine(NSString *output) {
	NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
	for (NSString *line in [lines reverseObjectEnumerator]) {
		NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (trimmed.length > 0 && ![trimmed containsString:@"MD_FILE:"]) {
			return trimmed;
		}
	}
	return nil;
}

@implementation MDDownloadManager

+ (instancetype)sharedManager {
	static MDDownloadManager *manager;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		manager = [[MDDownloadManager alloc] init];
	});
	return manager;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_workQueue = dispatch_queue_create("com.musiccc.musicdrop.downloader", DISPATCH_QUEUE_SERIAL);
		dispatch_async(_workQueue, ^{
			[self pruneOldDownloads];
		});
	}
	return self;
}

- (void)pruneOldDownloads {
	if (!MDEnsureDownloadDirectories(nil)) {
		return;
	}
	NSFileManager *manager = [NSFileManager defaultManager];
	NSTimeInterval cutoff = [[NSDate date] timeIntervalSince1970] - (7 * 24 * 60 * 60);
	for (NSString *directory in @[MDDownloadRoot, MDDownloadTemporaryRoot]) {
		for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:nil]) {
			NSString *path = [directory stringByAppendingPathComponent:name];
			NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
			NSDate *modified = attributes[NSFileModificationDate];
			if (modified && modified.timeIntervalSince1970 < cutoff) {
				[manager removeItemAtPath:path error:nil];
			}
		}
	}
}

- (NSError *)validationErrorForURL:(NSURL *)url {
	if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] || url.host.length == 0) {
		return MDDownloadError(10, @"Enter a complete HTTPS URL.");
	}
	if (url.user.length > 0 || url.password.length > 0) {
		return MDDownloadError(11, @"URLs containing a username or password are not accepted.");
	}
	if (MDIsPrivateOrLocalHost(url.host)) {
		return MDDownloadError(12, @"Local and private-network URLs are not accepted.");
	}
	return nil;
}

- (void)downloadURL:(NSURL *)url
		   progress:(MDDownloadProgressBlock)progress
		 completion:(MDDownloadCompletionBlock)completion {
	NSError *validationError = [self validationErrorForURL:url];
	if (validationError) {
		MDFinishDownload(completion, nil, validationError);
		return;
	}

	if (MDIsSpotifyHost(url.host)) {
		MDFinishDownload(completion, nil, MDDownloadError(20,
			@"Spotify does not provide full-track audio downloads. Its offline files are encrypted and cannot be imported. Use a DRM-free file you own instead."));
		return;
	}

	if (MDIsYouTubeHost(url.host)) {
		MDReportProgress(progress, @"Starting YouTube download…");
		[MDHelperClient runOperation:@{
			MDHelperOperationKey: MDHelperOperationYouTube,
			MDHelperURLKey: url.absoluteString,
		} progress:^(NSString *status) {
			MDReportProgress(progress, status);
		} completion:^(NSDictionary *response, NSError *helperError) {
			if (helperError) {
				MDFinishDownload(completion, nil, helperError);
				return;
			}
			NSString *path = response[MDHelperResultPathKey];
			MDFinishDownload(completion,
							 path.length > 0 ? [NSURL fileURLWithPath:path] : nil,
							 path.length > 0 ? nil : MDDownloadError(47, @"The helper returned no file."));
		}];
		return;
	}

	[self downloadDirectURL:url progress:progress completion:completion];
}

- (void)searchYouTube:(NSString *)query
			 progress:(MDDownloadProgressBlock)progress
		   completion:(MDDownloadCompletionBlock)completion {
	NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (trimmed.length == 0) {
		MDFinishDownload(completion, nil, MDDownloadError(50, @"Enter a song or artist name."));
		return;
	}
	if (trimmed.length > 200) {
		trimmed = [trimmed substringToIndex:200];
	}
	MDReportProgress(progress, @"Searching YouTube…");
	[MDHelperClient runOperation:@{
		MDHelperOperationKey: MDHelperOperationYouTube,
		MDHelperQueryKey: trimmed,
	} progress:^(NSString *status) {
		MDReportProgress(progress, status);
	} completion:^(NSDictionary *response, NSError *helperError) {
		if (helperError) {
			MDFinishDownload(completion, nil, helperError);
			return;
		}
		NSString *path = response[MDHelperResultPathKey];
		MDFinishDownload(completion,
						 path.length > 0 ? [NSURL fileURLWithPath:path] : nil,
						 path.length > 0 ? nil : MDDownloadError(51, @"No matching video was found."));
	}];
}

- (void)downloadDirectURL:(NSURL *)url
				  progress:(MDDownloadProgressBlock)progress
				completion:(MDDownloadCompletionBlock)completion {
	NSError *directoryError = nil;
	if (!MDEnsureDownloadDirectories(&directoryError)) {
		MDFinishDownload(completion, nil, directoryError);
		return;
	}

	MDReportProgress(progress, @"Downloading audio…");
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	request.timeoutInterval = 60.0;
	[request setValue:@"MusicDrop/1.1" forHTTPHeaderField:@"User-Agent"];

	NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	configuration.timeoutIntervalForRequest = 60.0;
	configuration.timeoutIntervalForResource = 60.0 * 60.0;
	configuration.HTTPMaximumConnectionsPerHost = 1;

	__block NSURLSession *session = nil;
	session = [NSURLSession sessionWithConfiguration:configuration];
	NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request
		completionHandler:^(NSURL *temporaryURL, NSURLResponse *response, NSError *networkError) {
		[session finishTasksAndInvalidate];
		session = nil;

		if (networkError) {
			MDLog(@"Direct download failed for %@: %@", url.absoluteString, networkError.localizedDescription);
			MDFinishDownload(completion, nil, MDDownloadError(30,
				[NSString stringWithFormat:@"Download failed: %@", networkError.localizedDescription]));
			return;
		}

		if (!temporaryURL || !response) {
			MDFinishDownload(completion, nil, MDDownloadError(31, @"The server returned no downloadable file."));
			return;
		}

		if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
			NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
			if (status < 200 || status >= 300) {
				MDFinishDownload(completion, nil, MDDownloadError(32,
					[NSString stringWithFormat:@"The server returned HTTP %ld.", (long)status]));
				return;
			}
		}

		if (response.expectedContentLength > 0 &&
			(unsigned long long)response.expectedContentLength > MDMaximumDownloadBytes) {
			MDFinishDownload(completion, nil, MDDownloadError(33, @"The file is larger than MusicDrop's 500 MB limit."));
			return;
		}

		NSString *MIMEType = response.MIMEType.lowercaseString;
		if ([MIMEType hasPrefix:@"text/"] ||
			[MIMEType isEqualToString:@"application/json"] ||
			[MIMEType isEqualToString:@"application/xml"]) {
			MDFinishDownload(completion, nil, MDDownloadError(34,
				[NSString stringWithFormat:@"The URL returned %@ instead of an audio file.", MIMEType]));
			return;
		}

		NSArray<NSString *> *candidateExtensions = @[
			response.suggestedFilename.pathExtension ?: @"",
			response.URL.pathExtension ?: @"",
			url.pathExtension ?: @"",
			MDExtensionForMIMEType(MIMEType) ?: @"",
		];
		NSString *extension = nil;
		for (NSString *candidate in candidateExtensions) {
			if (MDIsSupportedMediaExtension(candidate)) {
				extension = candidate.lowercaseString;
				break;
			}
		}
		if (extension.length == 0) {
			MDFinishDownload(completion, nil, MDDownloadError(35,
				@"The server did not return a supported MP3, M4A, AAC, FLAC, WAV, AIFF, CAF, or MP4 file."));
			return;
		}

		NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:temporaryURL.path error:nil];
		unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
		if (size == 0 || size > MDMaximumDownloadBytes) {
			NSString *message = size == 0 ? @"The downloaded file is empty." : @"The file is larger than MusicDrop's 500 MB limit.";
			MDFinishDownload(completion, nil, MDDownloadError(36, message));
			return;
		}

		NSString *suggestedName = response.suggestedFilename.length > 0
			? response.suggestedFilename
			: response.URL.lastPathComponent;
		NSString *destination = MDUniqueDestination(suggestedName, extension);
		NSError *moveError = nil;
		if (![[NSFileManager defaultManager] moveItemAtURL:temporaryURL
											 toURL:[NSURL fileURLWithPath:destination]
											 error:&moveError]) {
			MDFinishDownload(completion, nil, MDDownloadError(37,
				[NSString stringWithFormat:@"Could not save the download: %@", moveError.localizedDescription]));
			return;
		}
		[[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
										 ofItemAtPath:destination
												error:nil];

		MDLog(@"Downloaded direct URL %@ -> %@ (%llu bytes)", url.host, destination.lastPathComponent, size);
		MDFinishDownload(completion, [NSURL fileURLWithPath:destination], nil);
	}];
	[task resume];
}

/// Runs in the helper daemon, which is not sandboxed and can spawn yt-dlp.
+ (void)performYouTubeDownloadTarget:(NSString *)target
							progress:(MDDownloadProgressBlock)progress
						  completion:(MDDownloadCompletionBlock)completion {
	NSError *directoryError = nil;
	if (!MDEnsureDownloadDirectories(&directoryError)) {
		MDFinishDownload(completion, nil, directoryError);
		return;
	}

	MDReportProgress(progress, @"Preparing yt-dlp…");
	NSArray<NSString *> *launcher = MDYouTubeLauncher(progress);
	if (!launcher) {
		MDFinishDownload(completion, nil, MDDownloadError(40,
			@"Could not prepare yt-dlp. Check your connection to GitHub (the log has details), then try again. You can also download into Files elsewhere and use Import Files."));
		return;
	}

	NSString *ffmpeg = MDExecutableAtPaths(@[
		@"/var/jb/usr/bin/ffmpeg",
		@"/var/jb/usr/local/bin/ffmpeg",
		@"/usr/bin/ffmpeg",
		@"/usr/local/bin/ffmpeg",
	]);
	if (!ffmpeg) {
		MDFinishDownload(completion, nil, MDDownloadError(41,
			@"YouTube audio conversion needs FFmpeg. Install a rootless FFmpeg package, then reopen Music."));
		return;
	}

	NSString *format = [MDPreferences downloadFormat];
	if (![@[@"m4a", @"mp3", @"flac"] containsObject:format]) {
		format = @"m4a";
	}
	BOOL embedExtras = [MDPreferences embedArtwork];
	BOOL detailed = [MDPreferences showProgressDetails];

	NSString *outputTemplate = [MDDownloadRoot stringByAppendingPathComponent:@"%(title).100B-%(id)s.%(ext)s"];
	NSMutableArray<NSString *> *arguments = [launcher mutableCopy];
	[arguments addObjectsFromArray:@[
		@"--no-playlist",
		@"--extractor-args", @"youtube:player_client=android",
		@"--max-filesize", @"500M",
		@"--extract-audio",
		@"--audio-format", format,
		@"--audio-quality", @"0",
	]];
	if (embedExtras) {
		[arguments addObjectsFromArray:@[
			@"--embed-metadata",
			@"--embed-thumbnail",
			@"--convert-thumbnails", @"jpg",
		]];
	}
	[arguments addObjectsFromArray:@[
		@"--ffmpeg-location", ffmpeg,
		@"--newline",
	]];
	if (detailed) {
		[arguments addObject:@"--progress"];
	}
	[arguments addObjectsFromArray:@[
		@"--print", @"after_move:MD_FILE:%(filepath)s",
		@"--output", outputTemplate,
		@"--",
		target,
	]];

	NSMutableDictionary<NSString *, NSString *> *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
	environment[@"PATH"] = @"/var/jb/usr/bin:/var/jb/usr/local/bin:/usr/bin:/usr/local/bin:/bin:/var/jb/bin";
	environment[@"HOME"] = @"/var/mobile";
	environment[@"TMPDIR"] = MDDownloadTemporaryRoot;
	environment[@"PYTHONUNBUFFERED"] = @"1";

	char **argv = calloc(arguments.count + 1, sizeof(char *));
	for (NSUInteger index = 0; index < arguments.count; index++) {
		argv[index] = (char *)arguments[index].UTF8String;
	}
	NSArray<NSString *> *environmentKeys = environment.allKeys;
	NSMutableArray<NSString *> *environmentEntries = [NSMutableArray arrayWithCapacity:environmentKeys.count];
	for (NSString *key in environmentKeys) {
		[environmentEntries addObject:[NSString stringWithFormat:@"%@=%@", key, environment[key]]];
	}
	char **envp = calloc(environmentEntries.count + 1, sizeof(char *));
	for (NSUInteger index = 0; index < environmentEntries.count; index++) {
		envp[index] = (char *)environmentEntries[index].UTF8String;
	}

	int outputPipe[2];
	if (pipe(outputPipe) != 0) {
		free(argv);
		free(envp);
		MDFinishDownload(completion, nil, MDDownloadError(42,
			[NSString stringWithFormat:@"Could not create the downloader pipe: %s", strerror(errno)]));
		return;
	}

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
	posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
	posix_spawn_file_actions_addclose(&actions, outputPipe[1]);

	pid_t process = 0;
	int spawnResult = posix_spawn(&process, arguments[0].fileSystemRepresentation, &actions, NULL, argv, envp);
	posix_spawn_file_actions_destroy(&actions);
	free(argv);
	free(envp);
	close(outputPipe[1]);

	if (spawnResult != 0) {
		close(outputPipe[0]);
		MDFinishDownload(completion, nil, MDDownloadError(43,
			[NSString stringWithFormat:@"Could not start yt-dlp: %s. If iOS reports a permission error, download into Files and import it instead.", strerror(spawnResult)]));
		return;
	}

	MDLog(@"Started yt-dlp pid %d for %@", process, target);
	NSMutableString *outputTail = [NSMutableString string];
	__block NSString *downloadedPath = nil;
	FILE *stream = fdopen(outputPipe[0], "r");
	char lineBytes[4096];
	while (stream && fgets(lineBytes, sizeof(lineBytes), stream)) {
		NSString *line = [[NSString alloc] initWithUTF8String:lineBytes];
		if (!line) {
			line = [[NSString alloc] initWithBytes:lineBytes
									 length:strlen(lineBytes)
								   encoding:NSISOLatin1StringEncoding];
		}
		NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (trimmed.length == 0) {
			continue;
		}

		[outputTail appendFormat:@"%@\n", trimmed];
		if (outputTail.length > 8000) {
			[outputTail deleteCharactersInRange:NSMakeRange(0, outputTail.length - 8000)];
		}

		NSRange marker = [trimmed rangeOfString:@"MD_FILE:"];
		if (marker.location != NSNotFound) {
			downloadedPath = [[trimmed substringFromIndex:NSMaxRange(marker)]
				stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			continue;
		}

		if ([trimmed containsString:@"[ExtractAudio]"]) {
			MDReportProgress(progress, @"Converting YouTube audio…");
		} else if ([trimmed containsString:@"[Metadata]"] || [trimmed containsString:@"[EmbedThumbnail]"]) {
			MDReportProgress(progress, @"Embedding track information…");
		} else if ([trimmed containsString:@"[download]"] && [trimmed containsString:@"%"] ) {
			static NSRegularExpression *percentageExpression;
			static dispatch_once_t once;
			dispatch_once(&once, ^{
				percentageExpression = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)%"
																		 options:0
																		   error:nil];
			});
			NSTextCheckingResult *match = [percentageExpression firstMatchInString:trimmed
																 options:0
																   range:NSMakeRange(0, trimmed.length)];
			if (match.numberOfRanges > 1) {
				NSString *percentage = [trimmed substringWithRange:[match rangeAtIndex:1]];
				MDReportProgress(progress, [NSString stringWithFormat:@"Downloading from YouTube… %@%%", percentage]);
			}
		}
	}
	if (stream) {
		fclose(stream);
	} else {
		close(outputPipe[0]);
	}

	int processStatus = 0;
	while (waitpid(process, &processStatus, 0) < 0 && errno == EINTR) {
	}
	BOOL exitedSuccessfully = WIFEXITED(processStatus) && WEXITSTATUS(processStatus) == 0;
	if (!exitedSuccessfully) {
		NSString *detail = MDLastUsefulOutputLine(outputTail);
		NSString *message = detail.length > 0
			? [NSString stringWithFormat:@"YouTube download failed: %@", detail]
			: @"YouTube download failed. Check your connection and update yt-dlp.";
		MDLog(@"yt-dlp failed (status %d): %@", processStatus, outputTail);
		MDFinishDownload(completion, nil, MDDownloadError(44, message));
		return;
	}

	NSString *standardRoot = MDDownloadRoot.stringByStandardizingPath;
	NSString *standardPath = downloadedPath.stringByStandardizingPath;
	if (standardPath.length == 0 ||
		![standardPath hasPrefix:[standardRoot stringByAppendingString:@"/"]]) {
		MDFinishDownload(completion, nil, MDDownloadError(45,
			@"yt-dlp finished but did not report a safe output file."));
		return;
	}

	NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:standardPath error:nil];
	unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
	if (size == 0 || size > MDMaximumDownloadBytes || !MDIsSupportedMediaExtension(standardPath.pathExtension)) {
		MDFinishDownload(completion, nil, MDDownloadError(46,
			@"yt-dlp did not produce a supported audio file within the 500 MB limit."));
		return;
	}
	[[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
									 ofItemAtPath:standardPath
											error:nil];

	MDLog(@"yt-dlp completed %@ (%llu bytes)", standardPath.lastPathComponent, size);
	MDFinishDownload(completion, [NSURL fileURLWithPath:standardPath], nil);
}

@end
