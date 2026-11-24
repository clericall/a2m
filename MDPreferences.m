#import "MDPreferences.h"

static NSString *const MDEmbedLyricsKey = @"MusicDropEmbedLyrics";
static NSString *const MDEmbedArtworkKey = @"MusicDropEmbedArtwork";
static NSString *const MDDownloadFormatKey = @"MusicDropDownloadFormat";
static NSString *const MDShowProgressKey = @"MusicDropShowProgress";

static BOOL MDBool(id value, BOOL fallback) {
	return value ? [value boolValue] : fallback;
}

@implementation MDPreferences

+ (BOOL)embedLyrics {
	return MDBool([[NSUserDefaults standardUserDefaults] objectForKey:MDEmbedLyricsKey], YES);
}

+ (void)setEmbedLyrics:(BOOL)enabled {
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:MDEmbedLyricsKey];
}

+ (BOOL)embedArtwork {
	return MDBool([[NSUserDefaults standardUserDefaults] objectForKey:MDEmbedArtworkKey], YES);
}

+ (void)setEmbedArtwork:(BOOL)enabled {
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:MDEmbedArtworkKey];
}

+ (NSString *)downloadFormat {
	id value = [[NSUserDefaults standardUserDefaults] objectForKey:MDDownloadFormatKey];
	return [value isKindOfClass:[NSString class]] ? value : @"m4a";
}

+ (void)setDownloadFormat:(NSString *)format {
	[[NSUserDefaults standardUserDefaults] setObject:format forKey:MDDownloadFormatKey];
}

+ (BOOL)showProgressDetails {
	return MDBool([[NSUserDefaults standardUserDefaults] objectForKey:MDShowProgressKey], YES);
}

+ (void)setShowProgressDetails:(BOOL)enabled {
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:MDShowProgressKey];
}

@end
