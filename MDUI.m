#import "MDUI.h"
#import "MDPreferences.h"

#import <QuartzCore/QuartzCore.h>

static UIColor *MDPink(void) {
	return [UIColor colorWithRed:0.98 green:0.20 blue:0.35 alpha:1.0];
}

static UIColor *MDDynamic(UIColor *light, UIColor *dark) {
	if (@available(iOS 13.0, *)) {
		return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traits) {
			return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
		}];
	}
	return light;
}

static UIColor *MDCardColor(void) {
	return MDDynamic([UIColor colorWithWhite:0.98 alpha:1.0],
					 [UIColor colorWithWhite:0.12 alpha:1.0]);
}

static UIColor *MDRowColor(void) {
	return MDDynamic([UIColor whiteColor], [UIColor colorWithWhite:0.18 alpha:1.0]);
}

static UIColor *MDText(void) {
	return MDDynamic([UIColor blackColor], [UIColor whiteColor]);
}

static UIColor *MDSubtext(void) {
	return MDDynamic([UIColor darkGrayColor], [UIColor lightGrayColor]);
}

@interface MDOverlayView : UIView
@property (nonatomic, strong) UIView *card;
@property (nonatomic, assign) CGFloat cardBaseY;
@property (nonatomic, copy, nullable) void (^onDismiss)(void);
@property (nonatomic, copy, nullable) void (^menuSelection)(MDMenuAction action);
@property (nonatomic, copy, nullable) void (^inputCompletion)(NSString *text);
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, copy, nullable) void (^choiceSelection)(NSInteger index);
@property (nonatomic, strong) UILabel *progressTitle;
@property (nonatomic, strong) UILabel *progressDetail;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
- (void)buildCardWithHeight:(CGFloat)height bottom:(BOOL)bottom;
- (void)dismissAnimated:(BOOL)animated;
@end

@implementation MDOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
																			action:@selector(backgroundTapped:)];
		tap.delegate = (id<UIGestureRecognizerDelegate>)self;
		[self addGestureRecognizer:tap];

		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(keyboardWillShow:)
													 name:UIKeyboardWillShowNotification
												   object:nil];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(keyboardWillHide:)
													 name:UIKeyboardWillHideNotification
												   object:nil];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
	return touch.view == self;
}

- (void)backgroundTapped:(__unused UITapGestureRecognizer *)gesture {
	[self dismissAnimated:YES];
}

- (void)buildCardWithHeight:(CGFloat)height bottom:(BOOL)bottom {
	CGFloat width = MIN(CGRectGetWidth(self.bounds) - 32.0, 380.0);
	CGFloat y;
	if (bottom) {
		y = CGRectGetHeight(self.bounds) - height - 14.0;
	} else {
		y = (CGRectGetHeight(self.bounds) - height) / 2.0;
	}
	CGRect frame = CGRectMake((CGRectGetWidth(self.bounds) - width) / 2.0, y, width, height);
	UIView *card = [[UIView alloc] initWithFrame:frame];
	card.backgroundColor = MDCardColor();
	card.layer.cornerRadius = 22.0;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.layer.shadowColor = [UIColor blackColor].CGColor;
	card.layer.shadowOpacity = 0.28;
	card.layer.shadowRadius = 18.0;
	card.layer.shadowOffset = CGSizeMake(0, 8);
	card.clipsToBounds = NO;
	[self addSubview:card];
	self.card = card;
	self.cardBaseY = y;
}

- (void)dismissAnimated:(BOOL)animated {
	[self endEditing:YES];
	void (^handler)(void) = self.onDismiss;
	self.onDismiss = nil;
	if (!animated) {
		[self removeFromSuperview];
		if (handler) {
			handler();
		}
		return;
	}
	[UIView animateWithDuration:0.18 animations:^{
		self.alpha = 0.0;
		self.card.transform = CGAffineTransformMakeScale(0.94, 0.94);
	} completion:^(BOOL finished) {
		[self removeFromSuperview];
		if (handler) {
			handler();
		}
	}];
}

