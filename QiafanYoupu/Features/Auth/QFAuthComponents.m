#import "QFAuthComponents.h"
#import "../../DesignSystem/QFDesign.h"

static NSString *const QFLoginConsentKey = @"qfyp.login.consent";
// Replace this revision when real documents are supplied; old UI selections must be cleared.
static NSString *const QFConsentUIRevision = @"ui-placeholder-v1";

@implementation QFLoginConsentStore
+ (BOOL)isAgreementChecked {
    id record = [NSUserDefaults.standardUserDefaults objectForKey:QFLoginConsentKey];
    if (![record isKindOfClass:NSDictionary.class])
        return NO;
    id schema = record[@"schemaVersion"];
    id value = record[@"loginAgreementChecked"];
    id timestamp = record[@"updatedAt"];
    BOOL validTimestamp = [timestamp isKindOfClass:NSString.class] &&
                          [[[NSISO8601DateFormatter alloc] init] dateFromString:timestamp] != nil;
    BOOL valid = [schema isKindOfClass:NSNumber.class] && [schema integerValue] == 1 &&
                 [value isKindOfClass:NSNumber.class] &&
                 CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && validTimestamp &&
                 [record[@"uiDocumentRevision"] isEqual:QFConsentUIRevision];
    if (!valid) {
        [self setAgreementChecked:NO];
        return NO;
    }
    return [value boolValue];
}
+ (void)setAgreementChecked:(BOOL)checked {
    NSString *timestamp = [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date];
    // NSUserDefaults cannot store NSNull. Unavailable formal document versions are omitted.
    NSDictionary *record = @{
        @"schemaVersion" : @1,
        @"loginAgreementChecked" : @(checked),
        @"updatedAt" : timestamp,
        @"uiDocumentRevision" : QFConsentUIRevision,
        @"uiOnly" : @YES
    };
    [NSUserDefaults.standardUserDefaults setObject:record forKey:QFLoginConsentKey];
}
@end

@interface QFAgreementDocumentViewController : UIViewController
@property (nonatomic, copy) NSString *documentTitle;
@end

@implementation QFAgreementDocumentViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFBackground();
    self.title = self.documentTitle;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(closeDocument)];
    self.navigationItem.leftBarButtonItem.accessibilityIdentifier = @"agreement.back";
    UITextView *body = [[UITextView alloc] init];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    body.backgroundColor = UIColor.clearColor;
    body.editable = NO;
    body.selectable = YES;
    body.font = [UIFont systemFontOfSize:17];
    body.textColor = QFText();
    body.textContainerInset = UIEdgeInsetsMake(28, 22, 28, 22);
    body.text = [NSString
        stringWithFormat:
            @"%@\n\n当前版本为界面展示阶段\n\n完整正式《%@"
            @"》尚未提供。此页仅用于展示协议入口、阅读及返回流程，不构成正式协议文本。\n\n当前勾选仅记录本机"
            @"界面选择，不代表服务端协议签署或身份认证。\n\n点击“返回”可回到原页面，阅读不会改变勾选状态。",
            self.documentTitle, self.documentTitle];
    body.accessibilityIdentifier = @"agreement.document";
    [self.view addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}
