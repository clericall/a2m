#import <Foundation/Foundation.h>

/// Loopback port used by the Music app to reach the unsandboxed helper daemon.
#define MDHelperPort 45454

#define MDHelperOperationKey @"op"
#define MDHelperOperationYouTube @"youtube"
#define MDHelperOperationLyrics @"lyrics"
#define MDHelperURLKey @"url"
#define MDHelperQueryKey @"query"
#define MDHelperPathKey @"path"
#define MDHelperTitleKey @"title"
#define MDHelperArtistKey @"artist"
#define MDHelperAlbumKey @"album"
#define MDHelperDurationKey @"duration"
#define MDHelperResultPathKey @"resultPath"