- (void)keyboardWillShow:(NSNotification *)note {
	CGRect keyboard = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	CGFloat overlap = CGRectGetMaxY(self.card.frame) - CGRectGetMinY(keyboard) + 12.0;
	if (overlap <= 0) {
		return;
	}
	[UIView animateWithDuration:0.2 animations:^{
		CGRect frame = self.card.frame;
		frame.origin.y -= overlap;
		self.card.frame = frame;
	}];
}

- (void)keyboardWillHide:(__unused NSNotification *)note {
	[UIView animateWithDuration:0.2 animations:^{
		CGRect frame = self.card.frame;
		frame.origin.y = self.cardBaseY;
		self.card.frame = frame;
	}];
}

@end

static void MDAddGradientIcon(UIView *card, CGFloat x, CGFloat y, CGFloat size) {
	UIView *icon = [[UIView alloc] initWithFrame:CGRectMake(x, y, size, size)];
	icon.layer.cornerRadius = size * 0.28;
	icon.layer.cornerCurve = kCACornerCurveContinuous;
	icon.clipsToBounds = YES;
	CAGradientLayer *gradient = [CAGradientLayer layer];
	gradient.frame = icon.bounds;
	gradient.colors = @[
		(id)[MDPink() CGColor],
		(id)[[UIColor colorWithRed:1.0 green:0.42 blue:0.52 alpha:1.0] CGColor],
	];
	gradient.startPoint = CGPointMake(0, 0);
	gradient.endPoint = CGPointMake(1, 1);
	[icon.layer insertSublayer:gradient atIndex:0];

	UIImageView *note = [[UIImageView alloc] initWithFrame:CGRectMake(size * 0.23, size * 0.23, size * 0.54, size * 0.54)];
	note.image = [UIImage systemImageNamed:@"music.note"];
	note.tintColor = [UIColor whiteColor];
	note.contentMode = UIViewContentModeScaleAspectFit;
	[icon addSubview:note];
	[card addSubview:icon];
}

static UIView *MDRow(CGFloat width, NSString *symbol, UIColor *tint, NSString *title,
					 NSString *subtitle, NSInteger tag, id target, SEL action) {
	UIView *row = [[UIView alloc] initWithFrame:CGRectMake(12, 0, width - 24, 60)];
	row.backgroundColor = MDRowColor();
	row.layer.cornerRadius = 14.0;
	row.layer.cornerCurve = kCACornerCurveContinuous;

	UIView *iconBg = [[UIView alloc] initWithFrame:CGRectMake(10, 10, 40, 40)];
	iconBg.backgroundColor = [tint colorWithAlphaComponent:0.15];
	iconBg.layer.cornerRadius = 12.0;
	iconBg.layer.cornerCurve = kCACornerCurveContinuous;
	UIImageView *image = [[UIImageView alloc] initWithFrame:CGRectMake(9, 9, 22, 22)];
	image.image = [UIImage systemImageNamed:symbol];
	image.tintColor = tint;
	image.contentMode = UIViewContentModeScaleAspectFit;
	[iconBg addSubview:image];
	[row addSubview:iconBg];

	UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(60, 11, width - 130, 21)];
	titleLabel.text = title;
	titleLabel.textColor = MDText();
	titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
	[row addSubview:titleLabel];

	UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(60, 32, width - 130, 16)];
	subLabel.text = subtitle;
	subLabel.textColor = MDSubtext();
	subLabel.font = [UIFont systemFontOfSize:12];
	[row addSubview:subLabel];

	UIImageView *chevron = [[UIImageView alloc] initWithFrame:CGRectMake(width - 58, 22, 16, 16)];
	chevron.image = [UIImage systemImageNamed:@"chevron.right"];
	chevron.tintColor = MDSubtext();
	chevron.contentMode = UIViewContentModeScaleAspectFit;
	[row addSubview:chevron];

	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	button.frame = row.bounds;
	button.tag = tag;
	[button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
	[row addSubview:button];
	return row;
}

