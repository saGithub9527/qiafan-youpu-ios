#import "QFDesign.h"

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
    [v.heightAnchor constraintEqualToConstant:height].active = YES;
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
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:22], [icon.heightAnchor constraintEqualToConstant:22],
        [icon.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:v.centerYAnchor]
    ]];
    [v.widthAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [v.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
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
    [NSLayoutConstraint activateConstraints:@[
        [child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:insets.top],
        [child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:insets.left],
        [child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-insets.right],
        [child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-insets.bottom]
    ]];
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
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    self.contentStack = QFStack(UILayoutConstraintAxisVertical, 16);
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.contentStack];
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
