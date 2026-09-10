#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Local UI choice only. This is neither an authentication credential nor a legal signing record.
@interface QFLoginConsentStore : NSObject
+ (BOOL)isAgreementChecked;
+ (void)setAgreementChecked:(BOOL)checked;
@end

@interface QFAgreementView : UIView
@property (nonatomic) BOOL checked;
@property (nonatomic, copy, nullable) void (^onChanged)(BOOL checked);
@property (nonatomic, copy, nullable) void (^onReadDocument)(NSString *title);
- (instancetype)initWithNoticeStyle:(BOOL)noticeStyle identifier:(NSString *)identifier;
@end

@interface QFSafetyNoticeViewController : UIViewController
@property (nonatomic) BOOL agreementChecked;
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(BOOL checked);
@property (nonatomic, copy, nullable) void (^onContinue)(void);
@property (nonatomic, copy, nullable) void (^onDecline)(void);
@end

void QFPresentAgreementDocument(UIViewController *presenter, NSString *title);

NS_ASSUME_NONNULL_END