static UIButton *MDButton(NSString *title, BOOL primary) {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
	button.layer.cornerRadius = 12.0;
	button.layer.cornerCurve = kCACornerCurveContinuous;
	button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
	[button setTitle:title forState:UIControlStateNormal];
	if (primary) {
		[button setBackgroundColor:MDPink()];
		[button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	} else {
		[button setBackgroundColor:MDRowColor()];
		[button setTitleColor:MDText() forState:UIControlStateNormal];
	}
	return button;
}

@implementation MDUI

+ (void)showMenuInWindow:(UIWindow *)window selection:(void (^)(MDMenuAction))selection {
	if (!window) {
		return;
	}
	for (UIView *view in window.subviews) {
		if ([view isKindOfClass:[MDOverlayView class]]) {
			[view removeFromSuperview];
		}
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	overlay.menuSelection = selection;

	CGFloat width = MIN(window.bounds.size.width - 32.0, 380.0);
	CGFloat height = 584.0;
	[overlay buildCardWithHeight:height bottom:YES];
	UIView *card = overlay.card;

	MDAddGradientIcon(card, 18, 18, 52);

	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(82, 22, width - 100, 24)];
	title.text = @"MusicDrop";
	title.textColor = MDText();
	title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
	[card addSubview:title];

	UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(82, 48, width - 100, 18)];
	subtitle.text = @"Add music to your library";
	subtitle.textColor = MDSubtext();
	subtitle.font = [UIFont systemFontOfSize:13];
	[card addSubview:subtitle];

	NSArray *rows = @[
		@{@"icon": @"folder", @"color": [UIColor systemBlueColor], @"title": @"Import Files", @"sub": @"Add DRM-free audio from Files"},
		@{@"icon": @"link", @"color": MDPink(), @"title": @"Download URL", @"sub": @"Direct audio or YouTube link"},
		@{@"icon": @"magnifyingglass", @"color": [UIColor systemPurpleColor], @"title": @"Search by Name", @"sub": @"Find a track on YouTube"},
		@{@"icon": @"list.bullet", @"color": [UIColor systemOrangeColor], @"title": @"Batch Download", @"sub": @"Paste several links at once"},
		@{@"icon": @"text.bubble", @"color": [UIColor systemGreenColor], @"title": @"Fix Lyrics", @"sub": @"Add lyrics to existing songs"},
		@{@"icon": @"gearshape", @"color": [UIColor systemGrayColor], @"title": @"Settings", @"sub": @"Lyrics, artwork, format"},
		@{@"icon": @"questionmark.circle", @"color": [UIColor systemTealColor], @"title": @"Help", @"sub": @"How MusicDrop works"},
	];
	CGFloat y = 86.0;
	for (NSInteger index = 0; index < rows.count; index++) {
		NSDictionary *info = rows[index];
		UIView *row = MDRow(width, info[@"icon"], info[@"color"], info[@"title"], info[@"sub"], index, overlay, @selector(menuRowTapped:));
		CGRect frame = row.frame;
		frame.origin.y = y;
		row.frame = frame;
		[card addSubview:row];
		y += 66.0;
	}

	UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(0, height - 26, width, 16)];
	footer.text = @"Download only what you have the right to save";
	footer.textColor = MDSubtext();
	footer.font = [UIFont systemFontOfSize:11];
	footer.textAlignment = NSTextAlignmentCenter;
	[card addSubview:footer];

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeTranslation(0, 30);
	[UIView animateWithDuration:0.25 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	}];
}

