#import "MDImportButton.h"
#import "MDDownloadManager.h"
#import "MDHelperClient.h"
#import "MDImporter.h"
#import "MDLibraryScanner.h"
#import "MDLog.h"
#import "MDRuntimeDump.h"
#import "MDUI.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>

static MDImportButton *sharedButton;

static UIWindow *MDKeyWindow(void) {
	UIApplication *application = [UIApplication sharedApplication];

	if (@available(iOS 13.0, *)) {
		UIWindow *fallback = nil;
		for (UIScene *scene in application.connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) {
				continue;
			}
			UIWindowScene *windowScene = (UIWindowScene *)scene;
			for (UIWindow *window in windowScene.windows) {
				if (window.isKeyWindow) {
					if (window.windowLevel == UIWindowLevelNormal) {
						return window;
					}
					if (!fallback) {
						fallback = window;
					}
				}
			}
		}
		if (fallback) {
			return fallback;
		}
		for (UIScene *scene in application.connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) {
				continue;
			}
			UIWindowScene *windowScene = (UIWindowScene *)scene;
			if (windowScene.activationState == UISceneActivationStateForegroundActive &&
				windowScene.windows.count > 0) {
				for (UIWindow *window in windowScene.windows) {
					if (window.windowLevel == UIWindowLevelNormal) {
						return window;
					}
				}
				return windowScene.windows.firstObject;
			}
		}
	}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	return application.keyWindow;
#pragma clang diagnostic pop
}

static UIViewController *MDTopViewController(void) {
	UIWindow *window = MDKeyWindow();
	UIViewController *controller = window.rootViewController;
	if (!controller) {
		return nil;
	}

	for (NSInteger depth = 0; depth < 8; depth++) {
		UIViewController *next = controller.presentedViewController;
		if (next) {
			controller = next;
			continue;
		}
		if ([controller isKindOfClass:[UINavigationController class]]) {
			UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
			if (visible && visible != controller) {
				controller = visible;
				continue;
			}
		}
		if ([controller isKindOfClass:[UITabBarController class]]) {
			UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
			if (selected && selected != controller) {
				controller = selected;
				continue;
			}
		}
		break;
	}
	return controller;
}

@interface MDImportButton () <UIDocumentPickerDelegate>
@property (nonatomic, strong, nullable) UIDocumentPickerViewController *picker;
@property (nonatomic, strong, nullable) UIView *progressView;
@property (nonatomic, strong) NSString *progressTitle;
@property (nonatomic, strong, nullable) NSArray<NSString *> *pendingErrors;
@property (nonatomic, assign) NSInteger pickerMode; // 0 = import, 1 = fix lyrics
@property (nonatomic, assign) BOOL importing;
@property (nonatomic, assign) BOOL downloading;
@property (nonatomic, assign) BOOL positionRestored;
- (void)layoutInWindow;
- (void)savePosition;
- (void)downloadEntries:(NSArray<NSString *> *)entries
				  index:(NSUInteger)index
				   files:(NSMutableArray<NSURL *> *)files
				  errors:(NSMutableArray<NSString *> *)errors;
- (void)beginFixLyricsWithFiles:(NSArray<NSDictionary *> *)files;
@end

@implementation MDImportButton

+ (void)installIfNeeded {
	if (![NSThread isMainThread]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self installIfNeeded];
		});
		return;
	}

	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

		[center addObserverForName:UIApplicationDidBecomeActiveNotification
							object:nil
							 queue:[NSOperationQueue mainQueue]
						usingBlock:^(__unused NSNotification *note) {
			[MDImportButton installIfNeeded];
		}];

		[center addObserverForName:UIWindowDidBecomeKeyNotification
							object:nil
							 queue:[NSOperationQueue mainQueue]
						usingBlock:^(__unused NSNotification *note) {
			[MDImportButton installIfNeeded];
		}];

		[center addObserverForName:UIDeviceOrientationDidChangeNotification
							object:nil
							 queue:[NSOperationQueue mainQueue]
						usingBlock:^(__unused NSNotification *note) {
			[sharedButton layoutInWindow];
		}];
	});

	UIWindow *window = MDKeyWindow();
	if (!window) {
		static BOOL retryPending = NO;
		if (!retryPending) {
			retryPending = YES;
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				retryPending = NO;
				[MDImportButton installIfNeeded];
			});
		}
		return;
	}

	if (!sharedButton) {
		sharedButton = [[MDImportButton alloc] initWithFrame:CGRectZero];
	}
	if (sharedButton.superview != window) {
		[sharedButton removeFromSuperview];
		[window addSubview:sharedButton];
	}
	[sharedButton layoutInWindow];
	[window bringSubviewToFront:sharedButton];
}

