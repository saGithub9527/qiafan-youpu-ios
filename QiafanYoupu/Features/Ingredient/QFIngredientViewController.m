#import "QFIngredientViewController.h"

@interface QFIngredientViewController () <UITextFieldDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *inventory;
@property (nonatomic, copy) NSArray<NSDictionary *> *shopping;
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, strong) NSMutableArray<UIButton *> *categoryButtons;
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UITextField *searchField;
@property (nonatomic, strong) UIView *nearDateNotice;
@property (nonatomic, strong) UILabel *listTitle;
@property (nonatomic, strong) UIButton *sortButton;
@property (nonatomic, strong) UIStackView *ingredientList;
@property (nonatomic) NSInteger selectedCategory;
@property (nonatomic) BOOL nearDateFirst;
@end

@implementation QFIngredientViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"食材";
    self.contentStack.spacing = 16;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.nearDateFirst = YES;
    self.categories = @[ @"全部", @"蔬菜", @"肉蛋", @"奶制品", @"水果", @"谷物", @"水产", @"菌藻", @"调味" ];
    self.categoryButtons = [NSMutableArray array];
    self.inventory = @[
        @{
            @"id" : @"broccoli",
            @"name" : @"西兰花",
            @"emoji" : @"🥦",
            @"category" : @"蔬菜",
            @"amount" : @"1 棵 · 约 300 克",
            @"storage" : @"冷藏",
            @"date" : @"9月10日到期",
            @"near" : @YES
        },
        @{
            @"id" : @"milk",
            @"name" : @"鲜牛奶",
            @"emoji" : @"🥛",
            @"category" : @"奶制品",
            @"amount" : @"1 盒 · 1 升",
            @"storage" : @"冷藏",
            @"date" : @"9月11日到期",
            @"near" : @YES
        },
        @{
            @"id" : @"egg",
            @"name" : @"鸡蛋",
            @"emoji" : @"🥚",
            @"category" : @"肉蛋",
            @"amount" : @"6 个",
            @"storage" : @"冷藏",
            @"date" : @"9月18日到期",
            @"near" : @NO
        },
        @{
            @"id" : @"tomato",
            @"name" : @"番茄",
            @"emoji" : @"🍅",
            @"category" : @"蔬菜",
            @"amount" : @"500 克",
            @"storage" : @"冷藏",
            @"date" : @"9月15日到期",
            @"near" : @NO
        },
        @{
            @"id" : @"chicken",
            @"name" : @"鸡胸肉",
            @"emoji" : @"🥩",
            @"category" : @"肉蛋",
            @"amount" : @"400 克",
            @"storage" : @"冷冻",
            @"date" : @"10月9日到期",
            @"near" : @NO
        },
        @{
            @"id" : @"beef",
            @"name" : @"牛腩",
            @"emoji" : @"🥩",
            @"category" : @"肉蛋",
            @"amount" : @"500 克",
            @"storage" : @"冷冻",
            @"date" : @"10月9日到期",
            @"near" : @NO
        },
        @{
            @"id" : @"rice",
            @"name" : @"大米",
            @"emoji" : @"🍚",
            @"category" : @"谷物",
            @"amount" : @"2,000 克",
            @"storage" : @"常温",
            @"date" : @"",
            @"near" : @NO
        },
        @{
            @"id" : @"flour",
            @"name" : @"面粉",
            @"emoji" : @"🌾",
            @"category" : @"谷物",
            @"amount" : @"500 克",
            @"storage" : @"常温",
            @"date" : @"",
            @"near" : @NO
        },
        @{
            @"id" : @"oil",
            @"name" : @"食用油",
            @"emoji" : @"🫒",
            @"category" : @"调味",
            @"amount" : @"500 毫升",
            @"storage" : @"常温",
            @"date" : @"",
            @"near" : @NO
        },
        @{
            @"id" : @"seaweed",
            @"name" : @"紫菜",
            @"emoji" : @"🥬",
            @"category" : @"菌藻",
            @"amount" : @"20 克",
            @"storage" : @"常温",
            @"date" : @"",
            @"near" : @NO
        },
        @{
            @"id" : @"carrot",
            @"name" : @"胡萝卜",
            @"emoji" : @"🥕",
            @"category" : @"蔬菜",
            @"amount" : @"300 克",
            @"storage" : @"冷藏",
            @"date" : @"9月20日到期",
            @"near" : @NO
        },
        @{
            @"id" : @"apple",
            @"name" : @"苹果",
            @"emoji" : @"🍎",
            @"category" : @"水果",
            @"amount" : @"2 个",
            @"storage" : @"冷藏",
            @"date" : @"9月20日到期",
            @"near" : @NO
        }
    ];
    self.shopping = @[
        @{
            @"id" : @"tomato",
            @"name" : @"番茄",
            @"emoji" : @"🍅",
            @"category" : @"蔬菜",
            @"amount" : @"500 克",
            @"price" : @"预计 ¥6.00"
        },
        @{
            @"id" : @"egg",
            @"name" : @"鸡蛋",
            @"emoji" : @"🥚",
            @"category" : @"肉蛋",
            @"amount" : @"6 个",
            @"price" : @"预计 ¥7.20"
        },
        @{
            @"id" : @"salt",
            @"name" : @"盐",
            @"emoji" : @"🧂",
            @"category" : @"调味",
            @"amount" : @"1 袋 · 500 克",
            @"price" : @"预计 ¥3.00"
        }
    ];
    [self.contentStack addArrangedSubview:[self makeHeader]];
    [self.contentStack addArrangedSubview:[self makeSearchField]];
    [self.contentStack addArrangedSubview:[self makeDiscoveryEntries]];
    self.segment = [[UISegmentedControl alloc] initWithItems:@[ @"家里已有 · 12", @"待采购 · 3" ]];
    self.segment.translatesAutoresizingMaskIntoConstraints = NO;
    self.segment.selectedSegmentIndex = 0;
    self.segment.backgroundColor = QFHex(0xE9EDE2);
    self.segment.selectedSegmentTintColor = UIColor.whiteColor;
    self.segment.accessibilityIdentifier = @"ingredient.segment";
    [self.segment setTitleTextAttributes:@{
        NSFontAttributeName : [UIFont systemFontOfSize:14 weight:UIFontWeightMedium],
        NSForegroundColorAttributeName : QFSecondary()
    }
                                forState:UIControlStateNormal];
    [self.segment setTitleTextAttributes:@{
        NSFontAttributeName : [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName : QFText()
    }
                                forState:UIControlStateSelected];
    [self.segment.heightAnchor constraintEqualToConstant:44].active = YES;
    [self.segment addTarget:self
                     action:@selector(segmentChanged:)
           forControlEvents:UIControlEventValueChanged];
    [self.contentStack addArrangedSubview:self.segment];
    self.nearDateNotice = [self makeNearDateNotice];
    [self.contentStack addArrangedSubview:self.nearDateNotice];
    [self.contentStack addArrangedSubview:[self makeCategories]];
    [self.contentStack addArrangedSubview:[self makeListHeader]];
    self.ingredientList = QFStack(UILayoutConstraintAxisVertical, 10);
    self.ingredientList.accessibilityIdentifier = @"ingredient.list";
    [self.contentStack addArrangedSubview:self.ingredientList];
    [self refreshList];
}