+ (void)showInputInWindow:(UIWindow *)window
					title:(NSString *)title
				 subtitle:(NSString *)subtitle
			  placeholder:(NSString *)placeholder
				   submit:(NSString *)submitTitle
				  initial:(NSString *)initialText
			   completion:(void (^)(NSString *))completion {
	if (!window) {
		return;
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	overlay.inputCompletion = completion;

	CGFloat height = 268.0;
	[overlay buildCardWithHeight:height bottom:NO];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, width - 40, 24)];
	titleLabel.text = title;
	titleLabel.textColor = MDText();
	titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
	[card addSubview:titleLabel];

	UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 46, width - 40, 36)];
	subLabel.text = subtitle;
	subLabel.textColor = MDSubtext();
	subLabel.font = [UIFont systemFontOfSize:12];
	subLabel.numberOfLines = 2;
	[card addSubview:subLabel];

	UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(20, 90, width - 40, 44)];
	field.placeholder = placeholder;
	field.text = initialText;
	field.textColor = MDText();
	field.font = [UIFont systemFontOfSize:14];
	field.keyboardType = UIKeyboardTypeURL;
	field.autocapitalizationType = UITextAutocapitalizationTypeNone;
	field.autocorrectionType = UITextAutocorrectionTypeNo;
	field.clearButtonMode = UITextFieldViewModeWhileEditing;
	field.backgroundColor = MDRowColor();
	field.layer.cornerRadius = 10.0;
	UIView *padding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
	field.leftView = padding;
	field.leftViewMode = UITextFieldViewModeAlways;
	[card addSubview:field];
	overlay.inputField = field;

	NSString *pasted = [UIPasteboard generalPasteboard].string;
	if (pasted.length > 0) {
		UIButton *paste = [UIButton buttonWithType:UIButtonTypeCustom];
		paste.frame = CGRectMake(0, 0, 52, 44);
		paste.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
		[paste setTitle:@"Paste" forState:UIControlStateNormal];
		[paste setTitleColor:MDPink() forState:UIControlStateNormal];
		[paste addTarget:overlay action:@selector(pasteTapped:) forControlEvents:UIControlEventTouchUpInside];
		field.rightView = paste;
		field.rightViewMode = UITextFieldViewModeAlways;
	}

	UILabel *formatLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 146, 80, 20)];
	formatLabel.text = @"Format";
	formatLabel.textColor = MDSubtext();
	formatLabel.font = [UIFont systemFontOfSize:12];
	[card addSubview:formatLabel];

	NSArray *formats = @[@"m4a", @"mp3", @"flac"];
	UISegmentedControl *segmented = [[UISegmentedControl alloc] initWithItems:formats];
	segmented.frame = CGRectMake(90, 142, width - 110, 28);
	NSString *current = [MDPreferences downloadFormat];
	NSUInteger selected = [formats indexOfObject:current];
	segmented.selectedSegmentIndex = selected == NSNotFound ? 0 : (NSInteger)selected;
	[segmented addTarget:overlay action:@selector(formatChanged:) forControlEvents:UIControlEventValueChanged];
	[card addSubview:segmented];

	UIButton *cancel = MDButton(@"Cancel", NO);
	cancel.frame = CGRectMake(20, 190, (width - 52) / 2.0, 44);
	[cancel addTarget:overlay action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:cancel];

	UIButton *submit = MDButton(submitTitle, YES);
	submit.frame = CGRectMake(20 + (width - 52) / 2.0 + 12, 190, (width - 52) / 2.0, 44);
	[submit addTarget:overlay action:@selector(submitTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:submit];

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeScale(0.94, 0.94);
	[UIView animateWithDuration:0.2 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	} completion:^(BOOL finished) {
		[field becomeFirstResponder];
	}];
}