- (void)closeDocument {
    [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
@end

void QFPresentAgreementDocument(UIViewController *presenter, NSString *title) {
    QFAgreementDocumentViewController *document = [QFAgreementDocumentViewController new];
    document.documentTitle = title;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:document];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.navigationBar.tintColor = QFGreen();
    [presenter presentViewController:navigation
                            animated:!UIAccessibilityIsReduceMotionEnabled()
                          completion:nil];
}

@interface QFAgreementView () <UITextViewDelegate>
@property (nonatomic, strong) UIButton *checkButton;
@end

@implementation QFAgreementView
- (instancetype)initWithNoticeStyle:(BOOL)noticeStyle identifier:(NSString *)identifier {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _checkButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _checkButton.translatesAutoresizingMaskIntoConstraints = NO;
        _checkButton.accessibilityIdentifier = identifier;
        _checkButton.accessibilityLabel = @"我已阅读并同意隐私政策和用户协议";
        [_checkButton addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_checkButton];
        UITextView *text = [[UITextView alloc] init];
        text.translatesAutoresizingMaskIntoConstraints = NO;
        text.backgroundColor = UIColor.clearColor;
        text.editable = NO;
        text.scrollEnabled = NO;
        text.delegate = self;
        text.textContainerInset = UIEdgeInsetsMake(11, 0, 0, 0);
        text.textContainer.lineFragmentPadding = 0;
        NSString *copy = noticeStyle ? @"我已阅读并同意 《用户协议》\n和《隐私政策》"
                                     : @"我已阅读并同意《隐私政策》和《用户协议》";
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.lineSpacing = 4;
        NSMutableAttributedString *attributed =
            [[NSMutableAttributedString alloc] initWithString:copy
                                                   attributes:@{
                                                       NSFontAttributeName : [UIFont systemFontOfSize:13],
                                                       NSForegroundColorAttributeName : QFSecondary(),
                                                       NSParagraphStyleAttributeName : paragraph
                                                   }];
        [attributed addAttribute:NSLinkAttributeName
                           value:@"qfyp-document://privacy"
                           range:[copy rangeOfString:@"《隐私政策》"]];
        [attributed addAttribute:NSLinkAttributeName
                           value:@"qfyp-document://terms"
                           range:[copy rangeOfString:@"《用户协议》"]];
        text.attributedText = attributed;
        text.linkTextAttributes =
            @{NSForegroundColorAttributeName : noticeStyle ? QFHex(0xA83212) : QFGreen()};
        [self addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [_checkButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:-5],
            [_checkButton.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_checkButton.widthAnchor constraintEqualToConstant:36],
            [_checkButton.heightAnchor constraintEqualToConstant:44],
            [text.leadingAnchor constraintEqualToAnchor:_checkButton.trailingAnchor constant:3],
            [text.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [text.topAnchor constraintEqualToAnchor:self.topAnchor],
            [text.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:55]
        ]];
        self.checked = NO;
    }
    return self;
}
- (void)setChecked:(BOOL)checked {
    _checked = checked;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIFontWeightRegular];
    [self.checkButton setImage:[[UIImage systemImageNamed:checked ? @"checkmark.square.fill" : @"square"]
                                   imageByApplyingSymbolConfiguration:configuration]
                      forState:UIControlStateNormal];
    self.checkButton.tintColor = checked ? QFGreen() : QFHex(0x93A18B);
    self.checkButton.accessibilityValue = checked ? @"已勾选" : @"未勾选";
    self.checkButton.accessibilityTraits =
        UIAccessibilityTraitButton | (checked ? UIAccessibilityTraitSelected : UIAccessibilityTraitNone);
}
- (void)toggle {
    self.checked = !self.checked;
    if (self.onChanged)
        self.onChanged(self.checked);
}
- (BOOL)textView:(UITextView *)textView
    shouldInteractWithURL:(NSURL *)URL
                  inRange:(NSRange)characterRange
              interaction:(UITextItemInteraction)interaction {
    if (self.onReadDocument)
        self.onReadDocument([URL.host isEqualToString:@"privacy"] ? @"隐私政策" : @"用户协议");
    return NO;
}
@end

@interface QFSafetyNoticeViewController ()
@property (nonatomic, strong) QFAgreementView *agreementView;
@property (nonatomic, strong) UIButton *continueButton;
@property (nonatomic) BOOL resolved;
@end