- (UIView *)makeHeader {
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 10);
    row.alignment = UIStackViewAlignmentCenter;
    UIStackView *labels = QFStack(UILayoutConstraintAxisVertical, 6);
    [labels addArrangedSubview:QFLabel(@"食材", 28, UIFontWeightBold, QFText())];
    [labels addArrangedSubview:QFLabel(@"把家里的食材用起来", 12, UIFontWeightRegular, QFSecondary())];
    [row addArrangedSubview:labels];
    UIButton *scan = QFIconButton(@"qrcode.viewfinder", QFText());
    scan.accessibilityLabel = @"扫描小票二维码";
    scan.accessibilityIdentifier = @"ingredient.scan";
    scan.backgroundColor = UIColor.whiteColor;
    scan.layer.cornerRadius = 14;
    scan.layer.borderWidth = 1;
    scan.layer.borderColor = QFBorder().CGColor;
    [scan.widthAnchor constraintEqualToConstant:44].active = YES;
    [scan.heightAnchor constraintEqualToConstant:40].active = YES;
    UIButton *add = QFButton(@"＋ 添加", 14, UIColor.whiteColor);
    add.backgroundColor = QFOrange();
    add.layer.cornerRadius = 14;
    add.accessibilityIdentifier = @"ingredient.add";
    [add.widthAnchor constraintEqualToConstant:72].active = YES;
    [add.heightAnchor constraintEqualToConstant:40].active = YES;
    __weak typeof(self) weakSelf = self;
    QFOnTap(scan, ^{
        QFShowUnavailable(weakSelf, @"扫描小票二维码");
    });
    QFOnTap(add, ^{
        QFShowUnavailable(weakSelf, @"添加食材");
    });
    [row addArrangedSubview:scan];
    [row addArrangedSubview:add];
    return row;
}