+ (void)showMultilineInputInWindow:(UIWindow *)window
							 title:(NSString *)title
						  subtitle:(NSString *)subtitle
					   placeholder:(NSString *)placeholder
							submit:(NSString *)submitTitle
						completion:(void (^)(NSString *text))completion {
	if (!window) {
		return;
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	overlay.inputCompletion = completion;

	CGFloat height = 310.0;
	[overlay buildCardWithHeight:height bottom:NO];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, width - 40, 24)];
	titleLabel.text = title;
	titleLabel.textColor = MDText();
	titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
	[card addSubview:titleLabel];

	UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 46, width - 40, 36)];
	subLabel.text = subtitle;
	subLabel.textColor = MDSubtext();
	subLabel.font = [UIFont systemFontOfSize:12];
	subLabel.numberOfLines = 2;
	[card addSubview:subLabel];

	UITextView *textView = [[UITextView alloc] initWithFrame:CGRectMake(20, 90, width - 40, 100)];
	textView.text = placeholder;
	textView.textColor = MDSubtext();
	textView.font = [UIFont systemFontOfSize:13];
	textView.backgroundColor = MDRowColor();
	textView.layer.cornerRadius = 10.0;
	textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
	textView.autocorrectionType = UITextAutocorrectionTypeNo;
	textView.keyboardType = UIKeyboardTypeURL;
	[card addSubview:textView];
	overlay.textView = textView;

	UIButton *paste = [UIButton buttonWithType:UIButtonTypeCustom];
	paste.frame = CGRectMake(20, 196, 90, 30);
	paste.layer.cornerRadius = 8.0;
	paste.backgroundColor = MDRowColor();
	paste.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
	[paste setTitle:@"Paste" forState:UIControlStateNormal];
	[paste setTitleColor:MDPink() forState:UIControlStateNormal];
	[paste addTarget:overlay action:@selector(pasteMultilineTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:paste];

	NSArray *formats = @[@"m4a", @"mp3", @"flac"];
	UISegmentedControl *segmented = [[UISegmentedControl alloc] initWithItems:formats];
	segmented.frame = CGRectMake(120, 196, width - 140, 30);
	NSString *current = [MDPreferences downloadFormat];
	NSUInteger selected = [formats indexOfObject:current];
	segmented.selectedSegmentIndex = selected == NSNotFound ? 0 : (NSInteger)selected;
	[segmented addTarget:overlay action:@selector(formatChanged:) forControlEvents:UIControlEventValueChanged];
	[card addSubview:segmented];

	UIButton *cancel = MDButton(@"Cancel", NO);
	cancel.frame = CGRectMake(20, 238, (width - 52) / 2.0, 44);
	[cancel addTarget:overlay action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:cancel];

	UIButton *submit = MDButton(submitTitle, YES);
	submit.frame = CGRectMake(20 + (width - 52) / 2.0 + 12, 238, (width - 52) / 2.0, 44);
	[submit addTarget:overlay action:@selector(submitMultilineTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:submit];

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeScale(0.94, 0.94);
	[UIView animateWithDuration:0.2 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	} completion:^(BOOL finished) {
		[textView becomeFirstResponder];
	}];
}

+ (void)showChoiceInWindow:(UIWindow *)window
					 title:(NSString *)title
				  subtitle:(NSString *)subtitle
				   options:(NSArray<NSDictionary *> *)options
				 selection:(void (^)(NSInteger index))selection {
	if (!window || options.count == 0) {
		return;
	}
	for (UIView *view in window.subviews) {
		if ([view isKindOfClass:[MDOverlayView class]]) {
			[view removeFromSuperview];
		}
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	overlay.choiceSelection = selection;

	CGFloat rowHeight = 62.0;
	CGFloat height = 92.0 + options.count * (rowHeight + 6.0) + 16.0;
	[overlay buildCardWithHeight:height bottom:NO];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, width - 40, 24)];
	titleLabel.text = title;
	titleLabel.textColor = MDText();
	titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
	[card addSubview:titleLabel];

	UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 46, width - 40, 34)];
	subLabel.text = subtitle;
	subLabel.textColor = MDSubtext();
	subLabel.font = [UIFont systemFontOfSize:12];
	subLabel.numberOfLines = 2;
	[card addSubview:subLabel];

	CGFloat y = 90.0;
	for (NSInteger index = 0; index < options.count; index++) {
		NSDictionary *info = options[index];
		UIView *row = MDRow(width, info[@"icon"], info[@"color"], info[@"title"], info[@"sub"], index, overlay, @selector(choiceRowTapped:));
		CGRect frame = row.frame;
		frame.origin.y = y;
		row.frame = frame;
		[card addSubview:row];
		y += rowHeight + 6.0;
	}

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeScale(0.94, 0.94);
	[UIView animateWithDuration:0.2 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	}];
}

+ (UIView *)showProgressInWindow:(UIWindow *)window title:(NSString *)title {
	if (!window) {
		return nil;
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	[overlay buildCardWithHeight:186.0 bottom:NO];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	spinner.color = MDPink();
	spinner.center = CGPointMake(width / 2.0, 42);
	[spinner startAnimating];
	[card addSubview:spinner];
	overlay.spinner = spinner;

	UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 74, width - 32, 22)];
	titleLabel.text = title;
	titleLabel.textColor = MDText();
	titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
	titleLabel.textAlignment = NSTextAlignmentCenter;
	[card addSubview:titleLabel];
	overlay.progressTitle = titleLabel;

	UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, width - 32, 38)];
	detail.text = @"Preparing…";
	detail.textColor = MDSubtext();
	detail.font = [UIFont systemFontOfSize:12];
	detail.numberOfLines = 2;
	detail.textAlignment = NSTextAlignmentCenter;
	[card addSubview:detail];
	overlay.progressDetail = detail;

	UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	bar.frame = CGRectMake(24, 146, width - 48, 6);
	bar.progressTintColor = MDPink();
	bar.hidden = YES;
	[card addSubview:bar];
	overlay.progressBar = bar;

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeScale(0.94, 0.94);
	[UIView animateWithDuration:0.2 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	}];
	return overlay;
}