- (instancetype)initWithFrame:(CGRect)frame {
	frame.size = CGSizeMake(56, 56);
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = [UIColor colorWithRed:0.98 green:0.20 blue:0.35 alpha:1.0];
		self.tintColor = [UIColor whiteColor];
		self.layer.cornerRadius = 28;
		self.layer.cornerCurve = kCACornerCurveContinuous;
		self.layer.borderWidth = 0.5;
		self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.25] CGColor];
		self.layer.shadowColor = [[UIColor blackColor] CGColor];
		self.layer.shadowOpacity = 0.30f;
		self.layer.shadowRadius = 12.0f;
		self.layer.shadowOffset = CGSizeMake(0, 6);

		UIImageSymbolConfiguration *configuration =
			[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightSemibold];
		UIImage *icon = [UIImage systemImageNamed:@"music.note" withConfiguration:configuration];
		if (!icon) {
			icon = [UIImage systemImageNamed:@"plus" withConfiguration:configuration];
		}
		[self setImage:icon forState:UIControlStateNormal];
		self.imageView.contentMode = UIViewContentModeScaleAspectFit;

		self.accessibilityLabel = @"Add music";
		self.accessibilityHint = @"Import audio files or download from a URL";
		[self addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];

		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(buttonPanned:)];
		[self addGestureRecognizer:pan];
	}
	return self;
}

- (CGPoint)clampedCenter:(CGPoint)center {
	UIWindow *window = self.window;
	if (!window) {
		return center;
	}
	CGRect bounds = window.bounds;
	UIEdgeInsets safe = window.safeAreaInsets;
	CGFloat radius = CGRectGetWidth(self.bounds) / 2.0;

	CGFloat minX = safe.left + radius + 8.0;
	CGFloat maxX = CGRectGetWidth(bounds) - safe.right - radius - 8.0;
	CGFloat minY = safe.top + radius + 8.0;
	CGFloat maxY = CGRectGetHeight(bounds) - safe.bottom - radius - 8.0;

	center.x = MIN(MAX(center.x, minX), MAX(minX, maxX));
	center.y = MIN(MAX(center.y, minY), MAX(minY, maxY));
	return center;
}

- (void)layoutInWindow {
	UIWindow *window = self.window ?: MDKeyWindow();
	if (!window) {
		return;
	}

	if (!self.positionRestored) {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		double savedX = [defaults doubleForKey:@"MusicDropButtonX"];
		double savedY = [defaults doubleForKey:@"MusicDropButtonY"];
		CGFloat width = CGRectGetWidth(window.bounds);
		CGFloat height = CGRectGetHeight(window.bounds);

		if (savedX > 0.0 && savedY > 0.0 && savedX <= 1.0 && savedY <= 1.0 && width > 0 && height > 0) {
			self.center = CGPointMake(savedX * width, savedY * height);
		} else {
			UIEdgeInsets safe = window.safeAreaInsets;
			CGFloat radius = CGRectGetWidth(self.bounds) / 2.0;
			self.center = CGPointMake(width - safe.right - radius - 16.0,
									  height - safe.bottom - 49.0 - radius - 18.0);
		}
		self.positionRestored = YES;
	}

	self.center = [self clampedCenter:self.center];
}

- (void)savePosition {
	UIWindow *window = self.window;
	if (!window || CGRectGetWidth(window.bounds) <= 0 || CGRectGetHeight(window.bounds) <= 0) {
		return;
	}
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setDouble:self.center.x / CGRectGetWidth(window.bounds) forKey:@"MusicDropButtonX"];
	[defaults setDouble:self.center.y / CGRectGetHeight(window.bounds) forKey:@"MusicDropButtonY"];
}

