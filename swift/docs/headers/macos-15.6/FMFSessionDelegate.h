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

#import <IMCore/NSObject-Protocol.h>

@protocol FMFSessionDelegate <NSObject>

@optional
-(void)connectionError:(id)arg1;
-(void)didChangeActiveLocationSharingDevice:(id)arg1;
-(void)didFailToFetchLocationForHandle:(id)arg1 withError:(id)arg2;
-(void)didFailToHandleMappingPacket:(id)arg1 error:(id)arg2;
-(void)didReceiveFriendshipRequest:(id)arg1;
-(void)didReceiveLocation:(id)arg1;
-(void)didReceiveServerError:(id)arg1;
-(void)didStartAbilityToGetLocationForHandle:(id)arg1;
-(void)didStartSharingMyLocationWithHandle:(id)arg1;
-(void)didStopAbilityToGetLocationForHandle:(id)arg1;
-(void)didStopSharingMyLocationWithHandle:(id)arg1;
-(void)didUpdateActiveDeviceList:(id)arg1;
-(void)didUpdateFavoriteHandles:(id)arg1;
-(void)didUpdateFences:(id)arg1;
-(void)didUpdateHidingStatus:(BOOL)arg1;
-(void)didUpdatePendingOffersForHandles:(id)arg1;
-(void)didUpdatePreferences:(id)arg1;
-(void)mappingPacketProcessingCompleted:(id)arg1;
-(void)networkReachabilityUpdated:(BOOL)arg1;
-(void)sendMappingPacket:(id)arg1 toHandle:(id)arg2;
@end