+ (void)updateProgress:(UIView *)view title:(NSString *)title detail:(NSString *)detail percentage:(CGFloat)percentage {
	if (![view isKindOfClass:[MDOverlayView class]]) {
		return;
	}
	MDOverlayView *overlay = (MDOverlayView *)view;
	dispatch_async(dispatch_get_main_queue(), ^{
		overlay.progressTitle.text = title;
		overlay.progressDetail.text = detail;
		if (percentage > 0.0 && percentage <= 1.0) {
			overlay.progressBar.hidden = NO;
			overlay.progressBar.progress = percentage;
			overlay.spinner.hidden = YES;
		} else {
			overlay.progressBar.hidden = YES;
			overlay.spinner.hidden = NO;
		}
	});
}

+ (void)hideProgress:(UIView *)view {
	if ([view isKindOfClass:[MDOverlayView class]]) {
		[(MDOverlayView *)view dismissAnimated:YES];
	}
}

+ (void)showResultInWindow:(UIWindow *)window
					 title:(NSString *)title
				   message:(NSString *)message
				   success:(BOOL)success
					handler:(void (^)(void))handler {
	if (!window) {
		return;
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	overlay.onDismiss = handler;
	CGFloat height = 224.0;
	[overlay buildCardWithHeight:height bottom:NO];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(width / 2.0 - 22, 20, 44, 44)];
	NSString *symbol = success ? @"checkmark.circle.fill" : @"xmark.circle.fill";
	icon.image = [UIImage systemImageNamed:symbol];
	icon.tintColor = success ? [UIColor systemGreenColor] : MDPink();
	icon.contentMode = UIViewContentModeScaleAspectFit;
	[card addSubview:icon];

	UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 72, width - 32, 24)];
	titleLabel.text = title;
	titleLabel.textColor = MDText();
	titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
	titleLabel.textAlignment = NSTextAlignmentCenter;
	[card addSubview:titleLabel];

	UILabel *messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 102, width - 40, 64)];
	messageLabel.text = message;
	messageLabel.textColor = MDSubtext();
	messageLabel.font = [UIFont systemFontOfSize:13];
	messageLabel.numberOfLines = 4;
	messageLabel.textAlignment = NSTextAlignmentCenter;
	[card addSubview:messageLabel];

	UIButton *ok = MDButton(@"Done", YES);
	ok.frame = CGRectMake(20, height - 60, width - 40, 44);
	[ok addTarget:overlay action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:ok];

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeScale(0.94, 0.94);
	[UIView animateWithDuration:0.2 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	}];
}

