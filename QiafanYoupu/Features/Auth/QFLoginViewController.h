#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface QFLoginViewController : UIViewController
@property (nonatomic, copy, nullable) void (^onClose)(void);
@end
NS_ASSUME_NONNULL_END
