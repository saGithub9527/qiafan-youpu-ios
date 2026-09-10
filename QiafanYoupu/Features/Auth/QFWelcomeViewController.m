#import "QFWelcomeViewController.h"
#import "../../DesignSystem/QFDesign.h"
#import "QFAuthComponents.h"
#import <math.h>

// Illustration pieces use a small native Auto Layout canvas, scaled with the available width.
// The canvas contains live labels, shapes, and individual transparent/dish assets, never a page image.
static void QFArtPlace(UIView *view, UIView *parent, CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:x],
        [view.topAnchor constraintEqualToAnchor:parent.topAnchor constant:y],
        [view.widthAnchor constraintEqualToConstant:width],
        [view.heightAnchor constraintEqualToConstant:height]
    ]];
}

static UIView *QFArtShape(UIColor *color, CGFloat radius) {
    UIView *shape = [UIView new];
    shape.backgroundColor = color;
    shape.layer.cornerRadius = radius;
    return shape;
}

static UIView *QFArtCard(UIColor *shadow) {
    UIView *card = QFArtShape(UIColor.whiteColor, 22);
    card.layer.shadowColor = shadow.CGColor;
    card.layer.shadowOpacity = 1;
    card.layer.shadowOffset = CGSizeMake(4, 6);
    card.layer.shadowRadius = 0;
    return card;
}

static UILabel *QFArtText(NSString *copy, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = QFLabel(copy, size, weight, color);
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    return label;
}

static void QFArtChip(UIView *canvas, NSString *copy, UIColor *background, UIColor *color, CGFloat x,
                      CGFloat y, CGFloat width) {
    UILabel *chip = QFArtText(copy, 12, UIFontWeightMedium, color);
    chip.backgroundColor = background;
    chip.textAlignment = NSTextAlignmentCenter;
    chip.layer.cornerRadius = 15;
    chip.clipsToBounds = YES;
    QFArtPlace(chip, canvas, x, y, width, 30);
}

@interface QFGlobeView : UIView
@end
@implementation QFGlobeView
- (void)drawRect:(CGRect)rect {
    [QFPaleGreen() setFill];
    [[UIBezierPath bezierPathWithOvalInRect:self.bounds] fill];
    CGRect globe = CGRectInset(self.bounds, 44, 24);
    UIBezierPath *outline = [UIBezierPath bezierPathWithOvalInRect:globe];
    [QFHex(0xADC399) setStroke];
    outline.lineWidth = 1.6;
    [outline stroke];
    UIBezierPath *meridian =
        [UIBezierPath bezierPathWithOvalInRect:CGRectInset(globe, CGRectGetWidth(globe) * 0.23, 0)];
    meridian.lineWidth = 1.4;
    [meridian stroke];
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    [outline addClip];
    UIBezierPath *lines = [UIBezierPath bezierPath];
    [lines moveToPoint:CGPointMake(CGRectGetMidX(globe), CGRectGetMinY(globe))];
    [lines addLineToPoint:CGPointMake(CGRectGetMidX(globe), CGRectGetMaxY(globe))];
    for (NSInteger index = 1; index < 3; index++) {
        CGFloat y = CGRectGetMinY(globe) + CGRectGetHeight(globe) * index / 3.0;
        [lines moveToPoint:CGPointMake(CGRectGetMinX(globe), y)];
        [lines addLineToPoint:CGPointMake(CGRectGetMaxX(globe), y)];
    }
    lines.lineWidth = 1.4;
    [lines stroke];
    CGContextRestoreGState(context);
}
@end

@interface QFWelcomeArtView : UIView
@property (nonatomic, strong) UIView *canvas;
- (instancetype)initWithPage:(NSInteger)page;
@end

