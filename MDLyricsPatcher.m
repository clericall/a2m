#import "MDLyrics.h"
#import "MDLog.h"

#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <substrate.h>

static id (*MDLyricsOriginal)(id, SEL) = NULL;
static BOOL (*MDHasLyricsOriginal)(id, SEL) = NULL;

// Emergency kill switch: if this file exists, the patch does nothing.
static NSString *const MDLyricsPatchDisablePath = @"/var/mobile/Media/MusicDrop/disable_lyrics_patch";

static BOOL MDPatchEnabled(void) {
	return ![[NSFileManager defaultManager] fileExistsAtPath:MDLyricsPatchDisablePath];
}

static NSString *MDStringFromItem(id item, NSArray<NSString *> *selectors) {
	for (NSString *name in selectors) {
		SEL selector = NSSelectorFromString(name);
		if (![item respondsToSelector:selector]) {
			continue;
		}
		id (*call)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
		id value = call(item, selector);
		if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
			return (NSString *)value;
		}
	}
	return nil;
}

static id MDPatchedLyricsItem(id item) {
	if (!MDPatchEnabled()) {
		return nil;
	}

	NSDictionary *nowPlayingInfo = [[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo];
	NSString *title = nowPlayingInfo[MPMediaItemPropertyTitle];
	NSString *artist = nowPlayingInfo[MPMediaItemPropertyArtist];
	if (![title isKindOfClass:[NSString class]] || title.length == 0) {
		title = MDStringFromItem(item, @[@"title", @"trackName", @"name"]);
	}
	if (![artist isKindOfClass:[NSString class]] || artist.length == 0) {
		artist = MDStringFromItem(item, @[@"trackArtistName", @"artistName", @"artist"]);
	}
	if (title.length == 0) {
		return nil;
	}
	if (artist.length == 0) {
		artist = @"";
	}

	// Prefer plain lyrics. Raw LRC markup can break Music's renderer.
	NSString *text = [MDLyrics plainLyricsForTitle:title artist:artist];
	if (text.length == 0) {
		return nil;
	}

	static NSMutableDictionary<NSString *, id> *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = [NSMutableDictionary dictionary];
	});

	NSString *key = [NSString stringWithFormat:@"%@|%@", title, artist];
	@synchronized (cache) {
		id cached = cache[key];
		if (cached) {
			return cached;
		}

		Class lyricsClass = NSClassFromString(@"MPNowPlayingInfoLyricsItem");
		if (!lyricsClass) {
			MDLog(@"LyricsPatch: MPNowPlayingInfoLyricsItem missing");
			return nil;
		}

		id result = nil;
		@try {
			// Confirmed signature: @28@0:8@16B24 -> (id, SEL, id, BOOL)
			id (*call)(id, SEL, id, BOOL) = (id (*)(id, SEL, id, BOOL))objc_msgSend;
			result = call([lyricsClass alloc],
						  NSSelectorFromString(@"initWithLyrics:userProvided:"),
						  text, YES);
		} @catch (NSException *exception) {
			MDLog(@"LyricsPatch: init exception: %@", exception.reason);
			return nil;
		}
		if (!result) {
			MDLog(@"LyricsPatch: init returned nil for '%@'", title);
			return nil;
		}
		cache[key] = result;
		MDLog(@"LyricsPatch: created lyrics item for '%@' by '%@' (%lu chars)",
			  title, artist, (unsigned long)text.length);
		return result;
	}
}

static id MDHookedLyrics(id self, SEL selector) {
	id patched = MDPatchedLyricsItem(self);
	if (patched) {
		return patched;
	}
	return MDLyricsOriginal ? MDLyricsOriginal(self, selector) : nil;
}

static BOOL MDHookedHasLyrics(id self, SEL selector) {
	if (MDPatchedLyricsItem(self)) {
		return YES;
	}
	return MDHasLyricsOriginal ? MDHasLyricsOriginal(self, selector) : NO;
}

static void MDInstallLyricsPatch(void) {
	Class itemClass = NSClassFromString(@"MPNowPlayingContentItem");
	if (!itemClass) {
		return;
	}
	if (MDLyricsOriginal) {
		return;
	}
	MSHookMessageEx(itemClass, @selector(lyrics),
					(IMP)MDHookedLyrics, (IMP *)&MDLyricsOriginal);
	MSHookMessageEx(itemClass, @selector(hasLyrics),
					(IMP)MDHookedHasLyrics, (IMP *)&MDHasLyricsOriginal);
	MDLog(@"LyricsPatch: hooked MPNowPlayingContentItem (enabled=%d)", MDPatchEnabled());
}

__attribute__((constructor)) static void MDLyricsPatchConstructor(void) {
	@autoreleasepool {
		MDInstallLyricsPatch();
		if (!MDLyricsOriginal) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				MDInstallLyricsPatch();
			});
		}
	}
}
