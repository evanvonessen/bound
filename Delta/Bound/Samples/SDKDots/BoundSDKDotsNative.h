#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Exact homebrew adapter ports. Call only while the owning core is paused.
/// Installation is explicit and preserves the existing bridge IMP chain.
@interface BoundSDKDotsNative : NSObject
+ (BOOL)installObserver;
+ (uint64_t)claimOwner:(NSString *)owner gameURL:(NSURL *)url audioRenderer:(id)audio videoRenderer:(id)video NS_SWIFT_NAME(claim(owner:gameURL:audioRenderer:videoRenderer:));
+ (nullable NSData *)readSnapshotForOwner:(NSString *)owner generation:(uint64_t)generation NS_SWIFT_NAME(read(owner:generation:));
+ (BOOL)publishHost:(NSData *)host owner:(NSString *)owner generation:(uint64_t)generation NS_SWIFT_NAME(publish(_:owner:generation:));
+ (void)releaseOwner:(NSString *)owner generation:(uint64_t)generation NS_SWIFT_NAME(release(owner:generation:));
@end
NS_ASSUME_NONNULL_END