- (UIView *)makeSearchField {
    UIView *card = QFCard();
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1;
    card.layer.borderColor = QFBorder().CGColor;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = QFSecondary();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];
    self.searchField = [[UITextField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.font = [UIFont systemFontOfSize:14];
    self.searchField.textColor = QFText();
    self.searchField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:@"搜索食材名称"
                                        attributes:@{NSForegroundColorAttributeName : QFSecondary()}];
    self.searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.searchField.returnKeyType = UIReturnKeySearch;
    self.searchField.delegate = self;
    self.searchField.accessibilityIdentifier = @"ingredient.search";
    self.searchField.accessibilityLabel = @"搜索食材名称";
    [self.searchField addTarget:self
                         action:@selector(searchChanged:)
               forControlEvents:UIControlEventEditingChanged];
    [card addSubview:self.searchField];
    [NSLayoutConstraint activateConstraints:@[
        [card.heightAnchor constraintEqualToConstant:44],
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:19], [icon.heightAnchor constraintEqualToConstant:19],
        [self.searchField.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [self.searchField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [self.searchField.topAnchor constraintEqualToAnchor:card.topAnchor],
        [self.searchField.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]
    ]];
    return card;
}

- (UIView *)makeDiscoveryEntries {
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 12);
    row.distribution = UIStackViewDistributionFillEqually;
    [row addArrangedSubview:[self discoveryButton:@"食材大全"
                                         subtitle:@"分类查找，认识食材"
                                           symbol:@"book.closed"
                                            color:QFPaleGreen()
                                           accent:QFGreen()]];
    [row addArrangedSubview:[self discoveryButton:@"食材组合推荐"
                                         subtitle:@"选食材，看看能做什么"
                                           symbol:@"circle"
                                            color:QFHex(0xFFF0E7)
                                           accent:QFOrange()]];
    return row;
}