+ (void)showSettingsInWindow:(UIWindow *)window {
	if (!window) {
		return;
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	[overlay buildCardWithHeight:500.0 bottom:YES];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	MDAddGradientIcon(card, 16, 14, 42);
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(68, 18, width - 84, 26)];
	title.text = @"Settings";
	title.textColor = MDText();
	title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
	[card addSubview:title];

	NSArray *toggles = @[
		@{@"title": @"Embed Lyrics", @"sub": @"Fetch from LRCLIB and embed into the song", @"key": @"lyrics"},
		@{@"title": @"Embed Artwork", @"sub": @"Add cover art and metadata on YouTube downloads", @"key": @"artwork"},
		@{@"title": @"Detailed Progress", @"sub": @"Show download percentage and status", @"key": @"progress"},
	];
	CGFloat y = 72.0;
	for (NSDictionary *info in toggles) {
		UIView *row = [[UIView alloc] initWithFrame:CGRectMake(12, y, width - 24, 62)];
		row.backgroundColor = MDRowColor();
		row.layer.cornerRadius = 14.0;
		row.layer.cornerCurve = kCACornerCurveContinuous;

		UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, width - 100, 20)];
		label.text = info[@"title"];
		label.textColor = MDText();
		label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
		[row addSubview:label];

		UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(14, 32, width - 100, 16)];
		sub.text = info[@"sub"];
		sub.textColor = MDSubtext();
		sub.font = [UIFont systemFontOfSize:11];
		[row addSubview:sub];

		UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectMake(width - 76, 16, 50, 31)];
		NSString *key = info[@"key"];
		if ([key isEqualToString:@"lyrics"]) {
			toggle.on = [MDPreferences embedLyrics];
		} else if ([key isEqualToString:@"artwork"]) {
			toggle.on = [MDPreferences embedArtwork];
		} else {
			toggle.on = [MDPreferences showProgressDetails];
		}
		toggle.tag = [key isEqualToString:@"lyrics"] ? 1 : ([key isEqualToString:@"artwork"] ? 2 : 3);
		[toggle addTarget:overlay action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
		[row addSubview:toggle];
		[card addSubview:row];
		y += 70.0;
	}

	UILabel *formatLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, y + 4, width - 40, 18)];
	formatLabel.text = @"YouTube audio format";
	formatLabel.textColor = MDSubtext();
	formatLabel.font = [UIFont systemFontOfSize:12];
	[card addSubview:formatLabel];

	NSArray *formats = @[@"m4a", @"mp3", @"flac"];
	UISegmentedControl *segmented = [[UISegmentedControl alloc] initWithItems:formats];
	segmented.frame = CGRectMake(20, y + 26, width - 40, 30);
	NSString *current = [MDPreferences downloadFormat];
	NSUInteger selected = [formats indexOfObject:current];
	segmented.selectedSegmentIndex = selected == NSNotFound ? 0 : (NSInteger)selected;
	[segmented addTarget:overlay action:@selector(formatChanged:) forControlEvents:UIControlEventValueChanged];
	[card addSubview:segmented];

	UIButton *clear = MDButton(@"Clear Cached Data", NO);
	clear.frame = CGRectMake(20, y + 64, width - 40, 44);
	[clear addTarget:overlay action:@selector(clearCacheTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:clear];

	UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(20, y + 114, width - 40, 18)];
	note.text = @"Clear removes cached yt-dlp and temp files";
	note.textColor = MDSubtext();
	note.font = [UIFont systemFontOfSize:11];
	note.textAlignment = NSTextAlignmentCenter;
	[card addSubview:note];

	UIButton *done = MDButton(@"Done", YES);
	done.frame = CGRectMake(20, 500.0 - 60, width - 40, 44);
	[done addTarget:overlay action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:done];

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeTranslation(0, 30);
	[UIView animateWithDuration:0.22 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	}];
}

+ (void)showHelpInWindow:(UIWindow *)window {
	if (!window) {
		return;
	}
	MDOverlayView *overlay = [[MDOverlayView alloc] initWithFrame:window.bounds];
	[overlay buildCardWithHeight:500.0 bottom:YES];
	UIView *card = overlay.card;
	CGFloat width = CGRectGetWidth(card.bounds);

	MDAddGradientIcon(card, 16, 14, 42);
	UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(68, 18, width - 84, 26)];
	title.text = @"Help";
	title.textColor = MDText();
	title.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
	[card addSubview:title];

	UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, width - 40, 370)];
	body.text = @"Import Files\nAdd DRM-free MP3, M4A, FLAC, WAV or video files from Files.\n\nDownload URL\nPaste a direct audio link, a YouTube link, or a Spotify link (resolved to a matching YouTube video).\n\nSearch by Name\nFind a track on YouTube by song or artist name.\n\nBatch Download\nPaste several URLs, one per line, to download them in order.\n\nFix Lyrics\nScan songs already in your library and embed lyrics from LRCLIB, or pick files yourself.\n\nSettings\nChoose audio format, toggle lyrics/artwork, and clear cached data.\n\nKeep Music open until the import finishes. Lyrics and YouTube need FFmpeg installed from a rootless repo.";
	body.textColor = MDText();
	body.font = [UIFont systemFontOfSize:12];
	body.numberOfLines = 0;
	[card addSubview:body];

	UIButton *done = MDButton(@"Got it", YES);
	done.frame = CGRectMake(20, 500.0 - 60, width - 40, 44);
	[done addTarget:overlay action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
	[card addSubview:done];

	[window addSubview:overlay];
	overlay.alpha = 0.0;
	card.transform = CGAffineTransformMakeTranslation(0, 30);
	[UIView animateWithDuration:0.22 animations:^{
		overlay.alpha = 1.0;
		card.transform = CGAffineTransformIdentity;
	}];
}

