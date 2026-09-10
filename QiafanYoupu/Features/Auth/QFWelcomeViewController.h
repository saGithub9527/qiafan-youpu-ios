#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface QFWelcomeViewController : UIViewController
@property (nonatomic, copy, nullable) void (^onCompleted)(void);
@end
NS_ASSUME_NONNULL_END
