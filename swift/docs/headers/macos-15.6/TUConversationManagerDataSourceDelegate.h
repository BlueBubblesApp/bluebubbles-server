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

#import <TelephonyUtilities/NSObject-Protocol.h>

@protocol TUConversationManagerDataSourceDelegate <NSObject>

@required
-(void)activeParticipant:(id)arg1 addedHighlightToConversation:(id)arg2 highlightIdentifier:(id)arg3 oldHighlightIdentifier:(id)arg4 isFirstAdd:(BOOL)arg5;
-(void)activeParticipant:(id)arg1 removedHighlightFromConversation:(id)arg2 highlightIdentifier:(id)arg3;
-(void)activityAuthorizationsChangedForDataSource:(id)arg1 oldActivityAuthorizedBundleIdentifiers:(id)arg2;
-(void)addedCollaborationDictionary:(id)arg1 forConversation:(id)arg2;
-(void)conversation:(id)arg1 addedMembersLocally:(id)arg2;
-(void)conversation:(id)arg1 buzzedMember:(id)arg2;
-(void)conversation:(id)arg1 collaborationStateChanged:(long long)arg2 highlightIdentifier:(id)arg3;
-(void)conversation:(id)arg1 didChangeSceneAssociationForActivitySession:(id)arg2;
-(void)conversation:(id)arg1 didChangeStateForActivitySession:(id)arg2;
-(void)conversation:(id)arg1 participant:(id)arg2 addedNotice:(id)arg3;
-(void)conversation:(id)arg1 receivedActivitySessionEvent:(id)arg2;
-(void)conversation:(id)arg1 screenSharingChangedForParticipant:(id)arg2;
-(void)conversationManagerDataSource:(id)arg1 conversation:(id)arg2 appLaunchState:(unsigned long long)arg3 forActivitySession:(id)arg4;
-(void)conversationManagerDataSource:(id)arg1 didChangeActivatedConversationLinks:(id)arg2;
-(void)conversationManagerDataSource:(id)arg1 messagesGroupDetailsForMessagesGroupId:(id)arg2 completionHandler:(void (^)(void))arg3;
-(void)conversationUpdatedMessagesGroupPhoto:(id)arg1;
-(void)conversationsChangedForDataSource:(id)arg1 conversationsByGroupUUID:(id)arg2 oldConversationsByGroupUUID:(id)arg3;
-(void)conversationsChangedForDataSource:(id)arg1 updatedIncomingPendingConversationsByGroupUUID:(id)arg2;
-(void)receivedTrackedPendingMember:(id)arg1 forConversationLink:(id)arg2;
-(void)remoteScreenShareAttributesChanged:(id)arg1 isLocallySharing:(BOOL)arg2;
-(void)remoteScreenShareEndedWithReason:(id)arg1;
-(void)screenSharingAvailableChanged:(BOOL)arg1;
-(void)serverDisconnectedForDataSource:(id)arg1 oldConversationsByGroupUUID:(id)arg2;
-(void)sharePlayAvailableChanged:(BOOL)arg1;
@end