@implementation QFWelcomeArtView
- (instancetype)initWithPage:(NSInteger)page {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _canvas = [UIView new];
        _canvas.translatesAutoresizingMaskIntoConstraints = NO;
        _canvas.accessibilityElementsHidden = YES;
        [self addSubview:_canvas];
        [NSLayoutConstraint activateConstraints:@[
            [_canvas.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_canvas.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_canvas.widthAnchor constraintEqualToConstant:342],
            [_canvas.heightAnchor constraintEqualToConstant:342]
        ]];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitImage;
        if (page == 0 || page == 4)
            [self makeChef:page == 4];
        else if (page == 1)
            [self makeWorld];
        else if (page == 2)
            [self makeRecipe];
        else
            [self makePlan];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) / 342.0;
    self.canvas.transform = CGAffineTransformMakeScale(scale, scale);
}
- (void)addPlusAtX:(CGFloat)x y:(CGFloat)y color:(UIColor *)color {
    UILabel *plus = QFArtText(@"+", 30, UIFontWeightLight, color);
    plus.textAlignment = NSTextAlignmentCenter;
    QFArtPlace(plus, self.canvas, x, y, 24, 30);
}
- (void)makeChef:(BOOL)ready {
    self.accessibilityLabel = ready ? @"小狗厨师准备开饭" : @"小狗厨师拿着锅铲和一锅蔬菜";
    QFArtPlace(QFArtShape(QFHex(0xFFF0E5), 139), self.canvas, 32, 30, 278, 278);
    if (!ready)
        QFArtPlace(QFArtShape(QFHex(0xF3DBC0), 90), self.canvas, 50, 298, 242, 17);
    QFArtPlace(QFImage(@"chef-logo", UIViewContentModeScaleAspectFit), self.canvas, 58, 8, 231, 297);
    QFArtChip(self.canvas, ready ? @"从喜欢的一道菜开始" : @"今天也要好好吃饭", UIColor.whiteColor,
              QFHex(0xBF4223), 84, 302, 174);
    [self addPlusAtX:24 y:112 color:QFOrange()];
    [self addPlusAtX:ready ? 298 : 295 y:ready ? 231 : 50 color:ready ? QFGreen() : QFOrange()];
    QFArtPlace(QFArtShape(QFOrange(), 2.5), self.canvas, 57, 48, 5, 5);
    QFArtPlace(QFArtShape(QFHex(0xD6E5C9), 3.5), self.canvas, 289, 225, 7, 7);
    if (ready) {
        UILabel *check = QFArtText(@"✓", 24, UIFontWeightMedium, QFGreen());
        check.textAlignment = NSTextAlignmentCenter;
        check.backgroundColor = UIColor.whiteColor;
        check.layer.cornerRadius = 19;
        check.clipsToBounds = YES;
        QFArtPlace(check, self.canvas, 275, 42, 38, 38);
    }
}
- (void)makeWorld {
    self.accessibilityLabel = @"按国家、口味与菜系探索：中国家常味点心，意大利地中海风味意面";
    QFGlobeView *globe = [QFGlobeView new];
    globe.backgroundColor = UIColor.clearColor;
    QFArtPlace(globe, self.canvas, 34, 38, 279, 279);
    QFArtChip(self.canvas, @"国家", UIColor.whiteColor, QFGreen(), 27, 27, 62);
    QFArtChip(self.canvas, @"口味", UIColor.whiteColor, QFGreen(), 109, 10, 62);
    QFArtChip(self.canvas, @"菜系", UIColor.whiteColor, QFGreen(), 193, 21, 62);
    UIView *china = QFArtCard(QFHex(0xD5E1C9));
    QFArtPlace(china, self.canvas, 7, 92, 144, 169);
    UIImageView *dimSum = QFImage(@"dish-dimsum", UIViewContentModeScaleAspectFill);
    dimSum.clipsToBounds = YES;
    dimSum.layer.cornerRadius = 17;
    QFArtPlace(dimSum, china, 8, 8, 128, 112);
    QFArtPlace(QFArtText(@"中国 · 家常味", 13, UIFontWeightSemibold, QFText()), china, 14, 130, 124, 19);
    QFArtPlace(QFArtText(@"熟悉，也有新惊喜", 10, UIFontWeightRegular, QFSecondary()), china, 14, 150, 124,
               15);
    UIView *italy = QFArtCard(QFHex(0xD5E1C9));
    QFArtPlace(italy, self.canvas, 188, 143, 154, 167);
    UIImageView *noodles = QFImage(@"dish-noodles", UIViewContentModeScaleAspectFill);
    noodles.clipsToBounds = YES;
    noodles.layer.cornerRadius = 17;
    QFArtPlace(noodles, italy, 8, 8, 138, 108);
    QFArtPlace(QFArtText(@"意大利 · 地中海风味", 11.8, UIFontWeightSemibold, QFText()), italy, 14, 127, 134,
               19);
    QFArtPlace(QFArtText(@"换个地方，尝点不同", 10.8, UIFontWeightRegular, QFSecondary()), italy, 14, 147,
               133, 16);
    [self addPlusAtX:305 y:79 color:QFGreen()];
    QFArtPlace(QFArtShape(QFOrange(), 4), self.canvas, 50, 305, 8, 8);
}
- (void)makeRecipe {
    self.accessibilityLabel = @"搜索番茄炒蛋，准备番茄、鸡蛋和调味料，再跟着步骤做";
    UIView *card = QFArtCard(QFHex(0xEDD9C0));
    QFArtPlace(card, self.canvas, 22, 86, 296, 249);
    UIImageView *rice = QFImage(@"dish-rice", UIViewContentModeScaleAspectFill);
    rice.clipsToBounds = YES;
    rice.layer.cornerRadius = 17;
    QFArtPlace(rice, card, 16, 23, 78, 78);
    QFArtPlace(QFArtText(@"番茄炒蛋", 17, UIFontWeightSemibold, QFText()), card, 108, 32, 130, 28);
    QFArtChip(card, @"家常菜", QFPaleGreen(), QFGreen(), 108, 68, 70);
    UIImageView *heart = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"heart"]];
    heart.tintColor = QFOrange();
    QFArtPlace(heart, card, 248, 33, 20, 20);
    QFArtPlace(QFArtText(@"准备食材", 13, UIFontWeightSemibold, QFText()), card, 19, 120, 150, 19);
    QFArtChip(card, @"番茄", QFHex(0xFAF5EB), QFSecondary(), 19, 145, 66);
    QFArtChip(card, @"鸡蛋", QFHex(0xFAF5EB), QFSecondary(), 92, 145, 66);
    QFArtChip(card, @"调味料", QFHex(0xFAF5EB), QFSecondary(), 165, 145, 78);
    QFArtPlace(QFArtShape(QFBorder(), 0), card, 19, 192, 259, 1);
    UILabel *number = QFArtText(@"1", 12, UIFontWeightMedium, QFHex(0xAB3A1C));
    number.textAlignment = NSTextAlignmentCenter;
    number.backgroundColor = QFHex(0xFFF0E5);
    number.layer.cornerRadius = 10;
    number.clipsToBounds = YES;
    QFArtPlace(number, card, 19, 208, 20, 20);
    QFArtPlace(QFArtText(@"处理食材，开始第一步", 12, UIFontWeightSemibold, QFText()), card, 49, 206, 220,
               24);
    UIView *search = QFArtShape(UIColor.whiteColor, 17);
    search.layer.borderWidth = 1;
    search.layer.borderColor = QFBorder().CGColor;
    QFArtPlace(search, self.canvas, 44, 48, 257, 52);
    UIImageView *magnifying =
        [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    magnifying.tintColor = QFOrange();
    QFArtPlace(magnifying, search, 17, 16, 19, 19);
    QFArtPlace(QFArtText(@"番茄炒蛋", 14, UIFontWeightSemibold, QFText()), search, 48, 13, 160, 26);
    UILabel *arrow = QFArtText(@"→", 22, UIFontWeightMedium, QFOrange());
    arrow.backgroundColor = QFHex(0xFFF0E5);
    arrow.textAlignment = NSTextAlignmentCenter;
    arrow.layer.cornerRadius = 8;
    arrow.clipsToBounds = YES;
    QFArtPlace(arrow, search, 213, 15, 26, 23);
    [self addPlusAtX:8 y:258 color:QFOrange()];
    QFArtPlace(QFArtShape(QFOrange(), 3), self.canvas, 311, 72, 6, 6);
}
- (void)makePlan {
    self.accessibilityLabel = @"一周菜单安排了晚餐，食材清单中的蔬菜和鸡蛋已准备好";
    QFArtPlace(QFArtShape(QFPaleGreen(), 125), self.canvas, 53, 66, 265, 253);
    UIView *calendar = QFArtCard(QFHex(0xD5E1C9));
    QFArtPlace(calendar, self.canvas, 22, 59, 282, 228);
    QFArtPlace(QFArtText(@"我的一周菜单", 18, UIFontWeightSemibold, QFText()), calendar, 20, 15, 233, 27);
    QFArtPlace(QFArtShape(QFBorder(), 0), calendar, 20, 48, 239, 1);
    NSArray *days = @[ @"一", @"二", @"三", @"四", @"五", @"六", @"日" ];
    for (NSInteger day = 0; day < 7; day++) {
        UILabel *weekday = QFArtText(days[day], 11, UIFontWeightRegular, QFSecondary());
        weekday.textAlignment = NSTextAlignmentCenter;
        QFArtPlace(weekday, calendar, 17 + 36 * day, 60, 30, 18);
        UILabel *date = QFArtText([NSString stringWithFormat:@"%ld", (long)14 + day], 12, UIFontWeightRegular,
                                  day == 2 ? UIColor.whiteColor : QFText());
        date.textAlignment = NSTextAlignmentCenter;
        date.backgroundColor = day == 2 ? QFOrange() : UIColor.clearColor;
        date.layer.cornerRadius = 9;
        date.clipsToBounds = YES;
        QFArtPlace(date, calendar, 17 + 36 * day, 84, 27, 30);
    }
    UIImageView *dish = QFImage(@"dish-vegetables", UIViewContentModeScaleAspectFill);
    dish.clipsToBounds = YES;
    dish.layer.cornerRadius = 16;
    QFArtPlace(dish, calendar, 19, 135, 64, 64);
    QFArtPlace(QFArtText(@"今天吃点清爽的", 13, UIFontWeightSemibold, QFText()), calendar, 95, 141, 147, 23);
    QFArtPlace(QFArtText(@"已加入晚餐计划", 12, UIFontWeightRegular, QFSecondary()), calendar, 95, 165, 147,
               23);
    QFArtChip(calendar, @"✓", QFPaleGreen(), QFGreen(), 241, 144, 22);
    UIView *list = QFArtCard(QFHex(0xD5E1C9));
    QFArtPlace(list, self.canvas, 83, 250, 244, 87);
    QFArtPlace(QFArtText(@"食材清单", 13, UIFontWeightSemibold, QFText()), list, 20, 12, 170, 20);
    QFArtPlace(QFArtText(@"✓  蔬菜", 12, UIFontWeightRegular, QFSecondary()), list, 23, 42, 89, 20);
    QFArtPlace(QFArtText(@"✓  鸡蛋", 12, UIFontWeightRegular, QFSecondary()), list, 110, 42, 89, 20);
    QFArtPlace(QFArtText(@"都安排好了", 10, UIFontWeightSemibold, QFGreen()), list, 167, 66, 70, 17);
    [self addPlusAtX:312 y:110 color:QFGreen()];
    QFArtPlace(QFArtShape(QFOrange(), 3), self.canvas, 17, 279, 6, 6);
}
@end

