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
// Image: /System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework/Versions/A/FindMyLocateObjCWrapper
// Image source: dyld_shared_cache (arm64e)

@interface FindMyLocateSession : NSObject {

	_TtC23FindMyLocateObjCWrapper13ObjCBootstrap *_trampoline;
}
@property (retain, nonatomic) _TtC23FindMyLocateObjCWrapper13ObjCBootstrap * trampoline;
@property (copy) void (^)(void) locationUpdateCallback;
@property (copy) void (^)(void) friendshipUpdateCallback;
@property (copy) void (^)(void) meDeviceUpdateCallback;
+(BOOL)FMFRestricted;
-(id)init;
-(id)cachedLocationForHandle:(id)arg1;
-(void)startMonitoringActiveLocationSharingDeviceChangeWithCompletion:(void (^)(void))arg1;
-(void)sendFriendshipOfferToHandles:(id)arg1 expiration:(long long)arg2 isFromGroup:(BOOL)arg3 completion:(void (^)(void))arg4;
-(long long)cachedCanShareLocationWithHandle:(id)arg1 isFromGroup:(BOOL)arg2;
-(id)cachedFriendsFollowingMyLocation;
-(id)cachedFriendsSharingLocationsWithMe;
-(id)cachedOfferExpirationForHandle:(id)arg1 groupId:(id)arg2;
-(void)getActiveLocationSharingDeviceWithCompletion:(void (^)(void))arg1;
-(void)getFriendsFollowingMyLocationWithCompletion:(void (^)(void))arg1;
-(void)getFriendsSharingLocationsWithMeWithCompletion:(void (^)(void))arg1;
-(void)setFriendshipUpdateCallback:(void (^)(void))arg1;
-(void)setLocationUpdateCallback:(void (^)(void))arg1;
-(void)setMeDeviceUpdateCallback:(void (^)(void))arg1;
-(void)startRefreshingLocationForHandles:(id)arg1 priority:(long long)arg2 isFromGroup:(BOOL)arg3 reverseGeocode:(BOOL)arg4 completion:(void (^)(void))arg5;
-(void)startUpdatingFriendsWithInitialUpdates:(BOOL)arg1 completion:(void (^)(void))arg2;
-(void)stopRefreshingLocationForHandles:(id)arg1 priority:(long long)arg2 isFromGroup:(BOOL)arg3 completion:(void (^)(void))arg4;
-(void)stopSharingLocationWith:(id)arg1 isFromGroup:(BOOL)arg2 completion:(void (^)(void))arg3;
-(void (^)(void))friendshipUpdateCallback;
-(void (^)(void))meDeviceUpdateCallback;
-(void)setActiveLocationSharingDevice:(id)arg1 completion:(void (^)(void))arg2;
-(id)cachedLocationForHandle:(id)arg1 includeAddress:(BOOL)arg2;
-(void)canShareLocationWithHandle:(id)arg1 isFromGroup:(BOOL)arg2 completion:(void (^)(void))arg3;
-(void)friendshipStateWithHandle:(id)arg1 isFromGroup:(BOOL)arg2 completion:(void (^)(void))arg3;
-(void)getOfferExpirationForHandle:(id)arg1 groupId:(id)arg2 completion:(void (^)(void))arg3;
-(void (^)(void))locationUpdateCallback;
-(void)sendFriendshipInviteToHandle:(id)arg1 from:(id)arg2 isFromGroup:(BOOL)arg3 completion:(void (^)(void))arg4;
-(void)sendFriendshipInviteToHandle:(id)arg1 isFromGroup:(BOOL)arg2 completion:(void (^)(void))arg3;
-(void)sendFriendshipOfferToHandles:(id)arg1 from:(id)arg2 expiration:(long long)arg3 isFromGroup:(BOOL)arg4 completion:(void (^)(void))arg5;
-(void)setTrampoline:(id)arg1;
-(void)startRefreshingLocationForHandles:(id)arg1 priority:(long long)arg2 isFromGroup:(BOOL)arg3 completion:(void (^)(void))arg4;
-(void)stopRefreshingLocationWithCompletion:(void (^)(void))arg1;
-(void)stopSharingLocationWith:(id)arg1 from:(id)arg2 isFromGroup:(BOOL)arg3 completion:(void (^)(void))arg4;
-(void)stopUpdatingFriendsWithCompletion:(void (^)(void))arg1;
-(id)trampoline;
@end
