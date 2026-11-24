#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MDDownloadProgressBlock)(NSString *status);
typedef void (^MDDownloadCompletionBlock)(NSURL * _Nullable localFileURL,
											 NSError * _Nullable error);

@interface MDDownloadManager : NSObject

+ (instancetype)sharedManager;

/// Downloads one direct HTTPS media URL or one YouTube item. Completion is
/// delivered on the main queue with a local file URL ready for MDImporter.
- (void)downloadURL:(NSURL *)url
		   progress:(nullable MDDownloadProgressBlock)progress
		 completion:(MDDownloadCompletionBlock)completion;

/// Downloads one YouTube URL or a `ytsearch1:` query. Called only by the
/// unsandboxed MusicDrop helper daemon.
+ (void)performYouTubeDownloadTarget:(NSString *)target
							progress:(nullable MDDownloadProgressBlock)progress
						  completion:(MDDownloadCompletionBlock)completion;

/// Downloads the first YouTube result for a search query.
- (void)searchYouTube:(NSString *)query
			 progress:(nullable MDDownloadProgressBlock)progress
		   completion:(MDDownloadCompletionBlock)completion;

@end

NS_ASSUME_NONNULL_END
