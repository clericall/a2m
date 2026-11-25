#import "MDRuntimeDump.h"
#import "MDLog.h"

#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static BOOL MDIsInteresting(NSString *name) {
	NSString *lower = name.lowercaseString;
	return [lower containsString:@"lyric"] ||
		   [lower containsString:@"nowplaying"] ||
		   [lower containsString:@"now_playing"];
}

static void MDDumpViews(UIView *view, NSInteger depth) {
	if (depth > 12) {
		return;
	}
	NSString *name = NSStringFromClass(view.class);
	NSString *label = view.accessibilityLabel ?: @"";
	if (MDIsInteresting(name) || MDIsInteresting(label)) {
		NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
											withString:@" "
									   startingAtIndex:0];
		MDLog(@"VIEW %@%@ | label='%@' | hidden=%d", indent, name, label, view.hidden);
	}
	for (UIView *subview in view.subviews) {
		MDDumpViews(subview, depth + 1);
	}
}

@implementation MDRuntimeDump

+ (void)logLyricsRuntimeInfo {
	MDLog(@"===== LYRICS RUNTIME DUMP START =====");

	unsigned int classCount = 0;
	Class *classes = objc_copyClassList(&classCount);
	if (classes) {
		for (unsigned int index = 0; index < classCount; index++) {
			Class cls = classes[index];
			NSString *className = NSStringFromClass(cls);
			if (!MDIsInteresting(className)) {
				continue;
			}
			MDLog(@"CLASS %@", className);

			unsigned int methodCount = 0;
			Method *methods = class_copyMethodList(cls, &methodCount);
			for (unsigned int mIndex = 0; mIndex < methodCount; mIndex++) {
				NSString *selector = NSStringFromSelector(method_getName(methods[mIndex]));
				MDLog(@"  METHOD -%@", selector);
			}
			free(methods);

			unsigned int ivarCount = 0;
			Ivar *ivars = class_copyIvarList(cls, &ivarCount);
			for (unsigned int iIndex = 0; iIndex < ivarCount; iIndex++) {
				MDLog(@"  IVAR %s", ivar_getName(ivars[iIndex]));
			}
			free(ivars);
		}
		free(classes);
	}

	UIApplication *application = [UIApplication sharedApplication];
	for (UIWindow *window in application.windows) {
		MDLog(@"WINDOW %@", NSStringFromClass(window.class));
		MDDumpViews(window, 0);
	}

	MDLog(@"===== LYRICS RUNTIME DUMP END =====");
}

@end
