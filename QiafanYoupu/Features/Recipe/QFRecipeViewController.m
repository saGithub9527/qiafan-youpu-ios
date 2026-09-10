#import "QFRecipeViewController.h"

@interface QFRecipeViewController ()
@property (nonatomic, copy) NSArray<NSString *> *categories;
@property (nonatomic, copy) NSArray<NSDictionary *> *recipes;
@property (nonatomic, strong) NSMutableArray<UIButton *> *categoryButtons;
@property (nonatomic, strong) UIScrollView *categoryScroll;
@property (nonatomic, strong) UIStackView *recipeList;
@property (nonatomic, strong) UILabel *sectionTitle;
@property (nonatomic, strong) UILabel *recipeCount;
@property (nonatomic) NSInteger selectedCategory;
@end

@implementation QFRecipeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"菜谱";
    self.view.backgroundColor = QFHex(0xF5F6F8);
    self.contentStack.spacing = 14;
    self.categories = @[
        @"推荐", @"早餐", @"家常菜", @"快手菜", @"肉类", @"素菜", @"海鲜", @"小吃", @"烘焙", @"甜品", @"饮品"
    ];
    self.categoryButtons = [NSMutableArray array];
    self.recipes = @[
        @{
            @"name" : @"番茄炖牛腩",
            @"origin" : @"中国 · 家常菜",
            @"time" : @"90 分钟 · 2 人份",
            @"rating" : @"4.9",
            @"saves" : @"2,386 收藏",
            @"asset" : @"dish-stew",
            @"categories" : @[ @"家常菜", @"肉类" ]
        },
        @{
            @"name" : @"番茄罗勒意面",
            @"origin" : @"意大利 · 意式料理",
            @"time" : @"25 分钟 · 2 人份",
            @"rating" : @"4.8",
            @"saves" : @"1,624 收藏",
            @"asset" : @"dish-noodles",
            @"categories" : @[ @"快手菜", @"素菜" ]
        },
        @{
            @"name" : @"泰式打抛鸡",
            @"origin" : @"泰国 · 泰式料理",
            @"time" : @"20 分钟 · 2 人份",
            @"rating" : @"4.9",
            @"saves" : @"3,108 收藏",
            @"asset" : @"dish-rice",
            @"categories" : @[ @"家常菜", @"快手菜", @"肉类" ]
        },
        @{
            @"name" : @"照烧三文鱼饭",
            @"origin" : @"日本 · 日式料理",
            @"time" : @"25 分钟 · 2 人份",
            @"rating" : @"4.8",
            @"saves" : @"2,041 收藏",
            @"asset" : @"dish-seafood",
            @"categories" : @[ @"快手菜", @"海鲜" ]
        }
    ];
    UIView *categoryHeader = [self makeCategoryHeader];
    UIView *filters = [self makeFilters];
    UIView *sectionHeader = [self makeSectionHeader];
    [self.contentStack addArrangedSubview:categoryHeader];
    [self.contentStack setCustomSpacing:7 afterView:categoryHeader];
    [self.contentStack addArrangedSubview:filters];
    [self.contentStack setCustomSpacing:8 afterView:filters];
    [self.contentStack addArrangedSubview:sectionHeader];
    [self.contentStack setCustomSpacing:6 afterView:sectionHeader];
    self.recipeList = QFStack(UILayoutConstraintAxisVertical, 12);
    self.recipeList.accessibilityIdentifier = @"recipe.list";
    [self.contentStack addArrangedSubview:self.recipeList];
    [self selectCategory:0];
}

