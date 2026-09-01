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
// Image: /System/Library/PrivateFrameworks/TelephonyUtilities.framework/Versions/A/TelephonyUtilities
// Image source: dyld_shared_cache (arm64e)

#import <TelephonyUtilities/TUConversationManagerXPCClient-Protocol.h>
#import <TelephonyUtilities/TUConversationManagerDataSource-Protocol.h>

@interface TUConversationManagerXPCClient : NSObject <TUConversationManagerXPCClient, TUConversationManagerDataSource> {

	BOOL _autoSharePlayEnabled;
	BOOL _hasRequestedInitialState;
	BOOL _hasInitialState;
	BOOL _shouldConnectToHost;
	struct os_unfair_lock_s _accessorLock;
	int _shouldConnectToken;
	id<TUConversationManagerDataSourceDelegate> *_delegate;
	id<TUConversationMediaControllerDataSourceDelegate> *_mediaDelegate;
	id<TUConversationReactionsControllerDataSourceDelegate> *_reactionsDelegate;
	NSXPCConnection *_xpcConnection;
	NSObject<OS_dispatch_queue> *_queue;
	NSDictionary *_conversationsByGroupUUID;
	NSDictionary *_activityAuthorizedBundleIdentifiers;
	NSNumber *_sharePlayAvailable;
	NSNumber *_screenSharingAvailable;
	id<TUScreenSharingRemoteControlProviderDelegate> *_remoteControlProviderDelegate;
}
@property (readonly, nonatomic) struct os_unfair_lock_s accessorLock;
@property (readonly, nonatomic) NSObject<OS_dispatch_queue> * queue;
@property (retain, nonatomic) NSXPCConnection * xpcConnection;
@property (nonatomic, assign) BOOL hasRequestedInitialState;
@property (nonatomic, assign) BOOL hasInitialState;
@property (nonatomic, assign) int shouldConnectToken;
@property (nonatomic, assign) BOOL shouldConnectToHost;
@property (copy, nonatomic) NSDictionary * conversationsByGroupUUID;
@property (copy, nonatomic) NSDictionary * activityAuthorizedBundleIdentifiers;
@property (copy, nonatomic) NSNumber * sharePlayAvailable;
@property (copy, nonatomic) NSNumber * screenSharingAvailable;
@property (__weak, nonatomic, assign) id<TUScreenSharingRemoteControlProviderDelegate> * remoteControlProviderDelegate;
@property (readonly) unsigned long long hash;
@property (readonly) Class superclass;
@property (readonly, copy) NSString * description;
@property (readonly, copy) NSString * debugDescription;
@property (readonly, copy, nonatomic) NSDictionary * incomingPendingConversationsByGroupUUID;
@property (readonly, copy, nonatomic) NSDictionary * pseudonymsByCallUUID;
@property (readonly, copy, nonatomic) NSSet * activatedConversationLinks;
@property (nonatomic, assign) BOOL autoSharePlayEnabled;
@property (readonly, nonatomic) BOOL isSharePlayAvailable;
@property (readonly, nonatomic) BOOL isScreenSharingAvailable;
@property (__weak, nonatomic, assign) id<TUConversationManagerDataSourceDelegate> * delegate;
@property (__weak, nonatomic, assign) id<TUConversationMediaControllerDataSourceDelegate> * mediaDelegate;
@property (__weak, nonatomic, assign) id<TUConversationReactionsControllerDataSourceDelegate> * reactionsDelegate;
+(id)asynchronousServer;
+(id)conversationManagerAllowedClasses;
+(id)conversationManagerClientXPCInterface;
+(id)conversationManagerServerXPCInterface;
+(void)setAsynchronousServer:(id)arg1;
+(void)setSynchronousServer:(id)arg1;
+(id)synchronousServer;
-(void)dealloc;
-(id)init;
-(id)delegate;
-(void)invalidate;
-(void)setDelegate:(id)arg1;
-(id)queue;
-(void)setXpcConnection:(id)arg1;
-(id)xpcConnection;
-(BOOL)isSharePlayAvailable;
-(void)_requestInitialStateIfNecessary;
-(void)activateLink:(id)arg1 completionHandler:(void (^)(void))arg2;
-(BOOL)hasInitialState;
-(void)requestScreenSharingPickerForConversationUUID:(id)arg1 withContentStyle:(long long)arg2;
-(void)updateConversationsByGroupUUID:(id)arg1;
-(void)_invokeCompletionHandler:(void (^)(void))arg1;
-(void)_requestInitialStateWithCompletionHandler:(void (^)(void))arg1;
-(struct os_unfair_lock_s)accessorLock;
-(void)activateConversationNoticeWithActionURL:(id)arg1 bundleIdentifier:(id)arg2;
-(id)activatedConversationLinks;
-(void)activeParticipant:(id)arg1 addedHighlightToConversation:(id)arg2 highlightIdentifier:(id)arg3 oldHighlightIdentifier:(id)arg4 isFirstAdd:(BOOL)arg5;
-(void)activeParticipant:(id)arg1 removedHighlightFromConversation:(id)arg2 highlightIdentifier:(id)arg3;
-(id)activityAuthorizedBundleIdentifiers;
-(void)addCollaborationDictionary:(id)arg1 forConversationWithUUID:(id)arg2 fromMe:(BOOL)arg3;
-(void)addCollaborationIdentifier:(id)arg1 collaborationURL:(id)arg2 cloudKitAppBundleIDs:(id)arg3 forConversationUUID:(id)arg4;
-(void)addDisclosedCollaborationInitiator:(id)arg1 toConversationUUID:(id)arg2;
-(void)addInvitedMemberHandles:(id)arg1 toConversationLink:(id)arg2 completionHandler:(void (^)(void))arg3;
-(void)addRemoteMembers:(id)arg1 otherInvitedHandles:(id)arg2 toConversation:(id)arg3;
-(void)addRemoteMembers:(id)arg1 toConversation:(id)arg2;
-(void)addScreenSharingType:(unsigned long long)arg1 forConversation:(id)arg2;
-(void)addedCollaborationDictionary:(id)arg1 forConversation:(id)arg2;
-(void)approvePendingMember:(id)arg1 forConversation:(id)arg2;
-(id)asynchronousServerWithErrorHandler:(void (^)(void))arg1;
-(BOOL)autoSharePlayEnabled;
-(void)buzzMember:(id)arg1 conversation:(id)arg2;
-(void)cancelOrDenyScreenShareRequest:(id)arg1 forConversation:(id)arg2;
-(void)checkLinkValidity:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)clientInvalidatedWithBundleIdentifier:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)conversation:(id)arg1 addedMembersLocally:(id)arg2;
-(void)conversation:(id)arg1 appLaunchState:(unsigned long long)arg2 forActivitySession:(id)arg3;
-(void)conversation:(id)arg1 buzzedMember:(id)arg2;
-(void)conversation:(id)arg1 collaborationStateChanged:(long long)arg2 highlightIdentifier:(id)arg3;
-(void)conversation:(id)arg1 didChangeSceneAssociationForActivitySession:(id)arg2;
-(void)conversation:(id)arg1 didChangeStateForActivitySession:(id)arg2;
-(void)conversation:(id)arg1 participant:(id)arg2 addedNotice:(id)arg3;
-(void)conversation:(id)arg1 participant:(id)arg2 didReact:(id)arg3;
-(void)conversation:(id)arg1 participantDidStopReacting:(id)arg2;
-(void)conversation:(id)arg1 receivedActivitySessionEvent:(id)arg2;
-(void)conversation:(id)arg1 screenSharingChangedForParticipant:(id)arg2;
-(void)conversationUpdateMessagesGroupPhoto:(id)arg1;
-(void)conversationUpdatedMessagesGroupPhoto:(id)arg1;
-(id)conversationsByGroupUUID;
-(void)createActivitySession:(id)arg1 onConversation:(id)arg2;
-(void)endActivitySession:(id)arg1 onConversation:(id)arg2;
-(void)fetchInitialStateWithCompletionHandler:(void (^)(void))arg1;
-(void)fetchUpcomingNoticeWithCompletionHandler:(void (^)(void))arg1;
-(void)generateLinkForConversation:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)generateLinkWithInvitedMemberHandles:(id)arg1 linkLifetimeScope:(long long)arg2 completionHandler:(void (^)(void))arg3;
-(void)getActiveLinksWithCreatedOnly:(BOOL)arg1 completionHandler:(void (^)(void))arg2;
-(void)getInactiveLinkWithCompletionHandler:(void (^)(void))arg1;
-(void)getLatestRemoteScreenShareAttributesWithCompletionHandler:(void (^)(void))arg1;
-(void)getMessagesGroupDetailsForConversationUUID:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)getMessagesGroupDetailsForMessagesGroupUUID:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)getNeedsDisclosureOfCollaborationInitiator:(id)arg1 forConversationUUID:(id)arg2 completionHandler:(void (^)(void))arg3;
-(void)handleServerDisconnect;
-(BOOL)hasRequestedInitialState;
-(id)incomingPendingConversationsByGroupUUID;
-(void)invalidateLink:(id)arg1 deleteReason:(long long)arg2 completionHandler:(void (^)(void))arg3;
-(BOOL)isScreenSharingAvailable;
-(void)joinConversationWithRequest:(id)arg1;
-(void)kickMember:(id)arg1 conversation:(id)arg2;
-(void)launchApplicationForActivitySessionUUID:(id)arg1 authorizedExternally:(BOOL)arg2 forceBackground:(BOOL)arg3 completionHandler:(void (^)(void))arg4;
-(void)leaveActivitySession:(id)arg1 onConversation:(id)arg2;
-(void)leaveConversationWithUUID:(id)arg1;
-(void)linkSyncStateIncludeLinks:(BOOL)arg1 WithCompletion:(void (^)(void))arg2;
-(void)markCollaborationWithIdentifierOpened:(id)arg1 forConversationUUID:(id)arg2;
-(id)mediaDelegate;
-(void)mediaPrioritiesChangedForConversation:(id)arg1;
-(void)participantsGrantedRemoteControlChanged:(id)arg1;
-(void)participantsRequestingRemoteControlChanged:(id)arg1;
-(void)prepareConversationWithUUID:(id)arg1 withHandoffContext:(id)arg2;
-(void)presentDismissalAlertForActivitySession:(id)arg1 onConversation:(id)arg2;
-(void)presenterAllowsRequestingControlChanged:(BOOL)arg1;
-(id)pseudonymsByCallUUID;
-(id)reactionsDelegate;
-(void)receivedTrackedPendingMember:(id)arg1 forConversationLink:(id)arg2;
-(void)refreshActiveConversations;
-(void)registerMessagesGroupUUIDForConversationUUID:(id)arg1;
-(void)registerWithCompletionHandler:(void (^)(void))arg1;
-(void)rejectPendingMember:(id)arg1 forConversation:(id)arg2;
-(void)relinquishControlWithCompletionHandler:(void (^)(void))arg1;
-(void)remoteControlClientSideCursorUpdated:(BOOL)arg1;
-(void)remoteControlDataReceivedFromPresenter:(id)arg1;
-(id)remoteControlProviderDelegate;
-(void)remoteControlProviderInvalidated;
-(void)remoteControlRevokedWithError:(id)arg1;
-(void)remoteControlStateChanged:(long long)arg1;
-(void)remoteScreenShareAttributesChanged:(id)arg1 isLocallySharing:(BOOL)arg2;
-(void)remoteScreenShareEndedWithReason:(id)arg1;
-(void)removeCollaborationIdentifier:(id)arg1 forConversationUUID:(id)arg2;
-(void)removeConversationNoticeWithUUID:(id)arg1;
-(void)renewLink:(id)arg1 expirationDate:(id)arg2 reason:(unsigned long long)arg3 completionHandler:(void (^)(void))arg4;
-(void)requestControlWithCompletionHandler:(void (^)(void))arg1;
-(void)requestParticipantToShareScreen:(id)arg1 forConversation:(id)arg2;
-(void)scheduleConversationLinkCheckInInitial:(BOOL)arg1;
-(id)screenSharingAvailable;
-(void)screenSharingAvailableChanged:(BOOL)arg1;
-(void)sendDataToPresenter:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)setActivityAllowsRequestingControl:(BOOL)arg1 completionHandler:(void (^)(void))arg2;
-(void)setActivityAuthorization:(BOOL)arg1 forBundleIdentifier:(id)arg2;
-(void)setActivityAuthorizedBundleIdentifiers:(id)arg1;
-(void)setAutoSharePlayEnabled:(BOOL)arg1;
-(void)setControlGranted:(BOOL)arg1 forParticipants:(id)arg2 completionHandler:(void (^)(void))arg3;
-(void)setConversationsByGroupUUID:(id)arg1;
-(void)setDownlinkMuted:(BOOL)arg1 forRemoteParticipantsInConversation:(id)arg2;
-(void)setGridDisplayMode:(unsigned long long)arg1 conversation:(id)arg2;
-(void)setHasInitialState:(BOOL)arg1;
-(void)setHasRequestedInitialState:(BOOL)arg1;
-(void)setIgnoreLetMeInRequests:(BOOL)arg1 forConversation:(id)arg2;
-(void)setLinkName:(id)arg1 forConversationLink:(id)arg2 completionHandler:(void (^)(void))arg3;
-(void)setLocalParticipantAudioVideoMode:(unsigned long long)arg1 forConversationUUID:(id)arg2;
-(void)setMediaDelegate:(id)arg1;
-(void)setPresenterAllowsRequestingControl:(BOOL)arg1 completionHandler:(void (^)(void))arg2;
-(void)setProviderDelegate:(id)arg1 completionHandler:(void (^)(void))arg2;
-(void)setReactionsDelegate:(id)arg1;
-(void)setRemoteControlProviderDelegate:(id)arg1;
-(void)setScreenEnabled:(BOOL)arg1 withScreenShareAttributes:(id)arg2 forConversationWithUUID:(id)arg3;
-(void)setScreenSharingAvailable:(id)arg1;
-(void)setSharePlayAvailable:(id)arg1;
-(void)setSharePlayHandedOff:(BOOL)arg1 onConversationWithUUID:(id)arg2;
-(void)setShouldConnectToHost:(BOOL)arg1;
-(void)setShouldConnectToken:(int)arg1;
-(void)setSupportsMessagesGroupProviding:(BOOL)arg1;
-(void)setUsingAirplay:(BOOL)arg1 onActivitySession:(id)arg2 onConversationWithUUID:(id)arg3;
-(id)sharePlayAvailable;
-(void)sharePlayAvailableChanged:(BOOL)arg1;
-(BOOL)shouldConnectToHost;
-(int)shouldConnectToken;
-(void)startTrackingCollaborationWithIdentifier:(id)arg1 collaborationURL:(id)arg2 cloudKitAppBundleIDs:(id)arg3 forConversationUUID:(id)arg4 completionHandler:(void (^)(void))arg5;
-(id)synchronousServerWithErrorHandler:(void (^)(void))arg1;
-(void)updateActivatedConversationLinks:(id)arg1;
-(void)updateActivityAuthorizedBundleIdentifierState:(id)arg1;
-(void)updateConversationWithUUID:(id)arg1 participantPresentationContexts:(id)arg2;
-(void)updateIncomingPendingConversationsByGroupUUID:(id)arg1;
-(void)updateLocalParticipantToAVLessWithPresentationMode:(unsigned long long)arg1 forConversationUUID:(id)arg2;
-(void)updateMessagesGroupName:(id)arg1 onConversation:(id)arg2;
@end
