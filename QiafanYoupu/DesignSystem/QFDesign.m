#import "QFDesign.h"
#import <Masonry/Masonry.h>

UIColor *QFHex(unsigned int v) {
    return [UIColor colorWithRed:((v >> 16) & 255) / 255.0
                           green:((v >> 8) & 255) / 255.0
                            blue:(v & 255) / 255.0
                           alpha:1];
}
UIColor *QFBackground(void) {
    return QFHex(0xF8F8F3);
}
UIColor *QFText(void) {
    return QFHex(0x202A25);
}
UIColor *QFSecondary(void) {
    return QFHex(0x788176);
}
UIColor *QFOrange(void) {
    return QFHex(0xF46236);
}
UIColor *QFGreen(void) {
    return QFHex(0x5D754E);
}
UIColor *QFPaleGreen(void) {
    return QFHex(0xEDF2E5);
}
UIColor *QFBorder(void) {
    return QFHex(0xE3E7DC);
}
UILabel *QFLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *v = [UILabel new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.text = text;
    v.textColor = color;
    v.font = [UIFont systemFontOfSize:size weight:weight];
    v.numberOfLines = 0;
    return v;
}
UIStackView *QFStack(UILayoutConstraintAxis axis, CGFloat spacing) {
    UIStackView *v = [UIStackView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.axis = axis;
    v.spacing = spacing;
    return v;
}
UIView *QFCard(void) {
    UIView *v = [UIView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = UIColor.whiteColor;
    v.layer.cornerRadius = 22;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    return v;
}
UIView *QFSpacer(CGFloat height) {
    UIView *v = [UIView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(height);
    }];
    return v;
}
UIButton *QFButton(NSString *title, CGFloat size, UIColor *color) {
    UIButton *v = [UIButton buttonWithType:UIButtonTypeSystem];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v setTitle:title forState:UIControlStateNormal];
    [v setTitleColor:color forState:UIControlStateNormal];
    v.titleLabel.font = [UIFont systemFontOfSize:size weight:UIFontWeightMedium];
    v.accessibilityLabel = title;
    return v;
}
UIButton *QFIconButton(NSString *symbol, UIColor *color) {
    UIButton *v = [UIButton buttonWithType:UIButtonTypeSystem];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.tintColor = color;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.accessibilityElementsHidden = YES;
    [v addSubview:icon];
    [icon mas_makeConstraints:^(MASConstraintMaker *make) {
        make.size.mas_equalTo(CGSizeMake(22, 22));
        make.center.equalTo(v);
    }];
    [v mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.height.mas_greaterThanOrEqualTo(40);
    }];
    return v;
}
void QFOnTap(UIButton *button, void (^handler)(void)) {
    [button addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                if (handler)
                    handler();
            }]
        forControlEvents:UIControlEventTouchUpInside];
}
void QFPin(UIView *child, UIView *parent, UIEdgeInsets insets) {
    [parent addSubview:child];
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [child mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(parent.mas_top).offset(insets.top);
        make.leading.equalTo(parent.mas_leading).offset(insets.left);
        make.trailing.equalTo(parent.mas_trailing).offset(-insets.right);
        make.bottom.equalTo(parent.mas_bottom).offset(-insets.bottom);
    }];
}
UIImageView *QFImage(NSString *asset, UIViewContentMode mode) {
    UIImageView *v = [[UIImageView alloc] initWithImage:[UIImage imageNamed:asset]];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.contentMode = mode;
    v.clipsToBounds = YES;
    return v;
}
void QFShowUnavailable(UIViewController *controller, NSString *title) {
    if (controller.presentedViewController)
        return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"该功能暂未开放"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
@interface QFBaseViewController ()
@property (nonatomic, strong, readwrite) UIScrollView *scrollView;
@property (nonatomic, strong, readwrite) UIStackView *contentStack;
@end
@implementation QFBaseViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFBackground();
    self.scrollView = [UIScrollView new];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];
    [self.scrollView mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.view.mas_safeAreaLayoutGuideTop);
        make.leading.trailing.bottom.equalTo(self.view);
    }];
    self.contentStack = QFStack(UILayoutConstraintAxisVertical, 16);
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentStack];
    // Masonry 1.1.0 does not accept scroll layout guides directly; retain their sizing semantics.
    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor
                                                    constant:14],
        [self.contentStack.leadingAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor
                           constant:20],
        [self.contentStack.trailingAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor
                           constant:-20],
        [self.contentStack.bottomAnchor
            constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor
                           constant:-24],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor
                                                      constant:-40]
    ]];
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDarkContent;
}
@end
