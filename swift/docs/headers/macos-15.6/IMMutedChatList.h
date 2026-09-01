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
// Image: /System/Library/PrivateFrameworks/IMSharedUtilities.framework/Versions/A/IMSharedUtilities
// Image source: dyld_shared_cache (arm64e)

@interface IMMutedChatList : NSObject

@property (readonly, nonatomic) NSDictionary * mutedChatList;+(id)sharedList;
-(BOOL)isMutedChat:(id)arg1;
-(void)muteChat:(id)arg1 untilDate:(id)arg2;
-(void)muteChat:(id)arg1 untilDate:(id)arg2 syncToPairedDevice:(BOOL)arg3;
-(id)muteIdentifiersForChat:(id)arg1;
-(id)unmuteDateForChat:(id)arg1;
-(void)dealloc;
-(id)init;
-(void)_handleChatGroupIDChangedNotification:(id)arg1;
-(void)_handleMutedChatListChanged;
-(void)_synchronizeMutedChatList:(id)arg1 syncToPairedDevice:(BOOL)arg2;
-(id)groupHashForParticipantIDs:(id)arg1 lastAddressedHandleID:(id)arg2;
-(void)groupID:(id)arg1 didChangeTo:(id)arg2 forChatIdentifier:(id)arg3;
-(BOOL)isMutedChatForChatIdentifier:(id)arg1 chatStyle:(unsigned char)arg2 groupID:(id)arg3 participantIDs:(id)arg4 lastAddressedHandleID:(id)arg5 originalGroupID:(id)arg6;
-(BOOL)isMutedChatForMuteIdentifiers:(id)arg1;
-(void)muteChatWithMuteIdentifiers:(id)arg1 untilDate:(id)arg2 syncToPairedDevice:(BOOL)arg3;
-(id)muteIdentifiersForChatStyle:(unsigned char)arg1 groupID:(id)arg2 participantIDs:(id)arg3 lastAddressedHandleID:(id)arg4 originalGroupID:(id)arg5 chatIdentifier:(id)arg6;
-(id)mutedChatList;
-(void)syncToPairedDeviceIncludingVersion:(BOOL)arg1;
-(void)unmuteChatWithMuteIdentifiers:(id)arg1 syncToPairedDevice:(BOOL)arg2;
-(id)unmuteDateForMuteIdentifier:(id)arg1;
-(id)unmuteDateForMuteIdentifiers:(id)arg1;
@end
