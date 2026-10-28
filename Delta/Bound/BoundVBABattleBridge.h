#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Paused core or completed-frame owner only. Network callbacks never access RAM.
@interface BoundVBABattleBridge : NSObject
/// Thread-safe battery admission fence. Blocked paths remain blocked until
/// explicitly authorized, including after their core has stopped or unbound.
+ (BOOL)setROMGameSaveAllowed:(BOOL)allowed forURL:(NSURL *)url NS_SWIFT_NAME(setROMGameSaveAllowed(_:for:));
/// Call before creating/binding a GBA core. Server-only games never read or
/// write persistent battery/state files, including at core start and stop.
+ (BOOL)setServerOnlyGameSave:(BOOL)enabled forURL:(NSURL *)url NS_SWIFT_NAME(setServerOnlyGameSave(_:for:));
/// Paused core or completed-frame owner only; these functions perform no I/O.
+ (NSData *)captureServerState;
+ (BOOL)restoreServerState:(NSData *)data;
+ (NSData *)captureServerBattery;
+ (BOOL)restoreServerBattery:(NSData *)data;
/// Attaches to the resident cartridge co-op ABI; gameplay code is never installed by this adapter.
+ (BOOL)installCooperativeDoubles;
+ (BOOL)setCooperativeGameSaveAllowed:(BOOL)allowed forURL:(NSURL *)url NS_SWIFT_NAME(setCooperativeGameSaveAllowed(_:for:));
+ (NSData *)cooperativeSnapshot;
+ (void)setCooperativeHost:(NSData *)data;
/// The existing reliable native command cable, without friendly entry/return hooks.
+ (BOOL)prepareCooperativeCableForPlayer:(NSUInteger)player;
+ (void)closeCooperativeCable;
+ (BOOL)resumeCooperativeCableForPlayer:(NSUInteger)player;
+ (NSData *)cooperativeCableSnapshot;
/// Exact paused cable continuation. Restore after the matching core state and cooperative host block.
+ (NSData *)captureCooperativeSession;
+ (BOOL)restoreCooperativeSession:(NSData *)data;
+ (BOOL)installROMMultiplayer;
+ (void)advanceROMFieldRecovery;
+ (NSData *)romMultiplayerSnapshot;
+ (void)setROMMultiplayerHost:(NSData *)data;
+ (NSInteger)linksMenuPageOffset;
+ (void)setLinksMenuHost:(NSData *)data;
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
+ (BOOL)verifyBattleEntryReady;
+ (BOOL)prepareBattleForPlayer:(NSUInteger)player;
+ (BOOL)prepareTradeForPlayer:(NSUInteger)player;
+ (BOOL)installBattleForPlayer:(NSUInteger)player;
+ (void)configureDecisionsWithSeed:(NSUInteger)seed;
+ (NSData *)takeOutgoingDecisions;
+ (NSUInteger)receiveDecisions:(NSData *)data;
/// Paused core only. Restore after its matching native state, without re-entering the battle or trade.
+ (NSData *)captureNativeSession;
+ (BOOL)restoreNativeSession:(NSData *)data;
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
+ (BOOL)setSoulLinkEliminated:(NSData *)bits;
+ (BOOL)usesAcceptedSoulFaints;
+ (BOOL)setSoulLinkAcquired:(NSData *)bits;
+ (NSDictionary<NSString *,id> *)soulLinkSnapshot;
+ (void)acknowledgeSoulLinkFaints;
+ (BOOL)acknowledgeSoulLinkFaintsMatching:(NSData *)identities;
+ (BOOL)acknowledgeSoulLinkAcquisitionsMatching:(NSData *)receipts;
/// Bound-owned admission fence. Load epochs prevent a stale owner from fencing
/// a replacement cartridge even when native allocations reuse an address.
+ (NSUInteger)claimSoulFrameOwner:(NSString *)owner gameURL:(NSURL *)url;
+ (BOOL)setSoulFrameBlocked:(BOOL)blocked owner:(NSString *)owner generation:(NSUInteger)generation;
+ (BOOL)isSoulFrameBlockedForOwner:(NSString *)owner generation:(NSUInteger)generation;
+ (void)enforceSoulLink;
+ (void)closeSoulLink;
#if DEBUG && TARGET_OS_SIMULATOR
+ (NSData *)qaLinksMenuHost;
+ (NSData *)qaEliminationPolicy;
+ (NSDictionary<NSString *,id> *)qaUncachedSoulLinkSnapshot;
+ (NSDictionary<NSString *,id> *)qaSoulBoxCacheChecks;
+ (NSDictionary<NSString *,id> *)qaSoulFaintAcknowledgementChecks;
+ (BOOL)qaStartNativePartyFixture;
+ (BOOL)qaConfigureBattleParty:(NSUInteger)mode;
+ (NSDictionary<NSString *,id> *)qaBattleMenu;
+ (BOOL)qaCooperativeGameSaveBlocked:(NSURL *)url;
+ (NSData *)qaSharedWorldImmutableDigest;
+ (BOOL)qaStartSharedWorldWait;
+ (BOOL)qaStartSharedWorldSightlineWait;
+ (BOOL)qaPrepareNuggetBridgeFixture;
+ (BOOL)qaWarpNuggetBridge:(NSUInteger)y;
+ (BOOL)qaWarpPalletEntrance;
+ (BOOL)qaWarpViridianMartEntrance;
+ (BOOL)qaStopMapMusicRetainingTracks;
+ (BOOL)qaStartMusicPauseText;
+ (BOOL)qaHideMusicPauseText;
+ (NSDictionary<NSString *,id> *)qaFieldMusicStatus;
+ (void)qaSetLegacyFieldTextAdmission:(BOOL)enabled;
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
#if DEBUG && TARGET_OS_SIMULATOR
@interface BoundVBABattleBridge (DebugFixtureOperations)
/// Test-owned paused core/frame owner only. Fixed pre-Brock native recipes:
/// 1=Mankey8 on Route1; 2=21 Rare Candy on Route1; 3=Pikachu8 on Route2.
/// Native Bag/learning UI must consume the candies; no stat/EXP/move writes.
+ (NSDictionary<NSString *,id> *)qaDebugFixturePreflight;
+ (BOOL)qaResetDebugFixtureOperations;
/// Restore only host bookkeeping for the exact audited Route1 gift basis.
+ (BOOL)qaAdmitRoute1FixtureContinuation;
+ (BOOL)qaBeginDebugFixtureOperation:(NSUInteger)operation;
+ (NSDictionary<NSString *,id> *)qaAdvanceDebugFixtureOperation;
@end
#endif
NS_ASSUME_NONNULL_END