@end

@interface MDOverlayView (Actions)
- (void)menuRowTapped:(UIButton *)sender;
- (void)cancelTapped:(UIButton *)sender;
- (void)submitTapped:(UIButton *)sender;
- (void)submitMultilineTapped:(UIButton *)sender;
- (void)pasteTapped:(UIButton *)sender;
- (void)pasteMultilineTapped:(UIButton *)sender;
- (void)choiceRowTapped:(UIButton *)sender;
- (void)clearCacheTapped:(UIButton *)sender;
- (void)formatChanged:(UISegmentedControl *)sender;
- (void)toggleChanged:(UISwitch *)sender;
@end

@implementation MDOverlayView (Actions)

- (void)menuRowTapped:(UIButton *)sender {
	void (^selection)(MDMenuAction) = self.menuSelection;
	[self dismissAnimated:YES];
	if (selection) {
		selection((MDMenuAction)sender.tag);
	}
}

- (void)cancelTapped:(__unused UIButton *)sender {
	[self dismissAnimated:YES];
}

- (void)submitTapped:(__unused UIButton *)sender {
	NSString *text = self.inputField.text ?: @"";
	void (^completion)(NSString *) = self.inputCompletion;
	self.inputCompletion = nil;
	[self dismissAnimated:YES];
	if (completion) {
		completion(text);
	}
}

- (void)submitMultilineTapped:(__unused UIButton *)sender {
	NSString *text = self.textView.text ?: @"";
	BOOL placeholderOnly = [text isEqualToString:@"Paste one URL per line…"];
	void (^completion)(NSString *) = self.inputCompletion;
	self.inputCompletion = nil;
	[self dismissAnimated:YES];
	if (completion) {
		completion(placeholderOnly ? @"" : text);
	}
}

- (void)pasteTapped:(__unused UIButton *)sender {
	self.inputField.text = [UIPasteboard generalPasteboard].string ?: @"";
}

- (void)pasteMultilineTapped:(__unused UIButton *)sender {
	self.textView.text = [UIPasteboard generalPasteboard].string ?: @"";
	self.textView.textColor = MDText();
}

- (void)choiceRowTapped:(UIButton *)sender {
	void (^selection)(NSInteger) = self.choiceSelection;
	[self dismissAnimated:YES];
	if (selection) {
		selection(sender.tag);
	}
}

- (void)clearCacheTapped:(UIButton *)sender {
	NSFileManager *manager = [NSFileManager defaultManager];
	[manager removeItemAtPath:@"/var/mobile/Media/MusicDrop/bin/yt-dlp" error:nil];
	for (NSString *directory in @[@"/var/mobile/Media/MusicDrop/tmp",
								  @"/var/mobile/Media/MusicDrop/downloads"]) {
		for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:nil]) {
			[manager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:nil];
		}
	}
	[sender setTitle:@"Cleared" forState:UIControlStateNormal];
}

- (void)formatChanged:(UISegmentedControl *)sender {
	NSArray *formats = @[@"m4a", @"mp3", @"flac"];
	if (sender.selectedSegmentIndex >= 0 && (NSUInteger)sender.selectedSegmentIndex < formats.count) {
		[MDPreferences setDownloadFormat:formats[sender.selectedSegmentIndex]];
	}
}

- (void)toggleChanged:(UISwitch *)sender {
	if (sender.tag == 1) {
		[MDPreferences setEmbedLyrics:sender.isOn];
	} else if (sender.tag == 2) {
		[MDPreferences setEmbedArtwork:sender.isOn];
	} else {
		[MDPreferences setShowProgressDetails:sender.isOn];
	}
}

@end