- (UIView *)makeCategoryHeader {
    UIStackView *header = QFStack(UILayoutConstraintAxisHorizontal, 8);
    header.alignment = UIStackViewAlignmentCenter;
    self.categoryScroll = [[UIScrollView alloc] init];
    self.categoryScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.categoryScroll.showsHorizontalScrollIndicator = NO;
    self.categoryScroll.accessibilityIdentifier = @"recipe.categories";
    UIStackView *items = QFStack(UILayoutConstraintAxisHorizontal, 24);
    items.translatesAutoresizingMaskIntoConstraints = NO;
    [self.categoryScroll addSubview:items];
    [items mas_makeConstraints:^(MASConstraintMaker *make) {
        make.leading.equalTo(
            QFLayoutGuideAttribute(self.categoryScroll.contentLayoutGuide, NSLayoutAttributeLeading));
        make.trailing
            .equalTo(
                QFLayoutGuideAttribute(self.categoryScroll.contentLayoutGuide, NSLayoutAttributeTrailing))
            .offset(-8);
        make.top.equalTo(
            QFLayoutGuideAttribute(self.categoryScroll.contentLayoutGuide, NSLayoutAttributeTop));
        make.bottom.equalTo(
            QFLayoutGuideAttribute(self.categoryScroll.contentLayoutGuide, NSLayoutAttributeBottom));
        make.height.equalTo(
            QFLayoutGuideAttribute(self.categoryScroll.frameLayoutGuide, NSLayoutAttributeHeight));
    }];
    [self.categoryScroll mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_equalTo(40);
    }];
    __weak typeof(self) weakSelf = self;
    [self.categories enumerateObjectsUsingBlock:^(NSString *name, NSUInteger index, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.accessibilityLabel = name;
        button.accessibilityIdentifier = [@"recipe.category." stringByAppendingString:name];
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 9, 0);
        configuration.title = name;
        button.configuration = configuration;
        [button mas_makeConstraints:^(MASConstraintMaker *make) {
            make.width.mas_greaterThanOrEqualTo(42);
        }];
        UIView *line = [[UIView alloc] init];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        line.backgroundColor = QFOrange();
        line.layer.cornerRadius = 1.5;
        line.tag = 110;
        line.userInteractionEnabled = NO;
        [button addSubview:line];
        [line mas_makeConstraints:^(MASConstraintMaker *make) {
            make.centerX.equalTo(button.mas_centerX);
            make.bottom.equalTo(button.mas_bottom).offset(-8);
            make.width.mas_equalTo(32);
            make.height.mas_equalTo(3);
        }];
        QFOnTap(button, ^{
            [weakSelf selectCategory:(NSInteger)index];
        });
        [weakSelf.categoryButtons addObject:button];
        [items addArrangedSubview:button];
    }];
    [header addArrangedSubview:self.categoryScroll];
    UIImageView *more = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    more.translatesAutoresizingMaskIntoConstraints = NO;
    more.tintColor = QFSecondary();
    more.contentMode = UIViewContentModeScaleAspectFit;
    [more mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.mas_equalTo(10);
        make.height.mas_equalTo(15);
    }];
    more.accessibilityElementsHidden = YES;
    [header addArrangedSubview:more];
    UIButton *search = QFIconButton(@"magnifyingglass", QFText());
    search.accessibilityLabel = @"搜索菜谱";
    search.accessibilityIdentifier = @"recipe.search";
    [search mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.height.mas_equalTo(40);
    }];
    QFOnTap(search, ^{
        QFShowUnavailable(weakSelf, @"搜索菜谱");
    });
    [header addArrangedSubview:search];
    return header;
}

- (UIView *)makeFilters {
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 6);
    row.distribution = UIStackViewDistributionFillEqually;
    NSArray *names = @[ @"国家", @"口味", @"菜系", @"评分" ];
    NSArray *values = @[ @"全球", @"不限", @"全部", @"不限" ];
    __weak typeof(self) weakSelf = self;
    for (NSUInteger index = 0; index < names.count; index++) {
        NSString *name = names[index];
        UIButton *button = QFButton(@"", 12, QFText());
        button.backgroundColor = UIColor.whiteColor;
        button.layer.cornerRadius = 12;
        button.layer.borderWidth = 1;
        button.layer.borderColor = QFBorder().CGColor;
        button.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", name, values[index]];
        button.accessibilityIdentifier = [@"recipe.filter." stringByAppendingString:name];
        UIStackView *labels = QFStack(UILayoutConstraintAxisVertical, 4);
        labels.translatesAutoresizingMaskIntoConstraints = NO;
        labels.userInteractionEnabled = NO;
        [labels addArrangedSubview:QFLabel(name, 10.5, UIFontWeightRegular, QFSecondary())];
        [labels addArrangedSubview:QFLabel(values[index], 12, UIFontWeightMedium, QFText())];
        [button addSubview:labels];
        UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
        arrow.translatesAutoresizingMaskIntoConstraints = NO;
        arrow.tintColor = QFSecondary();
        arrow.contentMode = UIViewContentModeScaleAspectFit;
        arrow.userInteractionEnabled = NO;
        [button addSubview:arrow];
        [button mas_makeConstraints:^(MASConstraintMaker *make) {
            make.height.mas_equalTo(48);
        }];
        [labels mas_makeConstraints:^(MASConstraintMaker *make) {
            make.leading.equalTo(button.mas_leading).offset(11);
            make.centerY.equalTo(button.mas_centerY);
            make.trailing.lessThanOrEqualTo(arrow.mas_leading).offset(-3);
        }];
        [arrow mas_makeConstraints:^(MASConstraintMaker *make) {
            make.trailing.equalTo(button.mas_trailing).offset(-10);
            make.bottom.equalTo(button.mas_bottom).offset(-12);
            make.width.height.mas_equalTo(9);
        }];
        QFOnTap(button, ^{
            QFShowUnavailable(weakSelf, [name stringByAppendingString:@"筛选"]);
        });
        [row addArrangedSubview:button];
    }
    return row;
}