- (void)buttonPanned:(UIPanGestureRecognizer *)gesture {
	if (!self.superview) {
		return;
	}

	if (gesture.state == UIGestureRecognizerStateChanged ||
		gesture.state == UIGestureRecognizerStateEnded) {
		CGPoint translation = [gesture translationInView:self.superview];
		CGPoint center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
		self.center = [self clampedCenter:center];
		[gesture setTranslation:CGPointZero inView:self.superview];

		if (gesture.state == UIGestureRecognizerStateEnded) {
			[self savePosition];
		}
	}
}

- (void)buttonTapped {
	if (self.importing || self.downloading) {
		return;
	}

	UIWindow *window = MDKeyWindow();
	if (!window) {
		MDLog(@"No window available to show the menu.");
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[MDUI showMenuInWindow:window selection:^(MDMenuAction action) {
		MDImportButton *strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}
		switch (action) {
			case MDMenuActionImportFiles:
				[strongSelf showDocumentPicker];
				break;
			case MDMenuActionDownloadURL:
				[strongSelf showDownloadPrompt];
				break;
			case MDMenuActionSearch:
				[strongSelf showSearchPrompt];
				break;
			case MDMenuActionBatchDownload:
				[strongSelf showBatchPrompt];
				break;
			case MDMenuActionFixLyrics:
				[strongSelf showFixLyricsPrompt];
				break;
			case MDMenuActionSettings:
				[MDUI showSettingsInWindow:MDKeyWindow()];
				break;
			case MDMenuActionHelp:
				[MDUI showHelpInWindow:MDKeyWindow()];
				break;
			case MDMenuActionLyricsDebug:
				[MDRuntimeDump logLyricsRuntimeInfo];
				[strongSelf showResultWithTitle:@"Dump Written"
					message:[NSString stringWithFormat:@"Music's lyrics classes and views were written to %@", MDLogPath]
					success:YES];
				break;
		}
	}];
}

- (void)showDocumentPicker {
	if (self.importing || self.downloading) {
		return;
	}

	NSMutableOrderedSet<UTType *> *types = [NSMutableOrderedSet orderedSet];
	if (UTTypeAudio) {
		[types addObject:UTTypeAudio];
	}
	if (UTTypeMovie) {
		[types addObject:UTTypeMovie];
	}
	NSArray<NSString *> *extensions = @[
		@"mp3", @"m4a", @"m4r", @"m4b", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac",
		@"mp4", @"m4v", @"mov",
	];
	for (NSString *extension in extensions) {
		UTType *type = [UTType typeWithFilenameExtension:extension];
		if (type) {
			[types addObject:type];
		}
	}

	if (types.count == 0) {
		[self showResultWithTitle:@"Unsupported" message:@"This iOS version did not report any audio file types." success:NO];
		return;
	}

	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types.array
																  asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	self.picker = picker;
	self.pickerMode = 0;

	UIViewController *presenter = MDTopViewController();
	if (!presenter) {
		MDLog(@"No view controller available to present the document picker.");
		return;
	}
	self.hidden = YES;
	[presenter presentViewController:picker animated:YES completion:nil];
}

