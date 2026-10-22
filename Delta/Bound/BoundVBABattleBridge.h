#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Paused core or completed-frame owner only. Network callbacks never access RAM.
@interface BoundVBABattleBridge : NSObject
/// Thread-safe battery admission fence. Blocked paths remain blocked until
/// explicitly authorized, including after their core has stopped or unbound.
+ (BOOL)setROMGameSaveAllowed:(BOOL)allowed forURL:(NSURL *)url NS_SWIFT_NAME(setROMGameSaveAllowed(_:for:));
+ (BOOL)installROMMultiplayer;
+ (NSData *)romMultiplayerSnapshot;
+ (void)setROMMultiplayerHost:(NSData *)data;
+ (BOOL)installSharedWorld;
+ (NSDictionary<NSString *,id> *)sharedWorldSnapshot;
+ (void)setSharedWorldPeer:(NSData *)flags group:(NSUInteger)group number:(NSUInteger)number boulders:(NSData *)boulders fresh:(BOOL)fresh;
+ (void)advanceSharedWorld;
+ (void)closeSharedWorld;
+ (void)resetFriendDialogueOwner;
+ (BOOL)friendDialogueReady;
+ (BOOL)beginFriendDialogue:(NSUInteger)mode text:(NSString *)text;
+ (void)cancelFriendDialogue;
+ (NSDictionary<NSString *,id> *)advanceFriendDialogue;
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
+ (NSData *)qaSharedWorldImmutableDigest;
+ (BOOL)qaStartSharedWorldWait;
+ (BOOL)qaStartSharedWorldSightlineWait;
+ (BOOL)qaPrepareNuggetBridgeFixture;
+ (BOOL)qaWarpNuggetBridge:(NSUInteger)y;
+ (NSDictionary<NSString *,id> *)qaNuggetBridgeStatus;
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