@implementation QFSafetyNoticeViewController
- (instancetype)init {
    if ((self = [super init])) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.modalInPresentation = YES;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [QFHex(0x24372C) colorWithAlphaComponent:0.39];
    self.view.accessibilityViewIsModal = YES;
    UIView *sheet = [UIView new];
    sheet.translatesAutoresizingMaskIntoConstraints = NO;
    sheet.backgroundColor = QFBackground();
    sheet.layer.cornerRadius = 28;
    sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [self.view addSubview:sheet];
    NSLayoutConstraint *preferredHeight = [sheet.heightAnchor constraintEqualToConstant:650];
    preferredHeight.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [sheet.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [sheet.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [sheet.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [sheet.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                                     constant:12],
        preferredHeight
    ]];
    UIView *handle = [UIView new];
    handle.translatesAutoresizingMaskIntoConstraints = NO;
    handle.backgroundColor = QFHex(0xD5DACF);
    handle.layer.cornerRadius = 2;
    [sheet addSubview:handle];
    [NSLayoutConstraint activateConstraints:@[
        [handle.topAnchor constraintEqualToAnchor:sheet.topAnchor constant:13],
        [handle.centerXAnchor constraintEqualToAnchor:sheet.centerXAnchor],
        [handle.widthAnchor constraintEqualToConstant:42], [handle.heightAnchor constraintEqualToConstant:4]
    ]];
    UIButton *decline = QFButton(@"暂不同意", 15, QFSecondary());
    decline.accessibilityIdentifier = @"notice.decline";
    [decline addTarget:self action:@selector(declineTapped) forControlEvents:UIControlEventTouchUpInside];
    [sheet addSubview:decline];
    _continueButton = QFButton(@"同意并继续", 17, QFGreen());
    _continueButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _continueButton.layer.cornerRadius = 17;
    _continueButton.accessibilityIdentifier = @"notice.continue";
    [_continueButton addTarget:self
                        action:@selector(continueTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [sheet addSubview:_continueButton];
    _agreementView = [[QFAgreementView alloc] initWithNoticeStyle:YES identifier:@"notice.agreement"];
    _agreementView.checked = self.agreementChecked;
    __weak typeof(self) weakSelf = self;
    _agreementView.onChanged = ^(BOOL checked) {
        weakSelf.agreementChecked = checked;
        if (weakSelf.onSelectionChanged)
            weakSelf.onSelectionChanged(checked);
    };
    _agreementView.onReadDocument = ^(NSString *title) {
        QFPresentAgreementDocument(weakSelf, title);
    };
    [sheet addSubview:_agreementView];
    UIView *separator = [UIView new];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = QFBorder();
    [sheet addSubview:separator];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = YES;
    [sheet addSubview:scroll];
    UIStackView *body = QFStack(UILayoutConstraintAxisVertical, 15);
    [scroll addSubview:body];
    UIStackView *heading = QFStack(UILayoutConstraintAxisHorizontal, 13);
    heading.alignment = UIStackViewAlignmentCenter;
    UIImageView *icon = QFImage(@"chef-icon", UIViewContentModeScaleAspectFit);
    icon.layer.cornerRadius = 12;
    icon.clipsToBounds = YES;
    [icon.widthAnchor constraintEqualToConstant:40].active = YES;
    [icon.heightAnchor constraintEqualToConstant:40].active = YES;
    [heading addArrangedSubview:icon];
    [heading addArrangedSubview:QFLabel(@"安全与使用须知", 22, UIFontWeightBold, QFText())];
    [body addArrangedSubview:heading];
    [body
        addArrangedSubview:QFLabel(@"开始之前，请先了解这些说明。", 14, UIFontWeightRegular, QFSecondary())];
    NSArray<NSArray<NSString *> *> *items = @[
        @[ @"食材与饮食安全", @"请留意过敏原和个人饮食需求，\n并确认食材新鲜、适合食用。" ],
        @[ @"烹饪与设备安全", @"使用刀具、热油及电器时请注意安全，\n未成年人应在成人指导下操作。" ],
        @[ @"内容仅供烹饪参考", @"份量、时间与做法请结合实际调整，\n菜谱内容不能替代专业健康建议。" ],
        @[ @"使用范围与限制", @"请勿恶意抓取、干扰服务或滥用内容，\n具体使用规则以用户协议为准。" ]
    ];
    [items enumerateObjectsUsingBlock:^(NSArray<NSString *> *item, NSUInteger index, BOOL *stop) {
        UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 10);
        row.alignment = UIStackViewAlignmentTop;
        UILabel *number = QFLabel([NSString stringWithFormat:@"%lu", (unsigned long)index + 1], 11,
                                  UIFontWeightMedium, QFHex(0xAC391C));
        number.backgroundColor = QFHex(0xFFF0E5);
        number.textAlignment = NSTextAlignmentCenter;
        number.layer.cornerRadius = 9;
        number.clipsToBounds = YES;
        [number.widthAnchor constraintEqualToConstant:18].active = YES;
        [number.heightAnchor constraintEqualToConstant:18].active = YES;
        UIStackView *copy = QFStack(UILayoutConstraintAxisVertical, 5);
        [copy addArrangedSubview:QFLabel(item[0], 15, UIFontWeightSemibold, QFText())];
        UILabel *detail = QFLabel(item[1], 13, UIFontWeightRegular, QFSecondary());
        detail.numberOfLines = 0;
        [copy addArrangedSubview:detail];
        [row addArrangedSubview:number];
        [row addArrangedSubview:copy];
        [body addArrangedSubview:row];
    }];
    [NSLayoutConstraint activateConstraints:@[
        [decline.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                             constant:-11],
        [decline.centerXAnchor constraintEqualToAnchor:sheet.centerXAnchor],
        [decline.heightAnchor constraintEqualToConstant:44],
        [decline.widthAnchor constraintEqualToConstant:150],
        [_continueButton.bottomAnchor constraintEqualToAnchor:decline.topAnchor constant:-12],
        [_continueButton.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:24],
        [_continueButton.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-24],
        [_continueButton.heightAnchor constraintEqualToConstant:53],
        [_agreementView.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:25],
        [_agreementView.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-24],
        [_agreementView.bottomAnchor constraintEqualToAnchor:_continueButton.topAnchor constant:-15],
        [separator.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:24],
        [separator.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-24],
        [separator.bottomAnchor constraintEqualToAnchor:_agreementView.topAnchor constant:-7],
        [separator.heightAnchor constraintEqualToConstant:1],
        [scroll.topAnchor constraintEqualToAnchor:handle.bottomAnchor constant:22],
        [scroll.leadingAnchor constraintEqualToAnchor:sheet.leadingAnchor constant:24],
        [scroll.trailingAnchor constraintEqualToAnchor:sheet.trailingAnchor constant:-24],
        [scroll.bottomAnchor constraintEqualToAnchor:separator.topAnchor constant:-17],
        [body.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [body.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [body.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-2],
        [body.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    [self updateContinueButton];
}
- (void)setAgreementChecked:(BOOL)agreementChecked {
    _agreementChecked = agreementChecked;
    self.agreementView.checked = agreementChecked;
    [self updateContinueButton];
}
- (void)updateContinueButton {
    self.continueButton.enabled = self.agreementChecked && !self.resolved;
    self.continueButton.backgroundColor = self.agreementChecked ? QFOrange() : QFHex(0xE7EBDD);
    [self.continueButton setTitleColor:self.agreementChecked ? UIColor.whiteColor : QFHex(0x6F795F)
                              forState:UIControlStateNormal];
    [self.continueButton setTitleColor:QFHex(0x6F795F) forState:UIControlStateDisabled];
}
- (void)continueTapped {
    if (!self.agreementChecked || self.resolved)
        return;
    self.resolved = YES;
    [self updateContinueButton];
    if (self.onContinue)
        self.onContinue();
}
- (void)declineTapped {
    if (self.resolved)
        return;
    self.resolved = YES;
    self.agreementChecked = NO;
    if (self.onSelectionChanged)
        self.onSelectionChanged(NO);
    if (self.onDecline)
        self.onDecline();
}
@end
