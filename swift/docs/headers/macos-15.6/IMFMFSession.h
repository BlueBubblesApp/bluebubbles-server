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
// Image: /System/Library/PrivateFrameworks/IMCore.framework/Versions/A/IMCore
// Image source: dyld_shared_cache (arm64e)

#import <IMCore/FMFSessionDelegate-Protocol.h>

@interface IMFMFSession : NSObject <FMFSessionDelegate> {

	FMFSession *_session;
	IMFindMyDevice *_activeDevice;
	NSString *_establishingAccountID;
	id _fmlSession;
	unsigned long long _fmfProvisionedState;
}
@property (retain, nonatomic) IMFindMyDevice * activeDevice;
@property (retain, nonatomic) FMFSession * session;
@property (retain, nonatomic) id fmlSession;
@property (retain, nonatomic) NSString * establishingAccountID;
@property (nonatomic, assign) unsigned long long fmfProvisionedState;
@property (readonly, nonatomic) BOOL restrictLocationSharing;
@property (readonly, nonatomic) BOOL disableLocationSharing;
@property (readonly) unsigned long long hash;
@property (readonly) Class superclass;
@property (readonly, copy) NSString * description;
@property (readonly, copy) NSString * debugDescription;
+(id)sharedInstance;
-(void)dealloc;
-(id)init;
-(id)session;
-(void)setSession:(id)arg1;
-(void)didChangeActiveLocationSharingDevice:(id)arg1;
-(void)didReceiveLocation:(id)arg1;
-(void)didStartAbilityToGetLocationForHandle:(id)arg1;
-(void)didStartSharingMyLocationWithHandle:(id)arg1;
-(void)didStopAbilityToGetLocationForHandle:(id)arg1;
-(void)didStopSharingMyLocationWithHandle:(id)arg1;
-(void)didUpdateHidingStatus:(BOOL)arg1;
-(void)sendMappingPacket:(id)arg1 toHandle:(id)arg2;
-(id)_accountStore;
-(void)_accountStoreDidChangeNotification:(id)arg1;
-(void)_postRelationshipStatusDidChangeNotificationWithIMFindMyHandle:(id)arg1;
-(id)allSiblingFindMyHandlesForChat:(id)arg1;
-(id)fmfGroupIdGroup;
-(void)startTrackingLocationForHandle:(id)arg1;
-(Class)__FMFSessionClass;
-(Class)__FMLSessionClass;
-(id)_bestAccountForAddresses:(id)arg1;
-(id)_callerIDForChat:(id)arg1;
-(BOOL)_canShareLocationWithFMLHandle:(id)arg1 isFromGroup:(BOOL)arg2;
-(void)_configureFindMyLocateSession;
-(id)_dateFromShareDuration:(long long)arg1;
-(void)_initializeFindMySessionIfInAllowedProcess;
-(void)_postNotification:(id)arg1 object:(id)arg2 userInfo:(id)arg3;
-(void)_setUpFindMyLocateSessionCallbacks;
-(void)_startFMLSessionMonitoring;
-(void)_startRefreshingLocationForFMLHandles:(id)arg1 priority:(long long)arg2 isFromGroup:(BOOL)arg3;
-(void)_startSharingWithFMFHandles:(id)arg1 inChat:(id)arg2 untilDate:(id)arg3;
-(void)_startSharingWithFMLHandles:(id)arg1 inChat:(id)arg2 withDuration:(long long)arg3;
-(void)_stopSharingWithFMFHandles:(id)arg1 inChat:(id)arg2;
-(void)_stopSharingWithFMLHandles:(id)arg1 inChat:(id)arg2;
-(void)_stopTrackingLocationForFMLHandles:(id)arg1 priority:(long long)arg2 isFromGroup:(BOOL)arg3;
-(void)_updateActiveDevice;
-(id)activeDevice;
-(BOOL)allChatParticipantsFollowingMyLocation:(id)arg1;
-(BOOL)allChatParticipantsSharingLocationWithMe:(id)arg1;
-(BOOL)chatHasParticipantsFollowingMyLocation:(id)arg1;
-(BOOL)chatHasParticipantsSharingLocationWithMe:(id)arg1;
-(BOOL)chatHasSiblingParticipantsSharingLocationWithMe:(id)arg1;
-(void)didReceiveLocationForHandle:(id)arg1;
-(BOOL)disableLocationSharing;
-(id)establishingAccountID;
-(BOOL)findMyHandleIsFollowingMyLocation:(id)arg1;
-(BOOL)findMyHandleIsSharingLocationWithMe:(id)arg1;
-(id)findMyHandlesForChat:(id)arg1;
-(id)findMyHandlesSharingLocationWithMe;
-(id)findMyLocationForFindMyHandle:(id)arg1;
-(id)findMyLocationForHandle:(id)arg1;
-(id)findMyLocationForHandleOrSibling:(id)arg1;
-(id)findMyURLForChat:(id)arg1;
-(id)fmfGroupIdOneToOne;
-(unsigned long long)fmfProvisionedState;
-(id)fmlSession;
-(void)friendshipRequestReceived:(id)arg1;
-(void)friendshipWasRemoved:(id)arg1;
-(BOOL)handleIsFollowingMyLocation:(id)arg1;
-(BOOL)handleIsSharingLocationWithMe:(id)arg1;
-(BOOL)imIsProvisionedForLocationSharing;
-(void)makeThisDeviceActiveDevice;
-(void)refreshLocationForChat:(id)arg1;
-(void)refreshLocationForHandle:(id)arg1 inChat:(id)arg2;
-(BOOL)restrictLocationSharing;
-(void)setActiveDevice:(id)arg1;
-(void)setEstablishingAccountID:(id)arg1;
-(void)setFmfProvisionedState:(unsigned long long)arg1;
-(void)setFmlSession:(id)arg1;
-(void)startSharingWithChat:(id)arg1 withDuration:(long long)arg2;
-(void)startSharingWithHandle:(id)arg1 inChat:(id)arg2 withDuration:(long long)arg3;
-(void)startTrackingLocationForChat:(id)arg1;
-(void)stopSharingWithChat:(id)arg1;
-(void)stopSharingWithHandle:(id)arg1 inChat:(id)arg2;
-(void)stopTrackingLocationForChat:(id)arg1;
-(void)stopTrackingLocationForHandle:(id)arg1;
-(id)timedOfferExpirationForChat:(id)arg1;
@end
