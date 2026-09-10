#import "QFLoginViewController.h"
#import "../../DesignSystem/QFDesign.h"
#import "QFAuthComponents.h"

@interface QFLoginViewController ()
@property (nonatomic, strong) QFAgreementView *agreementView;
@property (nonatomic, copy, nullable) NSString *pendingMethod;
@property (nonatomic, strong) UIView *heroCircle;
@end

@implementation QFLoginViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFHex(0xF8F8F2);
    UIButton *close = QFIconButton(@"xmark", QFHex(0x5E6C69));
    close.backgroundColor = UIColor.whiteColor;
    close.layer.cornerRadius = 20;
    close.accessibilityIdentifier = @"login.close";
    close.accessibilityLabel = @"关闭登录";
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = QFStack(UILayoutConstraintAxisVertical, 0);
    [scroll addSubview:stack];
    UIView *hero = [UIView new];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    _heroCircle = [UIView new];
    _heroCircle.translatesAutoresizingMaskIntoConstraints = NO;
    _heroCircle.backgroundColor = QFHex(0xFFF0E7);
    [hero addSubview:_heroCircle];
    UIImageView *chef = QFImage(@"chef-logo", UIViewContentModeScaleAspectFit);
    [_heroCircle addSubview:chef];
    [NSLayoutConstraint activateConstraints:@[
        [_heroCircle.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
        [_heroCircle.topAnchor constraintEqualToAnchor:hero.topAnchor],
        [_heroCircle.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [_heroCircle.widthAnchor constraintEqualToAnchor:hero.widthAnchor multiplier:0.69],
        [_heroCircle.heightAnchor constraintEqualToAnchor:_heroCircle.widthAnchor],
        [chef.leadingAnchor constraintEqualToAnchor:_heroCircle.leadingAnchor constant:17],
        [chef.trailingAnchor constraintEqualToAnchor:_heroCircle.trailingAnchor constant:-17],
        [chef.topAnchor constraintEqualToAnchor:_heroCircle.topAnchor constant:10],
        [chef.bottomAnchor constraintEqualToAnchor:_heroCircle.bottomAnchor constant:-18]
    ]];
    [stack addArrangedSubview:hero];
    [stack addArrangedSubview:QFSpacer(19)];
    UILabel *brand = QFLabel(@"恰饭有谱", 32, UIFontWeightBold, QFText());
    brand.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:brand];
    [stack addArrangedSubview:QFSpacer(12)];
    UILabel *tagline = QFLabel(@"收藏世界风味，记录每一餐", 15, UIFontWeightRegular, QFSecondary());
    tagline.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:tagline];
    [stack addArrangedSubview:QFSpacer(70)];
    UIButton *quick = QFButton(@"快速登录", 20, UIColor.whiteColor);
    quick.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    quick.backgroundColor = QFOrange();
    quick.layer.cornerRadius = 16;
    quick.accessibilityIdentifier = @"login.quick";
    [quick.heightAnchor constraintEqualToConstant:55].active = YES;
    [quick addTarget:self action:@selector(quickTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:quick];
    [stack addArrangedSubview:QFSpacer(16)];
    UIButton *apple = QFButton(@"通过 Apple 登录", 22, UIColor.whiteColor);
    apple.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    apple.backgroundColor = UIColor.blackColor;
    apple.layer.cornerRadius = 8;
    UIImageSymbolConfiguration *appleSymbol =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIFontWeightMedium];
    UIButtonConfiguration *appleConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    appleConfiguration.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"通过 Apple 登录"
            attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:22 weight:UIFontWeightMedium]}];
    appleConfiguration.image =
        [[UIImage systemImageNamed:@"apple.logo"] imageByApplyingSymbolConfiguration:appleSymbol];
    appleConfiguration.imagePadding = 9;
    appleConfiguration.baseForegroundColor = UIColor.whiteColor;
    apple.configuration = appleConfiguration;
    apple.accessibilityIdentifier = @"login.apple";
    [apple.heightAnchor constraintEqualToConstant:55].active = YES;
    [apple addTarget:self action:@selector(appleTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:apple];
    UIView *bottomSpace = [UIView new];
    bottomSpace.translatesAutoresizingMaskIntoConstraints = NO;
    [bottomSpace.heightAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    NSLayoutConstraint *preferredSpace = [bottomSpace.heightAnchor constraintEqualToConstant:88];
    preferredSpace.priority = UILayoutPriorityDefaultLow;
    preferredSpace.active = YES;
    [stack addArrangedSubview:bottomSpace];
    _agreementView = [[QFAgreementView alloc] initWithNoticeStyle:NO identifier:@"login.agreement"];
    _agreementView.checked = [QFLoginConsentStore isAgreementChecked];
    __weak typeof(self) weakSelf = self;
    _agreementView.onChanged = ^(BOOL checked) {
        [QFLoginConsentStore setAgreementChecked:checked];
    };
    _agreementView.onReadDocument = ^(NSString *title) {
        QFPresentAgreementDocument(weakSelf, title);
    };
    [stack addArrangedSubview:_agreementView];
    [NSLayoutConstraint activateConstraints:@[
        [close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [close.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [close.widthAnchor constraintEqualToConstant:40], [close.heightAnchor constraintEqualToConstant:40],
        [scroll.topAnchor constraintEqualToAnchor:close.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:23],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:30],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-30],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-60]
    ]];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.heroCircle.layer.cornerRadius = CGRectGetWidth(self.heroCircle.bounds) / 2.0;
}
- (void)closeTapped {
    self.pendingMethod = nil;
    if (self.onClose)
        self.onClose();
    else
        [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
- (void)quickTapped {
    [self requestLoginMethod:@"quick"];
}
- (void)appleTapped {
    [self requestLoginMethod:@"apple"];
}
- (void)requestLoginMethod:(NSString *)method {
    if (self.presentedViewController)
        return;
    if (self.agreementView.checked) {
        [self showLoginUnavailable];
        return;
    }
    self.pendingMethod = method;
    QFSafetyNoticeViewController *notice = [QFSafetyNoticeViewController new];
    notice.agreementChecked = NO;
    __weak typeof(self) weakSelf = self;
    notice.onSelectionChanged = ^(BOOL checked) {
        weakSelf.agreementView.checked = checked;
        [QFLoginConsentStore setAgreementChecked:checked];
    };
    notice.onContinue = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self)
            return;
        BOOL hasPendingMethod = self.pendingMethod.length > 0;
        self.pendingMethod = nil; // Consume at most once and never persist an action.
        [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()
                                 completion:^{
                                     if (hasPendingMethod)
                                         [self showLoginUnavailable];
                                 }];
    };
    notice.onDecline = ^{
        weakSelf.pendingMethod = nil;
        [weakSelf dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
    };
    [self presentViewController:notice animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
- (void)showLoginUnavailable {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"登录暂未开放"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
