#import "BoundUITestGestures.h"

// XCTest's public coordinate API cannot synthesize a three-finger drag.
// Resolve these test-runner classes dynamically so a missing API fails the test.
@interface NSObject (BoundPrivateTouchSynthesis)
- (id)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (id)initWithName:(NSString *)name interfaceOrientation:(NSInteger)orientation;
- (void)addPointerEventPath:(id)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end

@implementation BoundUITestGestures
+ (BOOL)swipeWithStart:(CGPoint)start deltaY:(CGFloat)deltaY orientation:(NSInteger)orientation screenSize:(CGSize)screenSize error:(NSError **)error {
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    if (!pathClass || !recordClass) {
        if (error) *error = [NSError errorWithDomain:@"BoundUITestGestures" code:1 userInfo:@{NSLocalizedDescriptionKey: @"XCTest touch synthesis is unavailable"}];
        return NO;
    }
    // XCPointerEventPath consumes fixed portrait-display coordinates, even
    // when XCTest exposes the app's frame in its current landscape orientation.
    CGPoint (^physical)(CGPoint) = ^CGPoint(CGPoint p) {
        if (orientation == 4) return CGPointMake(p.y, screenSize.width - p.x);
        if (orientation == 3) return CGPointMake(screenSize.height - p.y, p.x);
        return p;
    };
    id record = [[recordClass alloc] initWithName:@"Three-finger opacity swipe" interfaceOrientation:1];
    for (NSInteger finger = -1; finger <= 1; finger++) {
        CGPoint point = CGPointMake(start.x + finger * 28, start.y);
        id path = [[pathClass alloc] initForTouchAtPoint:physical(point) offset:0];
        for (NSInteger step = 1; step <= 8; step++) {
            [path moveToPoint:physical(CGPointMake(point.x, point.y + deltaY * step / 8.0)) atOffset:0.1 + step * 0.05];
        }
        [path liftUpAtOffset:0.6];
        [record addPointerEventPath:path];
    }
    return [record synthesizeWithError:error];
}
@end