- (UIView *)discoveryButton:(NSString *)title
                   subtitle:(NSString *)subtitle
                     symbol:(NSString *)symbol
                      color:(UIColor *)color
                     accent:(UIColor *)accent {
    UIButton *button = QFButton(@"", 16, QFText());
    button.backgroundColor = color;
    button.layer.cornerRadius = 18;
    button.accessibilityLabel = title;
    button.accessibilityHint = subtitle;
    UILabel *heading = QFLabel(title, 16, UIFontWeightSemibold, QFText());
    heading.numberOfLines = 1;
    heading.adjustsFontSizeToFitWidth = YES;
    heading.minimumScaleFactor = 0.76;
    UILabel *caption = QFLabel(subtitle, 11, UIFontWeightRegular, accent);
    caption.numberOfLines = 1;
    caption.adjustsFontSizeToFitWidth = YES;
    caption.minimumScaleFactor = 0.85;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = accent;
    if ([symbol isEqualToString:@"circle"]) {
        UIImageView *overlap = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle"]];
        overlap.translatesAutoresizingMaskIntoConstraints = NO;
        overlap.contentMode = UIViewContentModeScaleAspectFit;
        overlap.tintColor = accent;
        [icon addSubview:overlap];
        [NSLayoutConstraint activateConstraints:@[
            [overlap.leadingAnchor constraintEqualToAnchor:icon.leadingAnchor constant:7],
            [overlap.topAnchor constraintEqualToAnchor:icon.topAnchor constant:9],
            [overlap.widthAnchor constraintEqualToConstant:19],
            [overlap.heightAnchor constraintEqualToConstant:19]
        ]];
    }
    for (UIView *view in @[ heading, caption, icon ]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        view.userInteractionEnabled = NO;
        [button addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [button.heightAnchor constraintEqualToConstant:74],
        [heading.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:14],
        [heading.topAnchor constraintEqualToAnchor:button.topAnchor constant:13],
        [heading.trailingAnchor constraintLessThanOrEqualToAnchor:icon.leadingAnchor constant:-4],
        [icon.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-13],
        [icon.topAnchor constraintEqualToAnchor:button.topAnchor constant:17],
        [icon.widthAnchor constraintEqualToConstant:21], [icon.heightAnchor constraintEqualToConstant:23],
        [caption.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
        [caption.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-12],
        [caption.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-13]
    ]];
    __weak typeof(self) weakSelf = self;
    QFOnTap(button, ^{
        QFShowUnavailable(weakSelf, title);
    });
    return button;
}

- (UIView *)makeNearDateNotice {
    UIButton *button = QFButton(@"", 12, QFHex(0xA16A17));
    button.backgroundColor = QFHex(0xFFF4DC);
    button.layer.cornerRadius = 14;
    button.accessibilityLabel = @"2 种食材临近标注日期，查看";
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 9);
    row.userInteractionEnabled = NO;
    row.alignment = UIStackViewAlignmentCenter;
    UIImageView *clock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"clock"]];
    clock.translatesAutoresizingMaskIntoConstraints = NO;
    clock.tintColor = QFHex(0xA16A17);
    clock.contentMode = UIViewContentModeScaleAspectFit;
    [clock.widthAnchor constraintEqualToConstant:17].active = YES;
    [clock.heightAnchor constraintEqualToConstant:17].active = YES;
    [row addArrangedSubview:clock];
    [row addArrangedSubview:QFLabel(@"2 种食材临近标注日期", 12, UIFontWeightRegular, QFHex(0xA16A17))];
    [row addArrangedSubview:[[UIView alloc] init]];
    [row addArrangedSubview:QFLabel(@"查看  ›", 12, UIFontWeightMedium, QFHex(0xA16A17))];
    [button addSubview:row];
    QFPin(row, button, UIEdgeInsetsMake(12, 14, 12, 14));
    __weak typeof(self) weakSelf = self;
    QFOnTap(button, ^{
        QFShowUnavailable(weakSelf, @"临期食材");
    });
    return button;
}

- (UIView *)makeCategories {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.accessibilityIdentifier = @"ingredient.categories";
    [scroll.heightAnchor constraintEqualToConstant:32].active = YES;
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 8);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor]
    ]];
    __weak typeof(self) weakSelf = self;
    [self.categories enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.accessibilityLabel = name;
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(5, 15, 5, 15);
        configuration.baseForegroundColor = QFSecondary();
        configuration.attributedTitle = [[NSAttributedString alloc]
            initWithString:name
                attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}];
        button.configuration = configuration;
        button.layer.cornerRadius = 16;
        button.layer.borderWidth = 1;
        button.accessibilityIdentifier = [@"ingredient.category." stringByAppendingString:name];
        QFOnTap(button, ^{
            weakSelf.selectedCategory = (NSInteger)index;
            [weakSelf refreshList];
        });
        [weakSelf.categoryButtons addObject:button];
        [row addArrangedSubview:button];
    }];
    return scroll;
}

- (UIView *)makeListHeader {
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 8);
    row.alignment = UIStackViewAlignmentCenter;
    self.listTitle = QFLabel(@"我的食材", 17, UIFontWeightSemibold, QFText());
    [row addArrangedSubview:self.listTitle];
    [row addArrangedSubview:[[UIView alloc] init]];
    self.sortButton = QFButton(@"临期优先  ﹀", 12, QFSecondary());
    self.sortButton.accessibilityLabel = @"食材排序，临期优先";
    [self.sortButton.heightAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
    [row addArrangedSubview:self.sortButton];
    __weak typeof(self) weakSelf = self;
    QFOnTap(self.sortButton, ^{
        if (weakSelf.segment.selectedSegmentIndex == 0) {
            weakSelf.nearDateFirst = !weakSelf.nearDateFirst;
            [weakSelf refreshList];
        }
    });
    return row;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self refreshList];
}

