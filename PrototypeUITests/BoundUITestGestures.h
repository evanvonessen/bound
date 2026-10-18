#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// XCTest-only touch synthesis; never linked into the application target.
@interface BoundUITestGestures : NSObject
+ (BOOL)swipeWithStart:(CGPoint)start deltaY:(CGFloat)deltaY orientation:(NSInteger)orientation screenSize:(CGSize)screenSize error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
