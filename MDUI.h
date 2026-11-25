#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MDMenuAction) {
	MDMenuActionImportFiles = 0,
	MDMenuActionDownloadURL,
	MDMenuActionSearch,
	MDMenuActionBatchDownload,
	MDMenuActionFixLyrics,
	MDMenuActionSettings,
	MDMenuActionHelp,
};

@interface MDUI : NSObject

/// Bottom-sheet menu. `selection` is not called on cancel.
+ (void)showMenuInWindow:(UIWindow *)window
			  selection:(void (^)(MDMenuAction action))selection;

/// Input card with a text field and clipboard paste. `completion` is only
/// called when the user submits, never on cancel.
+ (void)showInputInWindow:(UIWindow *)window
					title:(NSString *)title
				 subtitle:(NSString *)subtitle
			  placeholder:(NSString *)placeholder
				   submit:(NSString *)submitTitle
				  initial:(NSString *)initialText
			   completion:(void (^)(NSString *text))completion;

/// Multi-line input card for pasting several URLs.
+ (void)showMultilineInputInWindow:(UIWindow *)window
							 title:(NSString *)title
						  subtitle:(NSString *)subtitle
					   placeholder:(NSString *)placeholder
							submit:(NSString *)submitTitle
						completion:(void (^)(NSString *text))completion;

/// Choice card with two or more rows, returning the selected index.
+ (void)showChoiceInWindow:(UIWindow *)window
					 title:(NSString *)title
				  subtitle:(NSString *)subtitle
				   options:(NSArray<NSDictionary *> *)options
				 selection:(void (^)(NSInteger index))selection;

/// Progress card. Returns a handle used by update/hide.
+ (UIView *)showProgressInWindow:(UIWindow *)window title:(NSString *)title;
+ (void)updateProgress:(UIView *)view
				 title:(NSString *)title
				detail:(NSString *)detail
			percentage:(CGFloat)percentage;
+ (void)hideProgress:(UIView *)view;

+ (void)showResultInWindow:(UIWindow *)window
					 title:(NSString *)title
				   message:(NSString *)message
				   success:(BOOL)success
					handler:(nullable void (^)(void))handler;

+ (void)showSettingsInWindow:(UIWindow *)window;
+ (void)showHelpInWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
