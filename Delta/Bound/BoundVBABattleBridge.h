#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Paused core or completed-frame owner only. Network callbacks never access RAM.
@interface BoundVBABattleBridge : NSObject
+ (BOOL)verifyBattleReady;
+ (BOOL)prepareBattleForPlayer:(NSUInteger)player;
+ (BOOL)installBattleForPlayer:(NSUInteger)player;
+ (NSData *)takeOutgoingCommands;
+ (NSUInteger)connectionGeneration;
+ (void)requestPeerDisconnect;
+ (NSData *)peerAcknowledgement;
+ (void)acknowledgeGeneration:(NSUInteger)generation sequence:(NSUInteger)sequence;
+ (void)setPeerGeneration:(NSUInteger)generation;
+ (NSUInteger)receiveCommands:(NSData *)data;
+ (BOOL)isInBattle;
+ (NSArray<NSNumber *> *)playerHP;
+ (NSDictionary<NSString *, id> *)advanceAndObserve;
+ (void)close;
@end
NS_ASSUME_NONNULL_END
