#import "MDHelperClient.h"
#import "MDHelperProtocol.h"

#import <errno.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

static NSError *MDHelperError(NSString *message) {
	return [NSError errorWithDomain:@"com.musiccc.musicdrop.helper"
							   code:1
						   userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL MDWriteAll(int fd, const char *bytes, size_t length) {
	while (length > 0) {
		ssize_t sent = send(fd, bytes, length, 0);
		if (sent < 0) {
			if (errno == EINTR) {
				continue;
			}
			return NO;
		}
		if (sent == 0) {
			return NO;
		}
		bytes += sent;
		length -= (size_t)sent;
	}
	return YES;
}

@interface MDHelperClient ()
+ (nullable NSDictionary *)sendOperation:(NSDictionary *)operation
								progress:(nullable void (^)(NSString *status))progress
								   error:(NSError **)error;
@end

@implementation MDHelperClient

+ (nullable NSDictionary *)runOperation:(NSDictionary *)operation
							   progress:(nullable void (^)(NSString *status))progress
								  error:(NSError **)error {
	// A stale daemon can be killed by iOS when its binary is replaced during an
	// upgrade. Retry once so the just-restarted daemon handles the request.
	for (NSInteger attempt = 0; attempt < 2; attempt++) {
		NSError *attemptError = nil;
		NSDictionary *result = [self sendOperation:operation progress:progress error:&attemptError];
		if (result || !attemptError) {
			return result;
		}
		NSString *message = attemptError.localizedDescription ?: @"";
		BOOL transient = [message containsString:@"closed the connection"] ||
						 [message containsString:@"connection failed"];
		if (!transient || attempt == 1) {
			if (error) {
				*error = attemptError;
			}
			return nil;
		}
		usleep(500000);
	}
	return nil;
}

+ (nullable NSDictionary *)sendOperation:(NSDictionary *)operation
								progress:(nullable void (^)(NSString *status))progress
								   error:(NSError **)error {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		if (error) {
			*error = MDHelperError([NSString stringWithFormat:@"Could not create helper socket: %s", strerror(errno)]);
		}
		return nil;
	}

	struct timeval timeout;
	timeout.tv_sec = 300;
	timeout.tv_usec = 0;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = htons(MDHelperPort);
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
		NSString *detail = [NSString stringWithUTF8String:strerror(errno)] ?: @"unknown error";
		close(fd);
		if (error) {
			*error = MDHelperError([NSString stringWithFormat:
				@"MusicDrop's helper is not running (%@). Reinstall MusicDrop or reopen Music after installing.", detail]);
		}
		return nil;
	}

	NSData *json = [NSJSONSerialization dataWithJSONObject:operation options:0 error:nil];
	if (!json) {
		close(fd);
		if (error) {
			*error = MDHelperError(@"Could not serialize the helper request.");
		}
		return nil;
	}
	NSString *requestLine = [NSString stringWithFormat:@"%@\n", [json base64EncodedStringWithOptions:0]];
	if (!MDWriteAll(fd, requestLine.UTF8String, requestLine.length)) {
		close(fd);
		if (error) {
			*error = MDHelperError(@"Could not send the helper request.");
		}
		return nil;
	}

	NSMutableData *buffer = [NSMutableData data];
	char chunk[4096];
	NSDictionary *result = nil;
	NSString *failure = nil;

	while (!result && !failure) {
		ssize_t received = recv(fd, chunk, sizeof(chunk), 0);
		if (received < 0) {
			if (errno == EINTR) {
				continue;
			}
			failure = [NSString stringWithFormat:@"Helper connection failed: %s", strerror(errno)];
			break;
		}
		if (received == 0) {
			failure = @"Helper closed the connection before finishing.";
			break;
		}
		[buffer appendBytes:chunk length:(NSUInteger)received];

		while (!result && !failure) {
			NSRange newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
										options:0
										  range:NSMakeRange(0, buffer.length)];
			if (newline.location == NSNotFound) {
				break;
			}
			NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
			[buffer replaceBytesInRange:NSMakeRange(0, NSMaxRange(newline)) withBytes:NULL length:0];
			NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
			NSRange space = [line rangeOfString:@" "];
			if (line.length == 0 || space.location == NSNotFound) {
				continue;
			}
			NSString *prefix = [line substringToIndex:space.location];
			NSString *encoded = [line substringFromIndex:NSMaxRange(space)];
			NSData *decoded = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
			NSString *value = decoded ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
			if (!value) {
				continue;
			}

			if ([prefix isEqualToString:@"P"]) {
				if (progress) {
					progress(value);
				}
			} else if ([prefix isEqualToString:@"OK"]) {
				NSData *jsonData = [value dataUsingEncoding:NSUTF8StringEncoding];
				id object = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
				result = [object isKindOfClass:[NSDictionary class]] ? object : @{};
			} else if ([prefix isEqualToString:@"ER"]) {
				failure = value;
			}
		}
	}
	close(fd);

	if (failure) {
		if (error) {
			*error = MDHelperError(failure);
		}
		return nil;
	}
	return result;
}

+ (void)runOperation:(NSDictionary *)operation
			progress:(nullable void (^)(NSString *status))progress
		  completion:(void (^)(NSDictionary * _Nullable response, NSError * _Nullable error))completion {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSError *error = nil;
		NSDictionary *response = [self runOperation:operation progress:progress error:&error];
		if (completion) {
			dispatch_async(dispatch_get_main_queue(), ^{
				completion(response, error);
			});
		}
	});
}

+ (void)embedLyricsForFiles:(NSArray<NSDictionary *> *)files
				   progress:(nullable void (^)(NSString *status))progress
				 completion:(void (^)(NSUInteger embedded, NSUInteger skipped))completion {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		__block NSUInteger embedded = 0;
		__block NSUInteger skipped = 0;
		NSUInteger total = files.count;

		for (NSUInteger index = 0; index < total; index++) {
			NSDictionary *file = files[index];
			NSString *path = file[@"path"];
			if (progress) {
				progress([NSString stringWithFormat:@"Adding lyrics %lu of %lu…",
						  (unsigned long)(index + 1), (unsigned long)total]);
			}
			NSError *error = nil;
			NSDictionary *response = [self runOperation:@{
				MDHelperOperationKey: MDHelperOperationLyrics,
				MDHelperPathKey: path ?: @"",
				MDHelperTitleKey: file[@"title"] ?: @"",
				MDHelperArtistKey: file[@"artist"] ?: @"",
				MDHelperAlbumKey: file[@"album"] ?: @"",
				MDHelperDurationKey: file[@"duration"] ?: @0,
			} progress:nil error:&error];
			NSString *resultPath = response[MDHelperResultPathKey];
			if (!error && resultPath.length > 0) {
				embedded++;
			} else {
				skipped++;
			}
		}

		if (completion) {
			dispatch_async(dispatch_get_main_queue(), ^{
				completion(embedded, skipped);
			});
		}
	});
}

@end
