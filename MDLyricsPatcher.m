#import "MDLyrics.h"
#import "MDLog.h"
#import "MDPreferences.h"

#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <substrate.h>

static id (*MDLyricsOriginal)(id, SEL) = NULL;
static BOOL (*MDHasLyricsOriginal)(id, SEL) = NULL;
static BOOL (*MDShouldDisplayOriginal)(id, SEL, id, id, id, id, BOOL) = NULL;
static BOOL (*MDButtonActiveOriginal)(id, SEL, id, id) = NULL;

static NSString *const MDLyricsPatchDisablePath = @"/var/mobile/Media/MusicDrop/disable_lyrics_patch";
static NSString *const MDLyricsPatchCrashPath = @"/var/mobile/Media/MusicDrop/lyrics_patch_crashed";

static BOOL MDPatchEnabled(void) {
	NSFileManager *manager = [NSFileManager defaultManager];
	if ([manager fileExistsAtPath:MDLyricsPatchDisablePath]) {
		return NO;
	}
	// Auto-disable after a crash so Music stays usable.
	if ([manager fileExistsAtPath:MDLyricsPatchCrashPath]) {
		return NO;
	}
	return [MDPreferences nativeLyricsPatch];
}

static void MDHandleException(NSException *exception) {
	MDLog(@"LyricsPatch: EXCEPTION %@ reason=%@ callStack=%@",
		  exception.name, exception.reason,
		  [[exception callStackSymbols] subarrayWithRange:
		   NSMakeRange(0, MIN((NSUInteger)8, [exception callStackSymbols].count))]);
	[@"crashed" writeToFile:MDLyricsPatchCrashPath atomically:YES
				encoding:NSUTF8StringEncoding error:nil];
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
	@try {
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
				MDLog(@"LyricsPatch: MPNowPlayingInfoLyricsItem class missing");
				return nil;
			}
			id result = nil;
			@try {
				// Verified on device: @28@0:8@16B24 -> (id, SEL, id object, BOOL)
				id (*call)(id, SEL, id, BOOL) = (id (*)(id, SEL, id, BOOL))objc_msgSend;
				result = call([lyricsClass alloc],
							  NSSelectorFromString(@"initWithLyrics:userProvided:"),
							  text, YES);
			} @catch (NSException *exception) {
				MDHandleException(exception);
				return nil;
			}
			if (!result) {
				MDLog(@"LyricsPatch: created item was nil for '%@'", title);
				return nil;
			}
			cache[key] = result;
			MDLog(@"LyricsPatch: built lyrics item for '%@' by '%@' (%lu chars)",
				  title, artist, (unsigned long)text.length);
			return result;
		}
	} @catch (NSException *exception) {
		MDHandleException(exception);
		return nil;
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

static BOOL MDIdentifierIsLyrics(id identifier) {
	NSString *text = [identifier isKindOfClass:[NSString class]]
		? (NSString *)identifier : [identifier description];
	return [text.lowercaseString containsString:@"lyric"];
}

// Forces Music's Now Playing lyrics button to be displayed when we have lyrics.
static BOOL MDHookedShouldDisplay(id self, SEL selector, id controller,
								  id button, id image, id identifier, BOOL tinted) {
	if (MDPatchEnabled() && MDIdentifierIsLyrics(identifier)) {
		if (MDPatchedLyricsItem(nil)) {
			MDLog(@"LyricsPatch: forcing lyrics button visible");
			return YES;
		}
	}
	return MDShouldDisplayOriginal
		? MDShouldDisplayOriginal(self, selector, controller, button, image, identifier, tinted)
		: YES;
}

static BOOL MDHookedButtonActive(id self, SEL selector, id controller, id button) {
	if (MDPatchEnabled() && MDIdentifierIsLyrics(button)) {
		if (MDPatchedLyricsItem(nil)) {
			return YES;
		}
	}
	return MDButtonActiveOriginal
		? MDButtonActiveOriginal(self, selector, controller, button)
		: YES;
}

static void MDHookMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
	if (!cls || !selector || !class_getInstanceMethod(cls, selector)) {
		return;
	}
	if (*original) {
		return;
	}
	MSHookMessageEx(cls, selector, replacement, original);
}

static void MDInstallLyricsPatch(void) {
	if (!MDPatchEnabled()) {
		MDLog(@"LyricsPatch: disabled (toggle off, kill switch, or prior crash)");
		return;
	}

	Class contentItem = NSClassFromString(@"MPNowPlayingContentItem");
	MDHookMethod(contentItem, @selector(lyrics),
				 (IMP)MDHookedLyrics, (IMP *)&MDLyricsOriginal);
	MDHookMethod(contentItem, @selector(hasLyrics),
				 (IMP)MDHookedHasLyrics, (IMP *)&MDHasLyricsOriginal);

	Class manager = NSClassFromString(@"MCDNowPlayingContentManager");
	MDHookMethod(manager, NSSelectorFromString(@"nowPlayingViewController:shouldDisplayButton:withImage:existingIdentifier:tinted:"),
				 (IMP)MDHookedShouldDisplay, (IMP *)&MDShouldDisplayOriginal);
	MDHookMethod(manager, NSSelectorFromString(@"nowPlayingViewController:buttonShouldBeActive:"),
				 (IMP)MDHookedButtonActive, (IMP *)&MDButtonActiveOriginal);

	MDLog(@"LyricsPatch: installed (content=%d manager=%d)",
		  MDLyricsOriginal != NULL, MDShouldDisplayOriginal != NULL);
}

__attribute__((constructor)) static void MDLyricsPatchConstructor(void) {
	@autoreleasepool {
		NSSetUncaughtExceptionHandler(&MDHandleException);
		MDInstallLyricsPatch();
		if (!MDLyricsOriginal && MDPatchEnabled()) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				MDInstallLyricsPatch();
			});
		}
	}
}