- (UIView *)makeSectionHeader {
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 10);
    row.alignment = UIStackViewAlignmentCenter;
    self.sectionTitle = QFLabel(@"为你推荐", 17, UIFontWeightSemibold, QFText());
    self.recipeCount = QFLabel(@"4 道菜", 12, UIFontWeightRegular, QFSecondary());
    [row addArrangedSubview:self.sectionTitle];
    [row addArrangedSubview:self.recipeCount];
    UIView *space = [[UIView alloc] init];
    [row addArrangedSubview:space];
    [self.sectionTitle setContentHuggingPriority:UILayoutPriorityRequired
                                         forAxis:UILayoutConstraintAxisHorizontal];
    [self.recipeCount setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
    UIButton *clear = QFButton(@"清空筛选", 12, QFSecondary());
    clear.accessibilityIdentifier = @"recipe.clearFilters";
    [clear mas_makeConstraints:^(MASConstraintMaker *make) {
        make.height.mas_greaterThanOrEqualTo(28);
    }];
    __weak typeof(self) weakSelf = self;
    QFOnTap(clear, ^{
        [weakSelf selectCategory:0];
        [weakSelf.categoryScroll setContentOffset:CGPointZero animated:YES];
    });
    [row addArrangedSubview:clear];
    return row;
}

