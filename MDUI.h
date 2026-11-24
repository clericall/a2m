#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MDMenuAction) {
	MDMenuActionImportFiles = 0,
	MDMenuActionDownloadURL,
	MDMenuActionSearch,
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
					handler:(void (^)(void))handler;

+ (void)showSettingsInWindow:(UIWindow *)window;
+ (void)showHelpInWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