@interface QFWelcomeViewController () <UIScrollViewDelegate>
@property (nonatomic, strong) UIScrollView *pager;
@property (nonatomic) NSInteger selectedPage;
@property (nonatomic) CGFloat lastPageWidth;
@property (nonatomic) BOOL completed;
@end

@implementation QFWelcomeViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QFBackground();
    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    UIImageView *icon = QFImage(@"chef-icon", UIViewContentModeScaleAspectFit);
    icon.layer.cornerRadius = 9;
    icon.clipsToBounds = YES;
    [header addSubview:icon];
    UILabel *intro = QFLabel(@"下厨，从这里开始", 12, UIFontWeightMedium, QFSecondary());
    [header addSubview:intro];
    UIButton *skip = QFButton(@"跳过介绍", 12, QFSecondary());
    skip.accessibilityIdentifier = @"welcome.skip";
    [skip addTarget:self action:@selector(requestEntry) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:skip];
    _pager = [UIScrollView new];
    _pager.translatesAutoresizingMaskIntoConstraints = NO;
    _pager.pagingEnabled = YES;
    _pager.directionalLockEnabled = YES;
    _pager.showsHorizontalScrollIndicator = NO;
    _pager.showsVerticalScrollIndicator = NO;
    _pager.delegate = self;
    _pager.accessibilityIdentifier = @"welcome.pages";
    _pager.accessibilityLabel = @"欢迎介绍";
    _pager.accessibilityValue = @"第 1 页，共 5 页";
    [self.view addSubview:_pager];
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [header.heightAnchor constraintEqualToConstant:44],
        [icon.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:30], [icon.heightAnchor constraintEqualToConstant:30],
        [intro.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [intro.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [skip.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [skip.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [skip.heightAnchor constraintEqualToConstant:44], [skip.widthAnchor constraintEqualToConstant:62],
        [intro.trailingAnchor constraintLessThanOrEqualToAnchor:skip.leadingAnchor constant:-8],
        [_pager.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:9],
        [_pager.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_pager.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_pager.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    UIView *previous = nil;
    for (NSInteger page = 0; page < 5; page++) {
        UIScrollView *pageScroll = [self makePage:page];
        [_pager addSubview:pageScroll];
        [NSLayoutConstraint activateConstraints:@[
            [pageScroll.topAnchor constraintEqualToAnchor:_pager.contentLayoutGuide.topAnchor],
            [pageScroll.bottomAnchor constraintEqualToAnchor:_pager.contentLayoutGuide.bottomAnchor],
            [pageScroll.widthAnchor constraintEqualToAnchor:_pager.frameLayoutGuide.widthAnchor],
            [pageScroll.heightAnchor constraintEqualToAnchor:_pager.frameLayoutGuide.heightAnchor],
            [pageScroll.leadingAnchor constraintEqualToAnchor:previous
                                                                  ? previous.trailingAnchor
                                                                  : _pager.contentLayoutGuide.leadingAnchor]
        ]];
        previous = pageScroll;
    }
    [previous.trailingAnchor constraintEqualToAnchor:_pager.contentLayoutGuide.trailingAnchor].active = YES;
}
- (UIScrollView *)makePage:(NSInteger)page {
    NSArray<NSString *> *titles = @[
        @"今天，\n想做点什么？", @"把世界风味，\n端上餐桌", @"搜一道菜，\n跟着步骤做",
        @"这一周，\n吃得有计划", @"准备好，开饭啦"
    ];
    NSArray<NSString *> *subtitles = @[
        @"和小狗厨师一起，\n把每一天，做得有滋有味。", @"按国家、口味与菜系探索，\n找到今天想尝试的那一味。",
        @"先看需要什么食材，\n再跟着清晰步骤，一步步开做。",
        @"安排一周菜单，整理所需食材，\n让每天吃什么，提前有答案。",
        @"从第一道想做的菜开始，\n发现属于你的好味道。"
    ];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    scroll.directionalLockEnabled = YES;
    scroll.accessibilityIdentifier = [NSString stringWithFormat:@"welcome.page.%ld", (long)page + 1];
    UIStackView *stack = QFStack(UILayoutConstraintAxisVertical, 0);
    [scroll addSubview:stack];
    QFWelcomeArtView *art = [[QFWelcomeArtView alloc] initWithPage:page];
    [stack addArrangedSubview:art];
    [art.heightAnchor constraintEqualToAnchor:art.widthAnchor].active = YES;
    [stack addArrangedSubview:QFSpacer(24)];
    UILabel *title = QFLabel(titles[page], page == 4 ? 28 : 29, UIFontWeightBold, QFText());
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:QFSpacer(14)];
    UILabel *subtitle = QFLabel(subtitles[page], 14, UIFontWeightRegular, QFSecondary());
    subtitle.numberOfLines = 0;
    subtitle.textAlignment = NSTextAlignmentCenter;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineSpacing = 6;
    subtitle.attributedText =
        [[NSAttributedString alloc] initWithString:subtitles[page]
                                        attributes:@{
                                            NSFontAttributeName : subtitle.font,
                                            NSForegroundColorAttributeName : QFSecondary(),
                                            NSParagraphStyleAttributeName : paragraph
                                        }];
    [stack addArrangedSubview:subtitle];
    [stack addArrangedSubview:QFSpacer(26)];
    UIView *indicators = [UIView new];
    indicators.translatesAutoresizingMaskIntoConstraints = NO;
    [indicators.heightAnchor constraintEqualToConstant:28].active = YES;
    UIStackView *dots = QFStack(UILayoutConstraintAxisHorizontal, 5);
    [indicators addSubview:dots];
    [NSLayoutConstraint activateConstraints:@[
        [dots.centerXAnchor constraintEqualToAnchor:indicators.centerXAnchor],
        [dots.topAnchor constraintEqualToAnchor:indicators.topAnchor],
        [dots.bottomAnchor constraintEqualToAnchor:indicators.bottomAnchor]
    ]];
    for (NSInteger index = 0; index < 5; index++) {
        UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        dot.tag = index;
        dot.accessibilityLabel = [NSString stringWithFormat:@"第 %ld 页，共 5 页", (long)index + 1];
        dot.accessibilityTraits = UIAccessibilityTraitButton |
                                  (index == page ? UIAccessibilityTraitSelected : UIAccessibilityTraitNone);
        [dot.widthAnchor constraintEqualToConstant:31].active = YES;
        UIView *pill = QFArtShape(index == page ? QFOrange() : QFHex(0xD8DDD2), 3);
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.userInteractionEnabled = NO;
        [dot addSubview:pill];
        [NSLayoutConstraint activateConstraints:@[
            [pill.centerXAnchor constraintEqualToAnchor:dot.centerXAnchor],
            [pill.centerYAnchor constraintEqualToAnchor:dot.centerYAnchor],
            [pill.widthAnchor constraintEqualToConstant:index == page ? 24 : 6],
            [pill.heightAnchor constraintEqualToConstant:6]
        ]];
        [dot addTarget:self action:@selector(pageDotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [dots addArrangedSubview:dot];
    }
    [stack addArrangedSubview:indicators];
    if (page == 0) {
        [stack addArrangedSubview:QFSpacer(37)];
        UILabel *hint = QFLabel(@"左右滑动，继续了解", 12, UIFontWeightRegular, QFSecondary());
        hint.textAlignment = NSTextAlignmentCenter;
        [stack addArrangedSubview:hint];
    } else if (page == 4) {
        [stack addArrangedSubview:QFSpacer(29)];
        UIButton *enter = QFButton(@"进入 APP", 17, UIColor.whiteColor);
        enter.backgroundColor = QFOrange();
        enter.layer.cornerRadius = 17;
        enter.accessibilityIdentifier = @"welcome.enter";
        [enter.heightAnchor constraintEqualToConstant:55].active = YES;
        [enter addTarget:self action:@selector(requestEntry) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:enter];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:17],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-30],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    return scroll;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.pager.bounds);
    if (width > 0 && fabs(width - self.lastPageWidth) > 0.5) {
        self.lastPageWidth = width;
        [self.pager setContentOffset:CGPointMake(width * self.selectedPage, 0) animated:NO];
    }
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self updateSelectedPage];
    }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self updateSelectedPage];
}
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    [self updateSelectedPage];
}
- (void)updateSelectedPage {
    CGFloat width = CGRectGetWidth(self.pager.bounds);
    if (width <= 0)
        return;
    self.selectedPage = MAX(0, MIN(4, (NSInteger)llround(self.pager.contentOffset.x / width)));
    self.pager.accessibilityValue =
        [NSString stringWithFormat:@"第 %ld 页，共 5 页", (long)self.selectedPage + 1];
}
- (void)pageDotTapped:(UIButton *)sender {
    self.selectedPage = sender.tag;
    [self.pager setContentOffset:CGPointMake(sender.tag * CGRectGetWidth(self.pager.bounds), 0)
                        animated:!UIAccessibilityIsReduceMotionEnabled()];
    self.pager.accessibilityValue =
        [NSString stringWithFormat:@"第 %ld 页，共 5 页", (long)self.selectedPage + 1];
}
- (void)requestEntry {
    if (self.presentedViewController || self.completed)
        return;
    QFSafetyNoticeViewController *notice = [QFSafetyNoticeViewController new];
    notice.agreementChecked = NO;
    __weak typeof(self) weakSelf = self;
    notice.onContinue = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.completed)
            return;
        self.completed = YES;
        [self dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled()
                                 completion:^{
                                     if (self.onCompleted)
                                         self.onCompleted();
                                 }];
    };
    notice.onDecline = ^{
        [weakSelf dismissViewControllerAnimated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
    };
    [self presentViewController:notice animated:!UIAccessibilityIsReduceMotionEnabled() completion:nil];
}
@end