- (void)selectCategory:(NSInteger)index {
    self.selectedCategory = index;
    [self.categoryButtons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger buttonIndex, BOOL *stop) {
        BOOL selected = (NSInteger)buttonIndex == index;
        UIButtonConfiguration *configuration = button.configuration;
        configuration.baseForegroundColor = selected ? QFText() : QFSecondary();
        configuration.attributedTitle = [[NSAttributedString alloc]
            initWithString:configuration.title
                attributes:@{
                    NSFontAttributeName :
                        [UIFont systemFontOfSize:selected ? 20 : 17
                                          weight:selected ? UIFontWeightBold : UIFontWeightSemibold]
                }];
        button.configuration = configuration;
        [button viewWithTag:110].hidden = !selected;
        button.accessibilityTraits =
            UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
    }];
    NSString *category = self.categories[index];
    self.sectionTitle.text = index == 0 ? @"为你推荐" : category;
    for (UIView *view in [self.recipeList.arrangedSubviews copy]) {
        [self.recipeList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSUInteger count = 0;
    for (NSDictionary *recipe in self.recipes) {
        if (index != 0 && ![recipe[@"categories"] containsObject:category])
            continue;
        [self.recipeList addArrangedSubview:[self recipeCard:recipe]];
        count++;
    }
    self.recipeCount.text = [NSString stringWithFormat:@"%lu 道菜", (unsigned long)count];
    if (count == 0) {
        UIView *empty = QFCard();
        UIStackView *text = QFStack(UILayoutConstraintAxisVertical, 8);
        text.alignment = UIStackViewAlignmentCenter;
        [text addArrangedSubview:QFLabel(@"还没有找到相关菜谱", 15, UIFontWeightMedium, QFText())];
        [text
            addArrangedSubview:QFLabel(@"换个分类，发现更多好味道", 12, UIFontWeightRegular, QFSecondary())];
        [empty addSubview:text];
        QFPin(text, empty, UIEdgeInsetsMake(32, 12, 32, 12));
        [self.recipeList addArrangedSubview:empty];
    }
}

- (UIView *)recipeCard:(NSDictionary *)recipe {
    UIView *card = QFCard();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 0;
    UIButton *open = QFButton(@"", 16, QFText());
    open.accessibilityLabel =
        [NSString stringWithFormat:@"%@，%@，%@，评分%@，%@", recipe[@"name"], recipe[@"origin"],
                                   recipe[@"time"], recipe[@"rating"], recipe[@"saves"]];
    open.accessibilityHint = @"查看菜谱详情";
    [card addSubview:open];
    QFPin(open, card, UIEdgeInsetsZero);
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 14);
    row.userInteractionEnabled = NO;
    row.alignment = UIStackViewAlignmentCenter;
    [card addSubview:row];
    QFPin(row, card, UIEdgeInsetsMake(10, 10, 10, 14));
    UIImageView *art = QFImage(recipe[@"asset"], UIViewContentModeScaleAspectFill);
    art.backgroundColor = QFHex(0xFCF6EB);
    art.layer.cornerRadius = 12;
    art.clipsToBounds = YES;
    [art mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.height.mas_equalTo(108);
    }];
    [row addArrangedSubview:art];
    UIStackView *details = QFStack(UILayoutConstraintAxisVertical, 7);
    UIStackView *titleRow = QFStack(UILayoutConstraintAxisHorizontal, 0);
    UILabel *title = QFLabel(recipe[@"name"], 16, UIFontWeightSemibold, QFText());
    title.numberOfLines = 1;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;
    [titleRow addArrangedSubview:title];
    UIView *bookmarkSpace = [[UIView alloc] init];
    [bookmarkSpace mas_makeConstraints:^(MASConstraintMaker *make) {
        make.width.mas_equalTo(22);
    }];
    [titleRow addArrangedSubview:bookmarkSpace];
    [details addArrangedSubview:titleRow];
    [details addArrangedSubview:QFLabel(recipe[@"origin"], 12, UIFontWeightRegular, QFSecondary())];
    [details addArrangedSubview:QFLabel(recipe[@"time"], 12, UIFontWeightRegular, QFSecondary())];
    [details addArrangedSubview:QFSpacer(1)];
    UIStackView *metrics = QFStack(UILayoutConstraintAxisHorizontal, 5);
    metrics.alignment = UIStackViewAlignmentCenter;
    [metrics addArrangedSubview:QFLabel(@"★", 15, UIFontWeightRegular, QFHex(0xE99A22))];
    [metrics addArrangedSubview:QFLabel(recipe[@"rating"], 13, UIFontWeightMedium, QFText())];
    [metrics addArrangedSubview:[[UIView alloc] init]];
    UILabel *saves = QFLabel(recipe[@"saves"], 11, UIFontWeightRegular, QFSecondary());
    saves.numberOfLines = 1;
    saves.adjustsFontSizeToFitWidth = YES;
    saves.minimumScaleFactor = 0.8;
    [metrics addArrangedSubview:saves];
    [details addArrangedSubview:metrics];
    [row addArrangedSubview:details];
    UIButton *bookmark = QFIconButton(@"bookmark", QFSecondary());
    bookmark.translatesAutoresizingMaskIntoConstraints = NO;
    bookmark.accessibilityLabel = [@"收藏" stringByAppendingString:recipe[@"name"]];
    [card addSubview:bookmark];
    [bookmark mas_makeConstraints:^(MASConstraintMaker *make) {
        make.trailing.equalTo(card.mas_trailing).offset(-6);
        make.top.equalTo(card.mas_top).offset(6);
        make.width.height.mas_equalTo(40);
    }];
    card.accessibilityElements = @[ open, bookmark ];
    __weak typeof(self) weakSelf = self;
    QFOnTap(open, ^{
        QFShowUnavailable(weakSelf, recipe[@"name"]);
    });
    QFOnTap(bookmark, ^{
        QFShowUnavailable(weakSelf, @"收藏菜谱");
    });
    return card;
}
@end