- (void)showDownloadPrompt {
	if (self.importing || self.downloading) {
		return;
	}
	UIWindow *window = MDKeyWindow();
	if (!window) {
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[MDUI showInputInWindow:window
		title:@"Download Music"
		subtitle:@"Paste a direct audio or YouTube HTTPS URL. Only save media you have the right to download."
		placeholder:@"https://…"
		submit:@"Download"
		initial:[UIPasteboard generalPasteboard].string ?: @""
		completion:^(NSString *text) {
		[weakSelf beginDownloadURLString:text];
	}];
}

- (void)showSearchPrompt {
	if (self.importing || self.downloading) {
		return;
	}
	UIWindow *window = MDKeyWindow();
	if (!window) {
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[MDUI showInputInWindow:window
		title:@"Search YouTube"
		subtitle:@"Enter a song or artist name. MusicDrop downloads the first matching video as audio."
		placeholder:@"Artist – Song"
		submit:@"Search"
		initial:@""
		completion:^(NSString *text) {
		[weakSelf beginSearch:text];
	}];
}

- (void)showBatchPrompt {
	if (self.importing || self.downloading) {
		return;
	}
	UIWindow *window = MDKeyWindow();
	if (!window) {
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[MDUI showMultilineInputInWindow:window
		title:@"Batch Download"
		subtitle:@"Paste one direct audio or YouTube link per line. Downloads run in order."
		placeholder:@"Paste one URL per line…"
		submit:@"Download All"
		completion:^(NSString *text) {
		[weakSelf beginBatchDownload:text];
	}];
}

- (void)showFixLyricsPrompt {
	if (self.importing || self.downloading) {
		return;
	}
	UIWindow *window = MDKeyWindow();
	if (!window) {
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[MDUI showChoiceInWindow:window
		title:@"Fix Lyrics"
		subtitle:@"Add lyrics to songs you already have using LRCLIB."
		options:@[
			@{@"icon": @"music.note.list", @"color": [UIColor systemBlueColor], @"title": @"Scan Music Library", @"sub": @"Find songs in Music's folders"},
			@{@"icon": @"folder", @"color": [UIColor systemGreenColor], @"title": @"Choose Files", @"sub": @"Pick audio files from Files"},
		]
		selection:^(NSInteger index) {
		if (index == 0) {
			[weakSelf scanLibraryForLyrics];
		} else {
			[weakSelf showLyricsFilePicker];
		}
	}];
}

- (void)scanLibraryForLyrics {
	__weak MDImportButton *weakSelf = self;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSArray<NSDictionary *> *files = [MDLibraryScanner audioFilesInLibrary];
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf beginFixLyricsWithFiles:files];
		});
	});
}

- (void)showLyricsFilePicker {
	NSMutableOrderedSet<UTType *> *types = [NSMutableOrderedSet orderedSet];
	for (NSString *extension in @[@"mp3", @"m4a", @"m4b", @"m4r", @"aac", @"wav", @"aif", @"aiff", @"caf", @"flac"]) {
		UTType *type = [UTType typeWithFilenameExtension:extension];
		if (type) {
			[types addObject:type];
		}
	}
	if (types.count == 0 || !UTTypeAudio) {
		[self showResultWithTitle:@"Unsupported" message:@"This iOS version did not report any audio file types." success:NO];
		return;
	}
	[types addObject:UTTypeAudio];

	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types.array asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = YES;
	self.picker = picker;
	self.pickerMode = 1;

	UIViewController *presenter = MDTopViewController();
	if (!presenter) {
		MDLog(@"No view controller available to present the lyrics file picker.");
		return;
	}
	self.hidden = YES;
	[presenter presentViewController:picker animated:YES completion:nil];
}

- (void)beginFixLyricsWithFiles:(NSArray<NSDictionary *> *)files {
	if (files.count == 0) {
		[self showResultWithTitle:@"No Songs Found"
						  message:@"No audio files were found. Use Choose Files to pick the songs yourself."
						  success:NO];
		return;
	}

	self.downloading = YES;
	self.enabled = NO;
	self.alpha = 0.55;
	self.progressTitle = @"Adding Lyrics…";
	self.progressView = [MDUI showProgressInWindow:MDKeyWindow() title:@"Adding Lyrics…"];

	__weak MDImportButton *weakSelf = self;
	[MDHelperClient embedLyricsForFiles:files
		progress:^(NSString *status) {
		[weakSelf updateProgressWithStatus:status];
	} completion:^(NSUInteger embedded, NSUInteger skipped) {
		MDImportButton *strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}
		[MDUI hideProgress:strongSelf.progressView];
		strongSelf.progressView = nil;
		strongSelf.downloading = NO;
		strongSelf.enabled = YES;
		strongSelf.alpha = 1.0;
		NSString *message = [NSString stringWithFormat:@"Embedded lyrics in %lu song%@. Skipped %lu.",
			(unsigned long)embedded, embedded == 1 ? @"" : @"s", (unsigned long)skipped];
		[strongSelf showResultWithTitle:@"Lyrics Updated" message:message success:embedded > 0];
	}];
}

