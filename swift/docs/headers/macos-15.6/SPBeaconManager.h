// macOS 15.6 (Sequoia, build 24G84).
//
// NOT produced by swift/Tools/private-api. Third-party class-dump of the shipping binaries,
// transcribed from developer.limneos.net. It differs from macos-26.5.2/ in two ways that
// change how it reads — see docs/headers/README.md, "macOS 15.6 is a borrowed dump":
//   - read from the Mach-O in the dyld shared cache, not from the Objective-C runtime
//   - the NATIVE macOS framework, not the /System/iOSSupport (Catalyst) copy that
//     Messages.app loads
// Superseded by Tools/private-api/dump-headers.sh run on macOS 15.
//
// Dumped with classdump-dyld 3.0 on 2026-03-25, arm64e Macmini9,1.
//
// Image: /System/Library/PrivateFrameworks/SPOwner.framework/Versions/A/SPOwner
// Image source: dyld_shared_cache (arm64e)

@interface SPBeaconManager : NSObject {

	void (^_nearbyTokensChangedBlockWithCompletion)(void);
	FMXPCServiceDescription *_serviceDescription;
	FMXPCSession *_session;
	FMXPCServiceDescription *_userAgentServiceDescription;
	FMXPCSession *_userAgentSession;
	id<SPBeaconManagerXPCProtocol> *_proxy;
	id<SPBeaconManagerXPCProtocol> *_userAgentProxy;
	NSObject<OS_dispatch_queue> *_queue;
	SPBeaconManagerSimpleBeaconUpdateInterface *_simpleBeaconUpdateInterface;
	SPLocalBeaconManager *_localBeaconingManager;
}
@property (retain, nonatomic) FMXPCServiceDescription * serviceDescription;
@property (retain, nonatomic) FMXPCSession * session;
@property (retain, nonatomic) FMXPCServiceDescription * userAgentServiceDescription;
@property (retain, nonatomic) FMXPCSession * userAgentSession;
@property (retain, nonatomic) id<SPBeaconManagerXPCProtocol> * proxy;
@property (retain, nonatomic) id<SPBeaconManagerXPCProtocol> * userAgentProxy;
@property (retain, nonatomic) NSObject<OS_dispatch_queue> * queue;
@property (retain, nonatomic) SPBeaconManagerSimpleBeaconUpdateInterface * simpleBeaconUpdateInterface;
@property (retain, nonatomic) SPLocalBeaconManager * localBeaconingManager;
@property (copy, nonatomic) void (^)(void) stateChangedBlockWithCompletion;
@property (copy, nonatomic) void (^)(void) statusChangedBlockWithCompletion;
@property (copy, nonatomic) void (^)(void) beaconingKeyChangedBlockWithCompletion;
@property (copy, nonatomic) void (^)(void) nearbyTokensChangedBlockWithCompletion;
-(void)dealloc;
-(id)init;
-(void)invalidate;
-(id)queue;
-(void)setQueue:(id)arg1;
-(void)start;
-(id)session;
-(id)proxy;
-(void)setSession:(id)arg1;
-(id)remoteInterface;
-(void)setProxy:(id)arg1;
-(id)serviceDescription;
-(void)setServiceDescription:(id)arg1;
-(void)setBeaconingKeyChangedBlockWithCompletion:(void (^)(void))arg1;
-(void)setNearbyTokensChangedBlockWithCompletion:(void (^)(void))arg1;
-(void)setStateChangedBlockWithCompletion:(void (^)(void))arg1;
-(void)setStatusChangedBlockWithCompletion:(void (^)(void))arg1;
-(void)setSimpleBeaconUpdateInterface:(id)arg1;
-(void (^)(void))stateChangedBlockWithCompletion;
-(void)setUserAgentServiceDescription:(id)arg1;
-(void)allBeaconingKeysForUUID:(id)arg1 dateInterval:(id)arg2 forceGenerate:(BOOL)arg3 completion:(void (^)(void))arg4;
-(void)allBeaconsOfType:(id)arg1 completion:(void (^)(void))arg2;
-(void)allBeaconsOfTypes:(id)arg1 completion:(void (^)(void))arg2;
-(void)allBeaconsOfTypes:(id)arg1 includeDupes:(BOOL)arg2 includeHidden:(BOOL)arg3 completion:(void (^)(void))arg4;
-(void)allBeaconsWithCompletion:(void (^)(void))arg1;
-(void)allDuriansWithCompletion:(void (^)(void))arg1;
-(void)beaconForUUID:(id)arg1 completion:(void (^)(void))arg2;
-(void (^)(void))beaconingKeyChangedBlockWithCompletion;
-(void)beaconingKeysForUUID:(id)arg1 dateInterval:(id)arg2 completion:(void (^)(void))arg3;
-(void)connectedToBeacon:(id)arg1 withIndex:(unsigned long long)arg2;
-(void)connectedToBeacon:(id)arg1 withIndex:(unsigned long long)arg2 completion:(void (^)(void))arg3;
-(void)connectionTokensForBeaconUUID:(id)arg1 completion:(void (^)(void))arg2;
-(void)connectionTokensForBeaconUUID:(id)arg1 criteria:(id)arg2 completion:(void (^)(void))arg3;
-(void)connectionTokensForBeaconUUID:(id)arg1 dateInterval:(id)arg2 completion:(void (^)(void))arg3;
-(void)createDuplicateBeaconsForBeacon:(id)arg1 skipGroupIdentifier:(BOOL)arg2 count:(long long)arg3 completion:(void (^)(void))arg4;
-(void)createKeyReconcilerWithCompletion:(void (^)(void))arg1;
-(void)createOwnedDeviceKeyRecordForUUID:(id)arg1 completion:(void (^)(void))arg2;
-(void)fetchFirmwareVersionForBeacon:(id)arg1 completion:(void (^)(void))arg2;
-(void)fetchKeyMapFileDescriptorForBeacon:(id)arg1 completion:(void (^)(void))arg2;
-(void)fetchUserStatsForBeacon:(id)arg1 completion:(void (^)(void))arg2;
-(void)isLPEMModeSupported:(void (^)(void))arg1;
-(void)keySyncMetadataWithcompletion:(void (^)(void))arg1;
-(id)localBeaconingManager;
-(void (^)(void))nearbyTokensChangedBlockWithCompletion;
-(void)notificationBeaconForSubscriptionId:(id)arg1 completion:(void (^)(void))arg2;
-(void)ownedDeviceKeyRecordsForUUID:(id)arg1 completion:(void (^)(void))arg2;
-(void)postedLocalNotifyWhenFoundNotificationForUUID:(id)arg1 completion:(void (^)(void))arg2;
-(void)purgeOwnedDeviceKeyRecordsForUUID:(id)arg1 completion:(void (^)(void))arg2;
-(void)removeDuplicateBeaconsWithCompletion:(void (^)(void))arg1;
-(void)repairDataStore:(void (^)(void))arg1;
-(void)roleCategoriesWithCompletion:(void (^)(void))arg1;
-(void)setAlignmentUncertainty:(double)arg1 atIndex:(unsigned long long)arg2 date:(id)arg3 forBeacon:(id)arg4 completion:(void (^)(void))arg5;
-(void)setCurrentWildKeyIndex:(long long)arg1 forBeacon:(id)arg2 completion:(void (^)(void))arg3;
-(void)setKeyRollInterval:(unsigned long long)arg1 forBeacon:(id)arg2 completion:(void (^)(void))arg3;
-(void)setLocalBeaconingManager:(id)arg1;
-(void)setRole:(long long)arg1 forBeacon:(id)arg2 completion:(void (^)(void))arg3;
-(void)setSuppressLPEMBeaconing:(BOOL)arg1 completion:(void (^)(void))arg2;
-(void)setUserAgentProxy:(id)arg1;
-(void)setUserAgentSession:(id)arg1;
-(void)setUserHasAcknowledgedFindMy:(BOOL)arg1 completion:(void (^)(void))arg2;
-(void)setWildKeyBase:(unsigned long long)arg1 interval:(unsigned long long)arg2 fallback:(unsigned long long)arg3 forBeacon:(id)arg4 completion:(void (^)(void))arg5;
-(id)simpleBeaconUpdateInterface;
-(void)startUpdatingSimpleBeaconsWithContext:(id)arg1 collectionDifference:(void (^)(void))arg2 completion:(void (^)(void))arg3;
-(void (^)(void))statusChangedBlockWithCompletion;
-(void)stopUpdatingSimpleBeaconsWithCompletion:(void (^)(void))arg1;
-(void)submitDeviceEvent:(id)arg1 source:(unsigned int)arg2 attachedTo:(id)arg3 completion:(void (^)(void))arg4;
-(void)unacceptedBeaconsWithCompletion:(void (^)(void))arg1;
-(void)updateBeacon:(id)arg1 updates:(id)arg2 completion:(void (^)(void))arg3;
-(void)updateObfuscatedIdentifierWithCompletion:(void (^)(void))arg1;
-(id)userAgentProxy;
-(id)userAgentServiceDescription;
-(id)userAgentSession;
-(void)userHasAcknowledgeFindMyWithCompletion:(void (^)(void))arg1;
@end
