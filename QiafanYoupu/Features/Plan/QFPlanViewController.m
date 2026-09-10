#import "QFPlanViewController.h"
@interface QFPlanViewController ()
@property (nonatomic, strong) NSCalendar *calendar;
@property (nonatomic, strong) NSDate *month;
@property (nonatomic, strong) NSDate *selectedDate;
@property (nonatomic, strong) UIStackView *calendarBody;
@property (nonatomic, strong) UILabel *monthTitle;
@property (nonatomic, strong) UILabel *dayTitle;
@property (nonatomic, strong) UIStackView *meals;
@property (nonatomic, strong) NSArray<UILabel *> *summaryLabels;
@end
@implementation QFPlanViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.accessibilityIdentifier = @"plan.screen";
    self.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    self.selectedDate = [self.calendar startOfDayForDate:NSDate.date];
    NSDateComponents *c = [self.calendar components:NSCalendarUnitYear | NSCalendarUnitMonth
                                           fromDate:self.selectedDate];
    self.month = [self.calendar dateFromComponents:c];
    UIStackView *header = QFStack(UILayoutConstraintAxisHorizontal, 8);
    header.alignment = UIStackViewAlignmentCenter;
    [header addArrangedSubview:QFLabel(@"饮食计划", 29, UIFontWeightSemibold, QFText())];
    UIButton *record = QFButton(@"做菜记录", 14, QFOrange());
    [header addArrangedSubview:record];
    __weak typeof(self) weakSelf = self;
    QFOnTap(record, ^{
        QFShowUnavailable(weakSelf, @"做菜记录");
    });
    [self.contentStack addArrangedSubview:header];
    UIView *calendarCard = QFCard();
    calendarCard.layer.borderWidth = 0.7;
    calendarCard.layer.borderColor = QFBorder().CGColor;
    UIStackView *calendarStack = QFStack(UILayoutConstraintAxisVertical, 8);
    QFPin(calendarStack, calendarCard, UIEdgeInsetsMake(10, 12, 10, 12));
    UIStackView *monthRow = QFStack(UILayoutConstraintAxisHorizontal, 0);
    monthRow.alignment = UIStackViewAlignmentCenter;
    UIButton *previous = QFIconButton(@"chevron.left", QFSecondary());
    previous.accessibilityLabel = @"上个月";
    UIButton *next = QFIconButton(@"chevron.right", QFSecondary());
    next.accessibilityLabel = @"下个月";
    self.monthTitle = QFLabel(@"", 20, UIFontWeightSemibold, QFText());
    self.monthTitle.textAlignment = NSTextAlignmentCenter;
    [monthRow addArrangedSubview:previous];
    [monthRow addArrangedSubview:self.monthTitle];
    [monthRow addArrangedSubview:next];
    QFOnTap(previous, ^{
        [weakSelf moveMonth:-1];
    });
    QFOnTap(next, ^{
        [weakSelf moveMonth:1];
    });
    [calendarStack addArrangedSubview:monthRow];
    UIStackView *week = QFStack(UILayoutConstraintAxisHorizontal, 0);
    week.distribution = UIStackViewDistributionFillEqually;
    for (NSString *day in @[ @"一", @"二", @"三", @"四", @"五", @"六", @"日" ]) {
        UILabel *label = QFLabel(day, 14, UIFontWeightRegular, QFSecondary());
        label.textAlignment = NSTextAlignmentCenter;
        [week addArrangedSubview:label];
    }
    [calendarStack addArrangedSubview:week];
    self.calendarBody = QFStack(UILayoutConstraintAxisVertical, 0);
    self.calendarBody.accessibilityIdentifier = @"plan.calendar";
    [calendarStack addArrangedSubview:self.calendarBody];
    UIStackView *legend = QFStack(UILayoutConstraintAxisHorizontal, 8);
    legend.alignment = UIStackViewAlignmentCenter;
    [legend
        addArrangedSubview:QFLabel(@"• 有做菜记录     ◦ 有待做计划", 11, UIFontWeightRegular, QFSecondary())];
    UIButton *today = QFButton(@"回到今天", 12, QFOrange());
    QFOnTap(today, ^{
        [weakSelf returnToToday];
    });
    [legend addArrangedSubview:today];
    [calendarStack addArrangedSubview:legend];
    [self.contentStack addArrangedSubview:calendarCard];
    UIView *summary = QFCard();
    summary.backgroundColor = QFPaleGreen();
    UIStackView *summaryRow = QFStack(UILayoutConstraintAxisHorizontal, 10);
    summaryRow.distribution = UIStackViewDistributionFillEqually;
    QFPin(summaryRow, summary, UIEdgeInsetsMake(13, 14, 13, 14));
    NSMutableArray *labels = [NSMutableArray array];
    for (NSString *title in @[ @"已完成", @"消耗成本", @"采购支出" ]) {
        UIStackView *column = QFStack(UILayoutConstraintAxisVertical, 4);
        [column addArrangedSubview:QFLabel(title, 12, UIFontWeightRegular, QFGreen())];
        UILabel *value = QFLabel(@"", 22, UIFontWeightSemibold, QFText());
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.7;
        [column addArrangedSubview:value];
        [labels addObject:value];
        [summaryRow addArrangedSubview:column];
    }
    self.summaryLabels = labels;
    [self.contentStack addArrangedSubview:summary];
    UIStackView *dayRow = QFStack(UILayoutConstraintAxisHorizontal, 8);
    dayRow.alignment = UIStackViewAlignmentCenter;
    [dayRow addArrangedSubview:QFLabel(@"当日计划", 21, UIFontWeightSemibold, QFText())];
    self.dayTitle = QFLabel(@"", 12, UIFontWeightRegular, QFSecondary());
    self.dayTitle.textAlignment = NSTextAlignmentRight;
    [dayRow addArrangedSubview:self.dayTitle];
    [self.contentStack addArrangedSubview:dayRow];
    self.meals = QFStack(UILayoutConstraintAxisVertical, 12);
    [self.contentStack addArrangedSubview:self.meals];
    [self installActions];
    [self renderCalendar];
    [self renderMeals];
}
- (void)installActions {
    self.scrollView.contentInset = UIEdgeInsetsMake(0, 0, 70, 0);
    self.scrollView.verticalScrollIndicatorInsets = self.scrollView.contentInset;
    UIView *bar = [UIView new];
    bar.backgroundColor = QFBackground();
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [bar.heightAnchor constraintEqualToConstant:62]
    ]];
    UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 10);
    row.distribution = UIStackViewDistributionFillEqually;
    QFPin(row, bar, UIEdgeInsetsMake(6, 20, 7, 20));
    UIButton *create = QFButton(@"制定计划", 18, UIColor.whiteColor);
    create.backgroundColor = QFOrange();
    create.layer.cornerRadius = 17;
    create.accessibilityIdentifier = @"plan.create";
    UIButton *prep = QFButton(@"备菜", 18, QFText());
    prep.backgroundColor = UIColor.whiteColor;
    prep.layer.cornerRadius = 17;
    prep.layer.borderWidth = 1;
    prep.layer.borderColor = QFBorder().CGColor;
    [row addArrangedSubview:create];
    [row addArrangedSubview:prep];
    __weak typeof(self) weakSelf = self;
    QFOnTap(create, ^{
        QFShowUnavailable(weakSelf, @"制定计划");
    });
    QFOnTap(prep, ^{
        QFShowUnavailable(weakSelf, @"备菜");
    });
}
- (void)moveMonth:(NSInteger)delta {
    self.month = [self.calendar dateByAddingUnit:NSCalendarUnitMonth value:delta toDate:self.month options:0];
    [self renderCalendar];
}
- (void)returnToToday {
    self.selectedDate = [self.calendar startOfDayForDate:NSDate.date];
    self.month =
        [self.calendar dateFromComponents:[self.calendar components:NSCalendarUnitYear | NSCalendarUnitMonth
                                                           fromDate:self.selectedDate]];
    [self renderCalendar];
    [self renderMeals];
}
- (void)renderCalendar {
    for (UIView *view in self.calendarBody.arrangedSubviews.copy) {
        [self.calendarBody removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSDateComponents *components =
        [self.calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitWeekday
                         fromDate:self.month];
    self.monthTitle.text =
        [NSString stringWithFormat:@"%ld年%ld月", (long)components.year, (long)components.month];
    NSInteger offset = (components.weekday + 5) % 7;
    NSInteger count =
        [self.calendar rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:self.month].length;
    NSInteger rows = (offset + count + 6) / 7;
    for (NSInteger r = 0; r < rows; r++) {
        UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 0);
        row.distribution = UIStackViewDistributionFillEqually;
        [row.heightAnchor constraintEqualToConstant:32].active = YES;
        for (NSInteger col = 0; col < 7; col++) {
            NSInteger d = r * 7 + col - offset + 1;
            UIView *cell = [UIView new];
            [row addArrangedSubview:cell];
            if (d < 1 || d > count)
                continue;
            NSDate *date = [self.calendar dateByAddingUnit:NSCalendarUnitDay
                                                     value:d - 1
                                                    toDate:self.month
                                                   options:0];
            BOOL selected = [self.calendar isDate:date inSameDayAsDate:self.selectedDate];
            UIButton *button = QFButton([NSString stringWithFormat:@"%ld", (long)d], 16,
                                        selected ? UIColor.whiteColor : QFText());
            button.backgroundColor = selected ? QFOrange() : UIColor.clearColor;
            button.layer.cornerRadius = 10;
            button.accessibilityLabel =
                [NSString stringWithFormat:@"%ld月%ld日", (long)components.month, (long)d];
            button.accessibilityTraits =
                UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
            QFPin(button, cell, UIEdgeInsetsMake(1, 3, 1, 3));
            __weak typeof(self) weakSelf = self;
            QFOnTap(button, ^{
                weakSelf.selectedDate = date;
                [weakSelf renderCalendar];
                [weakSelf renderMeals];
            });
        }
        [self.calendarBody addArrangedSubview:row];
    }
}
- (void)renderMeals {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"M月d日 · EEEE";
    self.dayTitle.text = [formatter stringFromDate:self.selectedDate];
    for (UIView *view in self.meals.arrangedSubviews.copy) {
        [self.meals removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    BOOL fixture = [self.calendar isDateInToday:self.selectedDate];
    NSArray *values = fixture ? @[ @"3 / 4 道", @"¥36.60", @"¥54.20" ] : @[ @"0 / 0 道", @"¥0.00", @"¥0.00" ];
    for (NSUInteger i = 0; i < 3; i++)
        self.summaryLabels[i].text = values[i];
    if (!fixture) {
        UIView *empty = QFCard();
        UILabel *label =
            QFLabel(@"当天还没有安排\n留一点期待，给下一餐", 15, UIFontWeightRegular, QFSecondary());
        label.textAlignment = NSTextAlignmentCenter;
        QFPin(label, empty, UIEdgeInsetsMake(32, 18, 32, 18));
        [self.meals addArrangedSubview:empty];
        return;
    }
    [self.meals addArrangedSubview:[self meal:@"早餐"
                                       detail:@"1道 · 已完成"
                                       dishes:@[ @[ @"鲜肉小笼包", @"dish-dimsum", @"消耗 ¥6.20", @YES ] ]]];
    [self.meals addArrangedSubview:[self meal:@"午餐"
                                       detail:@"3道 · 整餐打卡"
                                       dishes:@[
                                           @[ @"番茄炖牛腩", @"dish-stew", @"消耗 ¥26.80", @YES ],
                                           @[ @"清炒西兰花", @"dish-vegetables", @"消耗 ¥3.60", @YES ],
                                           @[ @"番茄鸡蛋汤", @"dish-soup", @"待完成", @NO ]
                                       ]]];
}
- (UIView *)meal:(NSString *)name detail:(NSString *)detail dishes:(NSArray<NSArray *> *)dishes {
    UIView *card = QFCard();
    card.layer.borderWidth = 0.7;
    card.layer.borderColor = QFBorder().CGColor;
    UIStackView *body = QFStack(UILayoutConstraintAxisVertical, 12);
    QFPin(body, card, UIEdgeInsetsMake(12, 14, 14, 14));
    UIStackView *header = QFStack(UILayoutConstraintAxisHorizontal, 8);
    header.alignment = UIStackViewAlignmentCenter;
    [header addArrangedSubview:QFLabel(name, 19, UIFontWeightSemibold, QFText())];
    UILabel *detailLabel =
        QFLabel(detail, 12, UIFontWeightRegular, [name isEqualToString:@"午餐"] ? QFOrange() : QFSecondary());
    detailLabel.textAlignment = NSTextAlignmentRight;
    [header addArrangedSubview:detailLabel];
    UIButton *more = QFButton(@"···", 18, QFSecondary());
    [more.widthAnchor constraintEqualToConstant:24].active = YES;
    [header addArrangedSubview:more];
    __weak typeof(self) weakSelf = self;
    QFOnTap(more, ^{
        QFShowUnavailable(weakSelf, @"调整当餐计划");
    });
    [body addArrangedSubview:header];
    for (NSArray *dish in dishes) {
        UIStackView *row = QFStack(UILayoutConstraintAxisHorizontal, 10);
        row.alignment = UIStackViewAlignmentCenter;
        UIImageView *image = QFImage(dish[1], UIViewContentModeScaleAspectFill);
        image.layer.cornerRadius = 12;
        [image.widthAnchor constraintEqualToConstant:48].active = YES;
        [image.heightAnchor constraintEqualToConstant:48].active = YES;
        [row addArrangedSubview:image];
        UIStackView *text = QFStack(UILayoutConstraintAxisVertical, 5);
        [text addArrangedSubview:QFLabel(dish[0], 16, UIFontWeightSemibold, QFText())];
        [text addArrangedSubview:QFLabel(dish[2], 12, UIFontWeightRegular, QFSecondary())];
        [row addArrangedSubview:text];
        BOOL done = [dish[3] boolValue];
        UIButton *check = QFButton(done ? @"✓ 已做" : @"做菜打卡", 12, done ? QFGreen() : QFOrange());
        check.backgroundColor = done ? QFPaleGreen() : QFHex(0xFFF0E7);
        check.layer.cornerRadius = 15;
        [check.widthAnchor constraintEqualToConstant:64].active = YES;
        [check.heightAnchor constraintEqualToConstant:30].active = YES;
        QFOnTap(check, ^{
            QFShowUnavailable(weakSelf, @"做菜打卡");
        });
        [row addArrangedSubview:check];
        [body addArrangedSubview:row];
    }
    return card;
}
@end
