#import "QFRootViewController.h"
#import "QFDesign.h"
#import "QFIngredientViewController.h"
#import "QFLaunchPolicy.h"
#import "QFPlanViewController.h"
#import "QFProfileViewController.h"
#import "QFRecipeViewController.h"
#import "QFWelcomeViewController.h"

@interface QFRootViewController ()
@property (nonatomic, strong) UIView *host;
@property (nonatomic, strong) UIView *tabBar;
@property (nonatomic, strong) NSArray<UIViewController *> *tabs;
@property (nonatomic, strong) NSArray<UIButton *> *tabButtons;
@property (nonatomic, strong) UIViewController *activeController;
@end
@implementation QFRootViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFBackground();
#if DEBUG
    if ([NSProcessInfo.processInfo.arguments containsObject:@"-QFResetUIState"]) {
        [NSUserDefaults.standardUserDefaults
            removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    }
#endif
    BOOL debug = NO;
#if DEBUG
    debug = YES;
#endif
    BOOL show = [QFLaunchPolicy
        shouldShowWelcomeForDebug:debug
                        completed:[NSUserDefaults.standardUserDefaults boolForKey:QFOnboardingCompletedKey]];
#if DEBUG
    if ([NSProcessInfo.processInfo.arguments containsObject:@"-QFSkipWelcome"])
        show = NO;
#endif
    if (show)
        [self showWelcome];
    else
        [self showTabs];
}
- (void)attach:(UIViewController *)controller to:(UIView *)host {
    [self addChildViewController:controller];
    QFPin(controller.view, host, UIEdgeInsetsZero);
    [controller didMoveToParentViewController:self];
    self.activeController = controller;
}
- (void)removeActive {
    [self.activeController willMoveToParentViewController:nil];
    [self.activeController.view removeFromSuperview];
    [self.activeController removeFromParentViewController];
    self.activeController = nil;
}
- (void)showWelcome {
    QFWelcomeViewController *welcome = [QFWelcomeViewController new];
    __weak typeof(self) weakSelf = self;
    welcome.onCompleted = ^{
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:QFOnboardingCompletedKey];
        [weakSelf removeActive];
        [weakSelf showTabs];
    };
    [self attach:welcome to:self.view];
}
- (void)showTabs {
    self.host = [UIView new];
    self.host.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.host];
    self.tabBar = [UIView new];
    self.tabBar.backgroundColor = UIColor.whiteColor;
    self.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tabBar];
    [self.host mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.leading.trailing.equalTo(self.view);
        make.bottom.equalTo(self.tabBar.mas_top);
    }];
    [self.tabBar mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.view.mas_safeAreaLayoutGuideBottom).offset(-56);
        make.leading.trailing.bottom.equalTo(self.view);
    }];
    UIView *line = [UIView new];
    line.backgroundColor = QFBorder();
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tabBar addSubview:line];
    [line mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(0.5);
        make.top.leading.trailing.equalTo(self.tabBar);
    }];
    self.tabs = @[
        [QFRecipeViewController new], [QFPlanViewController new], [QFIngredientViewController new],
        [QFProfileViewController new]
    ];
    NSArray *titles = @[ @"菜谱", @"计划", @"食材", @"我的" ];
    NSArray *symbols = @[ @"book.closed", @"calendar.badge.checkmark", @"basket", @"person" ];
    NSArray *identifiers = @[ @"tab.recipe", @"tab.plan", @"tab.ingredient", @"tab.profile" ];
    UIStackView *stack = QFStack(UILayoutConstraintAxisHorizontal, 0);
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tabBar addSubview:stack];
    [stack mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(self.tabBar.mas_top).offset(3);
        make.leading.trailing.equalTo(self.tabBar);
        make.height.mas_equalTo(52);
    }];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
        config.title = titles[i];
        config.image = [UIImage systemImageNamed:symbols[i]
                               withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22]];
        config.imagePlacement = NSDirectionalRectEdgeTop;
        config.imagePadding = 3;
        config.contentInsets = NSDirectionalEdgeInsetsMake(3, 0, 2, 0);
        config.attributedTitle = [[NSAttributedString alloc]
            initWithString:titles[i]
                attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]}];
        button.configuration = config;
        button.accessibilityIdentifier = identifiers[i];
        button.accessibilityLabel = titles[i];
        [stack addArrangedSubview:button];
        [buttons addObject:button];
        __weak typeof(self) weakSelf = self;
        QFOnTap(button, ^{
            [weakSelf selectTab:i];
        });
    }
    self.tabButtons = buttons;
    NSUInteger selected = 0;
#if DEBUG
    NSString *start = [NSUserDefaults.standardUserDefaults stringForKey:@"QFStartTab"];
    NSUInteger index = [@[ @"recipe", @"plan", @"ingredient", @"profile" ] indexOfObject:start ?: @""];
    if (index != NSNotFound)
        selected = index;
#endif
    [self selectTab:selected];
}
- (void)selectTab:(NSUInteger)index {
    [self removeActive];
    [self attach:self.tabs[index] to:self.host];
    [self.tabButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger i, BOOL *stop) {
        UIColor *color = i == index ? QFOrange() : QFSecondary();
        UIButtonConfiguration *configuration = button.configuration;
        configuration.baseForegroundColor = color;
        button.configuration = configuration;
        button.tintColor = color;
        button.accessibilityTraits =
            UIAccessibilityTraitButton | (i == index ? UIAccessibilityTraitSelected : 0);
    }];
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleDarkContent;
}
@end
