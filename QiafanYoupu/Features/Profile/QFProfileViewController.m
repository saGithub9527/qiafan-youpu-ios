#import "QFProfileViewController.h"
#import "QFLoginViewController.h"
@interface QFProfileViewController ()
@property (nonatomic, assign) BOOL signedInPreview;
@end
@implementation QFProfileViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.accessibilityIdentifier = @"profile.screen";
#if DEBUG
    self.signedInPreview = [NSProcessInfo.processInfo.arguments containsObject:@"-QFPreviewSignedIn"];
#endif
    self.contentStack.spacing = 20;
    UIStackView *header = QFStack(UILayoutConstraintAxisHorizontal, 10);
    header.alignment = UIStackViewAlignmentCenter;
    [header addArrangedSubview:QFLabel(@"我的", 30, UIFontWeightSemibold, QFText())];
    UIButton *settings = QFIconButton(@"gearshape", QFText());
    settings.accessibilityLabel = @"设置";
    __weak typeof(self) weakSelf = self;
    QFOnTap(settings, ^{
        QFShowUnavailable(weakSelf, @"设置");
    });
    [header addArrangedSubview:settings];
    [self.contentStack addArrangedSubview:header];
    [self.contentStack addArrangedSubview:QFSpacer(2)];
    UIStackView *identity = QFStack(UILayoutConstraintAxisHorizontal, 14);
    identity.alignment = UIStackViewAlignmentCenter;
    UIView *avatar = QFCard();
    avatar.backgroundColor = QFPaleGreen();
    avatar.layer.cornerRadius = 36;
    [avatar.widthAnchor constraintEqualToConstant:72].active = YES;
    [avatar.heightAnchor constraintEqualToConstant:72].active = YES;
    UIImageView *image = self.signedInPreview
                             ? QFImage(@"default-avatar", UIViewContentModeScaleAspectFill)
                             : [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"person.fill"]];
    image.tintColor = QFHex(0x9AA78C);
    image.contentMode = UIViewContentModeScaleAspectFit;
    QFPin(image, avatar, UIEdgeInsetsMake(12, 12, 12, 12));
    UIStackView *name = QFStack(UILayoutConstraintAxisVertical, 6);
    [name addArrangedSubview:QFLabel(self.signedInPreview ? @"小满的厨房" : @"登录恰饭有谱", 20,
                                     UIFontWeightSemibold, QFText())];
    [name addArrangedSubview:QFLabel(self.signedInPreview ? @"中国 · 上海" : @"收藏菜谱，记录下厨日常", 12,
                                     UIFontWeightRegular, QFSecondary())];
    UIButton *login = QFButton(self.signedInPreview ? @"编辑资料" : @"去登录", 14, UIColor.whiteColor);
    login.backgroundColor = QFOrange();
    login.layer.cornerRadius = 19;
    login.accessibilityIdentifier = @"profile.login";
    [login.widthAnchor constraintEqualToConstant:80].active = YES;
    [login.heightAnchor constraintEqualToConstant:38].active = YES;
    QFOnTap(login, ^{
        if (weakSelf.signedInPreview)
            QFShowUnavailable(weakSelf, @"编辑资料");
        else
            [weakSelf showLogin];
    });
    [identity addArrangedSubview:avatar];
    [identity addArrangedSubview:name];
    [identity addArrangedSubview:login];
    [self.contentStack addArrangedSubview:identity];
    [self.contentStack addArrangedSubview:QFSpacer(0)];
    UIView *stats = QFCard();
    UIStackView *statsRow = QFStack(UILayoutConstraintAxisHorizontal, 0);
    statsRow.distribution = UIStackViewDistributionFillEqually;
    QFPin(statsRow, stats, UIEdgeInsetsMake(14, 0, 14, 0));
    NSArray *values = self.signedInPreview ? @[ @"128", @"26", @"12" ] : @[ @"—", @"—", @"—" ];
    NSArray *titles = @[ @"收藏", @"做菜天数", @"作品" ];
    for (NSUInteger i = 0; i < 3; i++) {
        UIStackView *column = QFStack(UILayoutConstraintAxisVertical, 4);
        column.alignment = UIStackViewAlignmentCenter;
        [column addArrangedSubview:QFLabel(values[i], 22, UIFontWeightSemibold,
                                           self.signedInPreview ? QFText() : QFHex(0x99A08F))];
        [column addArrangedSubview:QFLabel(titles[i], 13, UIFontWeightRegular, QFSecondary())];
        [statsRow addArrangedSubview:column];
    }
    [self.contentStack addArrangedSubview:stats];
    UIStackView *actions = QFStack(UILayoutConstraintAxisHorizontal, 14);
    actions.distribution = UIStackViewDistributionFillEqually;
    [actions addArrangedSubview:[self featureCard:@"发布作品"
                                         subtitle:@"记录今天的拿手菜"
                                           symbol:@"photo"
                                            color:QFOrange()
                                       background:QFHex(0xFFF0E7)]];
    [actions addArrangedSubview:[self featureCard:@"补充图片"
                                         subtitle:@"为食材、菜谱补充实拍"
                                           symbol:@"photo.badge.plus"
                                            color:QFGreen()
                                       background:QFPaleGreen()]];
    [self.contentStack addArrangedSubview:actions];
    [self.contentStack addArrangedSubview:QFLabel(@"我的内容", 20, UIFontWeightSemibold, QFText())];
    UIView *menu = QFCard();
    UIStackView *rows = QFStack(UILayoutConstraintAxisVertical, 0);
    QFPin(rows, menu, UIEdgeInsetsMake(4, 16, 4, 16));
    NSArray *names = @[ @"我的作品", @"我的图片贡献", @"我的收藏", @"做菜记录与统计" ];
    NSArray *icons = @[ @"photo", @"photo.badge.plus", @"bookmark", @"calendar.badge.checkmark" ];
    for (NSUInteger i = 0; i < names.count; i++) {
        [rows addArrangedSubview:[self menuRow:names[i]
                                        symbol:icons[i]
                                      subtitle:self.signedInPreview ? @"" : @"登录后查看"]];
        if (i < names.count - 1) {
            UIView *line = [UIView new];
            line.backgroundColor = QFBorder();
            [line.heightAnchor constraintEqualToConstant:0.5].active = YES;
            [rows addArrangedSubview:line];
        }
    }
    [self.contentStack addArrangedSubview:menu];
    UIView *preferences = QFCard();
    QFPin([self menuRow:@"兴趣偏好"
                 symbol:@"slider.horizontal.3"
               subtitle:self.signedInPreview ? @"" : @"登录后设置"],
          preferences, UIEdgeInsetsMake(4, 16, 4, 16));
    [self.contentStack addArrangedSubview:preferences];
}
- (UIView *)featureCard:(NSString *)title
               subtitle:(NSString *)subtitle
                 symbol:(NSString *)symbol
                  color:(UIColor *)color
             background:(UIColor *)background {
    UIView *card = QFCard();
    card.backgroundColor = background;
    UIStackView *body = QFStack(UILayoutConstraintAxisVertical, 10);
    QFPin(body, card, UIEdgeInsetsMake(16, 16, 16, 16));
    UIStackView *top = QFStack(UILayoutConstraintAxisHorizontal, 8);
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = color;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:23].active = YES;
    [icon.heightAnchor constraintEqualToConstant:23].active = YES;
    [top addArrangedSubview:icon];
    [top addArrangedSubview:[UIView new]];
    [top addArrangedSubview:QFLabel(@"›", 22, UIFontWeightRegular, color)];
    [body addArrangedSubview:top];
    [body addArrangedSubview:QFSpacer(0)];
    [body addArrangedSubview:QFLabel(title, 21, UIFontWeightSemibold, QFText())];
    [body addArrangedSubview:QFLabel(subtitle, 12, UIFontWeightRegular, color)];
    UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
    hit.accessibilityLabel = title;
    QFPin(hit, card, UIEdgeInsetsZero);
    __weak typeof(self) weakSelf = self;
    QFOnTap(hit, ^{
        [weakSelf openProtected:title];
    });
    return card;
}
- (UIView *)menuRow:(NSString *)title symbol:(NSString *)symbol subtitle:(NSString *)subtitle {
    UIView *row = [UIView new];
    [row.heightAnchor constraintEqualToConstant:51].active = YES;
    UIStackView *stack = QFStack(UILayoutConstraintAxisHorizontal, 12);
    stack.alignment = UIStackViewAlignmentCenter;
    QFPin(stack, row, UIEdgeInsetsZero);
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = QFGreen();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:22].active = YES;
    UILabel *name = QFLabel(title, 16, UIFontWeightMedium, QFText());
    UILabel *detail = QFLabel(subtitle, 12, UIFontWeightRegular, QFSecondary());
    [detail setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [stack addArrangedSubview:icon];
    [stack addArrangedSubview:name];
    [stack addArrangedSubview:detail];
    [stack addArrangedSubview:QFLabel(@"›", 20, UIFontWeightRegular, QFSecondary())];
    UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
    hit.accessibilityLabel = title;
    QFPin(hit, row, UIEdgeInsetsZero);
    __weak typeof(self) weakSelf = self;
    QFOnTap(hit, ^{
        [weakSelf openProtected:title];
    });
    return row;
}
- (void)openProtected:(NSString *)title {
    if (self.signedInPreview)
        QFShowUnavailable(self, title);
    else
        [self showLogin];
}
- (void)showLogin {
    QFLoginViewController *login = [QFLoginViewController new];
    login.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:login animated:YES completion:nil];
}
@end
