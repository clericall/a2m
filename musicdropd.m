#import "MDHelperProtocol.h"
#import "MDDownloadManager.h"
#import "MDLyrics.h"
#import "MDLog.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

static const char *MDHelperSocketRoot = "/var/mobile/Media/MusicDrop";

static void MDHelperWriteLine(int fd, NSString *line) {
	const char *bytes = line.UTF8String;
	size_t length = strlen(bytes);
	while (length > 0) {
		ssize_t sent = send(fd, bytes, length, 0);
		if (sent < 0) {
			if (errno == EINTR) {
				continue;
			}
			return;
		}
		if (sent == 0) {
			return;
		}
		bytes += sent;
		length -= (size_t)sent;
	}
}

static NSString *MDHelperEncode(NSString *prefix, NSString *value) {
	NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
	return [NSString stringWithFormat:@"%@ %@\n", prefix, [data base64EncodedStringWithOptions:0]];
}

static void MDHelperSendOK(int fd, NSString *path) {
	NSDictionary *response = @{MDHelperResultPathKey: path ?: @""};
	NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
	NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"{}";
	MDHelperWriteLine(fd, MDHelperEncode(@"OK", text));
}

static void MDHelperSendError(int fd, NSString *message) {
	MDHelperWriteLine(fd, MDHelperEncode(@"ER", message ?: @"Unknown helper error"));
}

static BOOL MDHelperPathIsSafe(NSString *path) {
	NSString *standard = path.stringByStandardizingPath;
	NSString *root = [NSString stringWithUTF8String:MDHelperSocketRoot].stringByStandardizingPath;
	return standard.length > 0 && [standard hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSDictionary *MDHelperReadRequest(int fd) {
	NSMutableData *buffer = [NSMutableData data];
	char chunk[4096];
	while (buffer.length < 1024 * 1024) {
		ssize_t received = recv(fd, chunk, sizeof(chunk), 0);
		if (received < 0) {
			if (errno == EINTR) {
				continue;
			}
			return nil;
		}
		if (received == 0) {
			break;
		}
		[buffer appendBytes:chunk length:(NSUInteger)received];
		NSRange newline = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
								options:0
								  range:NSMakeRange(0, buffer.length)];
		if (newline.location != NSNotFound) {
			NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
			NSString *encoded = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
			NSData *decoded = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
			if (!decoded) {
				return nil;
			}
			id object = [NSJSONSerialization JSONObjectWithData:decoded options:0 error:nil];
			return [object isKindOfClass:[NSDictionary class]] ? object : nil;
		}
	}
	return nil;
}

static void MDHelperHandleClient(int fd) {
	@autoreleasepool {
		NSDictionary *request = MDHelperReadRequest(fd);
		if (!request) {
			MDHelperSendError(fd, @"Could not read helper request.");
			close(fd);
			return;
		}

		NSString *operation = request[MDHelperOperationKey];
		if ([operation isEqualToString:MDHelperOperationYouTube]) {
			NSString *urlString = request[MDHelperURLKey];
			NSString *query = request[MDHelperQueryKey];
			NSString *target = nil;
			NSString *display = nil;
			if (query.length > 0) {
				target = [NSString stringWithFormat:@"ytsearch1:%@", query];
				display = query;
			} else if (urlString.length > 0) {
				target = urlString;
				display = [NSURL URLWithString:urlString].host ?: urlString;
			}
			if (target.length == 0) {
				MDHelperSendError(fd, @"The helper received an invalid request.");
				close(fd);
				return;
			}
			MDLog(@"Helper: YouTube request for %@", display);
			[MDDownloadManager performYouTubeDownloadTarget:target
				progress:^(NSString *status) {
					MDHelperWriteLine(fd, MDHelperEncode(@"P", status));
				}
				completion:^(NSURL *fileURL, NSError *error) {
					if (error || !fileURL) {
						MDHelperSendError(fd, error.localizedDescription ?: @"Download failed.");
					} else {
						MDHelperSendOK(fd, fileURL.path);
					}
					close(fd);
				}];
			return;
		}

		if ([operation isEqualToString:MDHelperOperationLyrics]) {
			NSString *path = request[MDHelperPathKey];
			if (!MDHelperPathIsSafe(path)) {
				MDHelperSendError(fd, @"Refusing to touch a file outside MusicDrop.");
				close(fd);
				return;
			}
			BOOL embedded = [[MDLyrics sharedLyrics] embedLyricsForTitle:request[MDHelperTitleKey] ?: @""
				artist:request[MDHelperArtistKey] ?: @""
				album:request[MDHelperAlbumKey]
				duration:[request[MDHelperDurationKey] doubleValue]
				intoFileAtPath:path
				extension:path.pathExtension];
			MDHelperSendOK(fd, embedded ? path : @"");
			close(fd);
			return;
		}

		MDHelperSendError(fd, @"Unknown helper operation.");
		close(fd);
	}
}

int main(int argc, char *argv[]) {
	@autoreleasepool {
		(void)argc;
		(void)argv;

		int listener = socket(AF_INET, SOCK_STREAM, 0);
		if (listener < 0) {
			MDLog(@"Helper: socket failed: %s", strerror(errno));
			return 1;
		}

		int yes = 1;
		setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
		setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif

		struct sockaddr_in address;
		memset(&address, 0, sizeof(address));
		address.sin_family = AF_INET;
		address.sin_port = htons(MDHelperPort);
		address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

		if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0) {
			MDLog(@"Helper: bind failed: %s", strerror(errno));
			close(listener);
			return 1;
		}
		if (listen(listener, 8) != 0) {
			MDLog(@"Helper: listen failed: %s", strerror(errno));
			close(listener);
			return 1;
		}

		MDLog(@"Helper: listening on 127.0.0.1:%u", (unsigned)MDHelperPort);

		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			while (listener >= 0) {
				int client = accept(listener, NULL, NULL);
				if (client < 0) {
					if (errno == EINTR) {
						continue;
					}
					break;
				}
#ifdef SO_NOSIGPIPE
				setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
				struct timeval timeout;
				timeout.tv_sec = 30;
				timeout.tv_usec = 0;
				setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
				setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
				MDHelperHandleClient(client);
			}
		});

		// Progress and completion blocks are dispatched to the main queue.
		dispatch_main();
	}
	return 0;
}
