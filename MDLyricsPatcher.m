#import "MDLyrics.h"
#import "MDLog.h"

#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <substrate.h>

static id (*MDLyricsOriginal)(id, SEL) = NULL;
static BOOL (*MDHasLyricsOriginal)(id, SEL) = NULL;

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

// Disabled until the exact initWithLyrics:userProvided: signature is
// confirmed from the device dump. Keeping it off stops the crash; the
// original implementation handles the button state.
static BOOL MDDeepPatchEnabled = NO;

static id MDPatchedLyricsItem(id item) {
	if (!MDDeepPatchEnabled) {
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

	NSString *synced = [MDLyrics syncedLyricsForTitle:title artist:artist];
	NSString *plain = [MDLyrics plainLyricsForTitle:title artist:artist];
	NSString *text = synced.length > 0 ? synced : plain;
	if (text.length == 0) {
		static NSString *lastMissingKey = nil;
		NSString *key = [NSString stringWithFormat:@"%@|%@", title, artist];
		if (![key isEqualToString:lastMissingKey]) {
			lastMissingKey = key;
			MDLog(@"LyricsPatch: no saved lyrics for '%@' by '%@'", title, artist);
		}
		return nil;
	}

	static NSMutableDictionary<NSString *, id> *cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = [NSMutableDictionary dictionary];
	});
	NSString *key = [NSString stringWithFormat:@"%@|%@", title, artist];
	id cached = cache[key];
	if (cached) {
		return cached;
	}

	Class lyricsClass = NSClassFromString(@"MPNowPlayingInfoLyricsItem");
	if (!lyricsClass) {
		return nil;
	}

	id result = nil;
	@try {
		id (*call)(id, SEL, id, BOOL) = (id (*)(id, SEL, id, BOOL))objc_msgSend;
		result = call([lyricsClass alloc],
					  NSSelectorFromString(@"initWithLyrics:userProvided:"),
					  text, YES);
	} @catch (NSException *exception) {
		MDLog(@"LyricsPatch: could not build lyrics item: %@", exception.reason);
		return nil;
	}
	if (result) {
		cache[key] = result;
		MDLog(@"LyricsPatch: provided lyrics for '%@' by '%@' (%lu chars)",
			  title, artist, (unsigned long)text.length);
	}
	return result;
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
		MDLog(@"LyricsPatch: MPNowPlayingContentItem not loaded; will retry");
		return;
	}
	if (MDLyricsOriginal) {
		return;
	}
	MSHookMessageEx(itemClass, @selector(lyrics),
					(IMP)MDHookedLyrics, (IMP *)&MDLyricsOriginal);
	MSHookMessageEx(itemClass, @selector(hasLyrics),
					(IMP)MDHookedHasLyrics, (IMP *)&MDHasLyricsOriginal);
	MDLog(@"LyricsPatch: hooked MPNowPlayingContentItem lyrics/hasLyrics");
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
