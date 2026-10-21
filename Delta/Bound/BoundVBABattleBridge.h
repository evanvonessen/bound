#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Paused core or completed-frame owner only. Network callbacks never access RAM.
@interface BoundVBABattleBridge : NSObject
+ (BOOL)verifyBattleReady;
+ (BOOL)prepareBattleForPlayer:(NSUInteger)player;
+ (BOOL)prepareTradeForPlayer:(NSUInteger)player;
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
+ (BOOL)installSoulLink;
+ (BOOL)setSoulLinkDenied:(NSData *)identities;
+ (NSDictionary<NSString *,id> *)soulLinkSnapshot;
+ (void)acknowledgeSoulLinkFaints;
+ (void)enforceSoulLink;
+ (void)closeSoulLink;
#if DEBUG && TARGET_OS_SIMULATOR
+ (BOOL)qaStartSoulCheck;
+ (BOOL)qaStartSoulCatch:(NSUInteger)mode;
+ (NSArray<NSNumber *> *)qaSoulCheckResult;
+ (void)qaFinishSoulCheck;
+ (BOOL)qaPrepareTradeFixture:(NSUInteger)marker;
+ (NSData *)qaTradeParty;
+ (NSDictionary<NSString *, id> *)qaTradeMenu;
#endif
@end
NS_ASSUME_NONNULL_END