- (void)searchChanged:(UITextField *)sender {
    [self refreshList];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)refreshList {
    BOOL shopping = self.segment.selectedSegmentIndex == 1;
    self.nearDateNotice.hidden = shopping;
    self.listTitle.text = shopping ? @"待采购食材" : @"我的食材";
    [self.sortButton
        setTitle:shopping ? @"预计 ¥16.20" : (self.nearDateFirst ? @"临期优先  ﹀" : @"默认排序  ﹀")
        forState:UIControlStateNormal];
    self.sortButton.enabled = !shopping;
    self.sortButton.accessibilityLabel =
        shopping ? @"预计花费16.20元" : (self.nearDateFirst ? @"食材排序，临期优先" : @"食材排序，默认排序");
    for (NSUInteger index = 0; index < self.categoryButtons.count; index++) {
        UIButton *button = self.categoryButtons[index];
        BOOL selected = (NSInteger)index == self.selectedCategory;
        button.backgroundColor = selected ? QFPaleGreen() : UIColor.whiteColor;
        button.layer.borderColor = selected ? UIColor.clearColor.CGColor : QFBorder().CGColor;
        UIButtonConfiguration *configuration = button.configuration;
        configuration.baseForegroundColor = selected ? QFGreen() : QFSecondary();
        button.configuration = configuration;
        button.accessibilityTraits =
            UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    }
    for (UIView *view in [self.ingredientList.arrangedSubviews copy]) {
        [self.ingredientList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSString *query = [self.searchField.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *category = self.categories[self.selectedCategory];
    NSArray<NSDictionary *> *source = shopping ? self.shopping : self.inventory;
    if (!shopping && !self.nearDateFirst) {
        source =
            [source sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
                return [left[@"name"] localizedStandardCompare:right[@"name"]];
            }];
    }
    NSUInteger count = 0;
    for (NSDictionary *item in source) {
        if (self.selectedCategory > 0 && ![item[@"category"] isEqualToString:category])
            continue;
        if (query.length > 0 && ![item[@"name"] localizedCaseInsensitiveContainsString:query])
            continue;
        [self.ingredientList addArrangedSubview:[self ingredientCard:item shopping:shopping]];
        count++;
    }
    if (count == 0) {
        UIView *empty = QFCard();
        UIStackView *labels = QFStack(UILayoutConstraintAxisVertical, 8);
        labels.alignment = UIStackViewAlignmentCenter;
        [labels addArrangedSubview:QFLabel(@"没有找到相关食材", 15, UIFontWeightMedium, QFText())];
        [labels addArrangedSubview:QFLabel(@"换个名称或分类试试", 12, UIFontWeightRegular, QFSecondary())];
        [empty addSubview:labels];
        QFPin(labels, empty, UIEdgeInsetsMake(30, 12, 30, 12));
        [self.ingredientList addArrangedSubview:empty];
    }
}

- (UIView *)ingredientCard:(NSDictionary *)item shopping:(BOOL)shopping {
    UIView *card = QFCard();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 1;
    card.layer.borderColor = QFBorder().CGColor;
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 12);
    row.alignment = UIStackViewAlignmentCenter;
    [card addSubview:row];
    QFPin(row, card, UIEdgeInsetsMake(13, 14, 13, 12));
    UIView *emoji = [UIView new];
    emoji.translatesAutoresizingMaskIntoConstraints = NO;
    emoji.backgroundColor = [item[@"id"] isEqualToString:@"milk"]
                                ? QFHex(0xE7F1F5)
                                : ([item[@"id"] isEqualToString:@"egg"] ? QFHex(0xFFF0D9) : QFPaleGreen());
    emoji.layer.cornerRadius = 12;
    emoji.clipsToBounds = YES;
    emoji.accessibilityElementsHidden = YES;
    [emoji.widthAnchor constraintEqualToConstant:48].active = YES;
    [emoji.heightAnchor constraintEqualToConstant:48].active = YES;
    NSString *identifier = item[@"id"] ?: @"";
    UIImage *ingredientImage = [UIImage imageNamed:[@"ingredient-" stringByAppendingString:identifier]];
    if (!ingredientImage) {
        NSDictionary<NSString *, NSString *> *fallbacks = @{
            @"肉蛋" : @"meat",
            @"蔬菜" : @"vegetable",
            @"奶制品" : @"milk",
            @"水果" : @"fruit",
            @"谷物" : @"grain",
            @"水产" : @"seafood",
            @"菌藻" : @"mushroom",
            @"调味" : @"seasoning"
        };
        NSString *category = item[@"category"] ?: @"";
        NSString *fallback = fallbacks[category] ?: @"generic";
        ingredientImage = [UIImage imageNamed:[@"ingredient-" stringByAppendingString:fallback]];
    }
    if (!ingredientImage) {
        ingredientImage = [UIImage imageNamed:@"ingredient-generic"];
    }
    UIImageView *art = [[UIImageView alloc] initWithImage:ingredientImage];
    art.translatesAutoresizingMaskIntoConstraints = NO;
    art.contentMode = UIViewContentModeScaleAspectFit;
    [emoji addSubview:art];
    [NSLayoutConstraint activateConstraints:@[
        [art.centerXAnchor constraintEqualToAnchor:emoji.centerXAnchor],
        [art.centerYAnchor constraintEqualToAnchor:emoji.centerYAnchor],
        [art.widthAnchor constraintEqualToConstant:36], [art.heightAnchor constraintEqualToConstant:36]
    ]];
    [row addArrangedSubview:emoji];
    UIStackView *labels = QFStack(UILayoutConstraintAxisVertical, 9);
    UILabel *name = QFLabel(item[@"name"], 17, UIFontWeightSemibold, QFText());
    name.numberOfLines = 1;
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.85;
    UILabel *amount = QFLabel(item[@"amount"], 12, UIFontWeightRegular, QFText());
    amount.numberOfLines = 1;
    amount.adjustsFontSizeToFitWidth = YES;
    amount.minimumScaleFactor = 0.8;
    [labels addArrangedSubview:name];
    [labels addArrangedSubview:amount];
    [row addArrangedSubview:labels];
    UIStackView *right = QFStack(UILayoutConstraintAxisVertical, 0);
    right.alignment = UIStackViewAlignmentTrailing;
    UIStackView *actions = QFStack(UILayoutConstraintAxisHorizontal, 5);
    actions.alignment = UIStackViewAlignmentCenter;
    if (!shopping) {
        UILabel *storage = QFLabel(item[@"storage"], 10.5, UIFontWeightRegular, QFGreen());
        storage.textAlignment = NSTextAlignmentCenter;
        storage.backgroundColor = QFPaleGreen();
        storage.layer.cornerRadius = 11;
        storage.clipsToBounds = YES;
        [storage.widthAnchor constraintEqualToConstant:42].active = YES;
        [storage.heightAnchor constraintEqualToConstant:22].active = YES;
        [actions addArrangedSubview:storage];
    }
    UIButton *more = QFIconButton(@"ellipsis", QFSecondary());
    more.accessibilityLabel = [item[@"name"] stringByAppendingString:@"，更多操作"];
    [more.widthAnchor constraintEqualToConstant:40].active = YES;
    [more.heightAnchor constraintEqualToConstant:40].active = YES;
    __weak typeof(self) weakSelf = self;
    QFOnTap(more, ^{
        QFShowUnavailable(weakSelf, [item[@"name"] stringByAppendingString:@"管理"]);
    });
    [actions addArrangedSubview:more];
    [right addArrangedSubview:actions];
    UILabel *date =
        QFLabel(shopping ? item[@"price"] : item[@"date"], 10.5, UIFontWeightRegular,
                shopping ? QFOrange() : ([item[@"near"] boolValue] ? QFHex(0xA66C1E) : QFSecondary()));
    date.numberOfLines = 1;
    [right addArrangedSubview:date];
    [right.widthAnchor constraintEqualToConstant:92].active = YES;
    [row addArrangedSubview:right];
    return card;
}
@end
