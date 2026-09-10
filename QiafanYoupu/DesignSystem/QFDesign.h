#import <Masonry/Masonry.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
UIColor *QFHex(unsigned int value);
UIColor *QFBackground(void);
UIColor *QFText(void);
UIColor *QFSecondary(void);
UIColor *QFOrange(void);
UIColor *QFGreen(void);
UIColor *QFPaleGreen(void);
UIColor *QFBorder(void);
UILabel *QFLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color);
UIStackView *QFStack(UILayoutConstraintAxis axis, CGFloat spacing);
UIView *QFCard(void);
UIView *QFSpacer(CGFloat height);
UIButton *QFButton(NSString *title, CGFloat size, UIColor *color);
UIButton *QFIconButton(NSString *symbol, UIColor *color);
void QFOnTap(UIButton *button, void (^handler)(void));
void QFPin(UIView *child, UIView *parent, UIEdgeInsets insets);
MASViewAttribute *QFLayoutGuideAttribute(UILayoutGuide *guide, NSLayoutAttribute attribute);
UIImageView *QFImage(NSString *asset, UIViewContentMode mode);
void QFShowUnavailable(UIViewController *controller, NSString *title);

@interface QFBaseViewController : UIViewController
@property (nonatomic, strong, readonly) UIScrollView *scrollView;
@property (nonatomic, strong, readonly) UIStackView *contentStack;
@end
NS_ASSUME_NONNULL_END