- (void)beginBatchDownload:(NSString *)input {
	NSMutableArray<NSString *> *entries = [NSMutableArray array];
	for (NSString *line in [input componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
		for (NSString *piece in [line componentsSeparatedByString:@","]) {
			NSString *value = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
			if (value.length == 0) {
				continue;
			}
			if ([value rangeOfString:@"://"].location == NSNotFound) {
				value = [@"https://" stringByAppendingString:value];
			}
			[entries addObject:value];
		}
	}

	if (entries.count == 0) {
		[self showResultWithTitle:@"No Links" message:@"Paste at least one URL to download." success:NO];
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[self startOperation:^{
		[weakSelf downloadEntries:entries index:0 files:[NSMutableArray array] errors:[NSMutableArray array]];
	}];
}

- (void)downloadEntries:(NSArray<NSString *> *)entries
				  index:(NSUInteger)index
				   files:(NSMutableArray<NSURL *> *)files
				  errors:(NSMutableArray<NSString *> *)errors {
	if (index >= entries.count) {
		self.downloading = NO;
		self.enabled = YES;
		self.alpha = 1.0;
		[MDUI hideProgress:self.progressView];
		self.progressView = nil;
		self.pendingErrors = errors;
		if (files.count > 0) {
			[self beginImport:files];
		} else {
			[self showResultWithTitle:@"Downloads Failed"
							  message:[errors componentsJoinedByString:@"\n"]
							  success:NO];
		}
		return;
	}

	NSString *value = entries[index];
	NSURL *url = [NSURL URLWithString:value];
	self.progressTitle = [NSString stringWithFormat:@"Downloading %lu of %lu…",
		(unsigned long)(index + 1), (unsigned long)entries.count];
	if (!url) {
		[errors addObject:[NSString stringWithFormat:@"Invalid URL: %@", value]];
		[self downloadEntries:entries index:index + 1 files:files errors:errors];
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[[MDDownloadManager sharedManager] downloadURL:url
		progress:^(NSString *status) {
		[weakSelf updateProgressWithStatus:status];
	} completion:^(NSURL *localFileURL, NSError *error) {
		MDImportButton *strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}
		if (localFileURL && !error) {
			[files addObject:localFileURL];
		} else {
			[errors addObject:[NSString stringWithFormat:@"%@: %@", value,
				error.localizedDescription ?: @"Failed"]];
		}
		[strongSelf downloadEntries:entries index:index + 1 files:files errors:errors];
	}];
}

- (void)beginDownloadURLString:(NSString *)input {
	if (self.importing || self.downloading) {
		return;
	}

	NSString *value = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (value.length == 0) {
		[self showResultWithTitle:@"No URL" message:@"Enter a direct audio or YouTube HTTPS URL." success:NO];
		return;
	}
	if ([value rangeOfString:@"://"].location == NSNotFound) {
		value = [@"https://" stringByAppendingString:value];
	}
	NSURL *url = [NSURL URLWithString:value];
	if (!url) {
		[self showResultWithTitle:@"Invalid URL" message:@"That URL is not valid." success:NO];
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[self startOperation:^{
		[[MDDownloadManager sharedManager] downloadURL:url
			progress:^(NSString *status) {
				[weakSelf updateProgressWithStatus:status];
			}
			completion:^(NSURL *localFileURL, NSError *error) {
				[weakSelf finishOperationWithFileURL:localFileURL error:error];
			}];
	}];
}

- (void)beginSearch:(NSString *)input {
	if (self.importing || self.downloading) {
		return;
	}

	NSString *value = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (value.length == 0) {
		[self showResultWithTitle:@"No Query" message:@"Enter a song or artist name to search." success:NO];
		return;
	}

	__weak MDImportButton *weakSelf = self;
	[self startOperation:^{
		[[MDDownloadManager sharedManager] searchYouTube:value
			progress:^(NSString *status) {
				[weakSelf updateProgressWithStatus:status];
			}
			completion:^(NSURL *localFileURL, NSError *error) {
				[weakSelf finishOperationWithFileURL:localFileURL error:error];
			}];
	}];
}

- (void)startOperation:(void (^)(void))operation {
	self.downloading = YES;
	self.enabled = NO;
	self.alpha = 0.55;
	self.progressTitle = @"Downloading…";
	self.progressView = [MDUI showProgressInWindow:MDKeyWindow() title:@"Downloading…"];
	operation();
}

- (void)updateProgressWithStatus:(NSString *)status {
	NSString *detail = status ?: @"Working…";
	CGFloat percentage = 0.0;
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+(?:\\.[0-9]+)?)%"
																	 options:0
																	   error:nil];
	NSTextCheckingResult *match = [regex firstMatchInString:detail
													options:0
													  range:NSMakeRange(0, detail.length)];
	if (match.numberOfRanges > 1) {
		percentage = [[detail substringWithRange:[match rangeAtIndex:1]] doubleValue] / 100.0;
	}
	[MDUI updateProgress:self.progressView title:self.progressTitle detail:detail percentage:percentage];
}

- (void)finishOperationWithFileURL:(NSURL *)localFileURL error:(NSError *)error {
	self.downloading = NO;
	self.enabled = YES;
	self.alpha = 1.0;
	[MDUI hideProgress:self.progressView];
	self.progressView = nil;

	if (localFileURL && !error) {
		[self beginImport:@[localFileURL]];
	} else {
		[self showResultWithTitle:@"Download Failed"
						  message:error.localizedDescription ?: @"The download failed."
						  success:NO];
	}
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
	didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSInteger mode = self.pickerMode;
	[self.picker dismissViewControllerAnimated:YES completion:^{
		self.picker = nil;
		self.hidden = NO;
		if (urls.count == 0) {
			return;
		}
		if (mode == 1) {
			NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
			for (NSURL *url in urls) {
				NSDictionary *metadata = [MDLibraryScanner metadataForPath:url.path];
				if (metadata) {
					[files addObject:metadata];
				}
			}
			[self beginFixLyricsWithFiles:files];
		} else {
			[self beginImport:urls];
		}
	}];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	self.picker = nil;
	self.hidden = NO;
	[MDImportButton installIfNeeded];
}

- (void)beginImport:(NSArray<NSURL *> *)urls {
	if (self.importing || self.downloading || urls.count == 0) {
		return;
	}
	self.importing = YES;
	self.enabled = NO;
	self.alpha = 0.55;
	self.progressTitle = @"Importing…";
	self.progressView = [MDUI showProgressInWindow:MDKeyWindow() title:@"Importing…"];

	__weak MDImportButton *weakSelf = self;
	[[MDImporter sharedImporter] importURLs:urls
		progress:^(NSString *status) {
			[weakSelf updateProgressWithStatus:status];
		} completion:^(NSUInteger imported, NSArray<NSString *> *errors) {
		MDImportButton *strongSelf = weakSelf;
		if (!strongSelf) {
			return;
		}
		[MDUI hideProgress:strongSelf.progressView];
		strongSelf.progressView = nil;
		strongSelf.importing = NO;
		strongSelf.enabled = YES;
		strongSelf.alpha = 1.0;
		[MDImportButton installIfNeeded];
		[strongSelf showImportResultWithImported:imported errors:errors];
	}];
}

- (void)showImportResultWithImported:(NSUInteger)imported errors:(NSArray<NSString *> *)errors {
	NSString *message = nil;
	BOOL success = imported > 0;
	NSMutableArray<NSString *> *allErrors = [NSMutableArray arrayWithArray:errors ?: @[]];
	if (self.pendingErrors.count > 0) {
		[allErrors addObjectsFromArray:self.pendingErrors];
		self.pendingErrors = nil;
	}
	errors = allErrors;

	if (imported > 0) {
		NSString *items = imported == 1 ? @"item" : @"items";
		message = [NSString stringWithFormat:@"Queued %lu %@ in Music.\n\nKeep Music open while the import finishes.",
				   (unsigned long)imported, items];
		if (errors.count > 0) {
			message = [message stringByAppendingFormat:@"\n\n%lu file%@ could not be imported:\n• %@",
					   (unsigned long)errors.count, errors.count == 1 ? @"" : @"s",
					   [[errors subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)5, errors.count))] componentsJoinedByString:@"\n• "]];
		}
	} else {
		message = errors.count > 0
			? [NSString stringWithFormat:@"• %@", [errors componentsJoinedByString:@"\n• "]]
			: @"No files were selected.";
	}

	[self showResultWithTitle:success ? @"Added to Music" : @"Nothing Imported"
					  message:message
					  success:success];
}

- (void)showResultWithTitle:(NSString *)title message:(NSString *)message success:(BOOL)success {
	UIWindow *window = MDKeyWindow();
	if (!window) {
		MDLog(@"Cannot show result, no window: %@", title);
		return;
	}
	[MDUI showResultInWindow:window title:title message:message success:success handler:nil];
}

@end
