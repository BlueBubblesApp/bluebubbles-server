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
// Image: /System/Library/PrivateFrameworks/NotesShared.framework/Versions/A/NotesShared
// Image source: dyld_shared_cache (arm64e)

@interface ICInvitation : NSManagedObject {

	CKShare *_serverShare;
}
@property (copy, nonatomic) NSURL * shareURL;
@property (retain, nonatomic) ICAccount * account;
@property (retain, nonatomic) ICCloudSyncingObject * rootObject;
@property (copy, nonatomic) NSString * rootObjectType;
@property (copy, nonatomic) NSData * serverShareData;
@property (retain, nonatomic) CKShare * serverShare;
@property (copy, nonatomic) NSString * title;
@property (copy, nonatomic) NSDate * creationDate;
@property (copy, nonatomic) NSDate * modificationDate;
@property (copy, nonatomic) NSDate * receivedDate;
@property (copy, nonatomic) NSString * snippet;
@property (nonatomic, assign) short snippetAttachmentType;
@property (nonatomic, assign) long long snippetAttachmentCount;
@property (copy, nonatomic) NSData * thumbnailDataLight;
@property (copy, nonatomic) NSData * thumbnailDataDark;
@property (nonatomic, assign) long long noteCount;
@property (nonatomic, assign) long long noteCountRecursive;
@property (nonatomic, assign) long long subfolderCount;
@property (nonatomic, assign) long long subfolderCountRecursive;
+(id)invitationWithShareURL:(id)arg1 context:(id)arg2;
+(id)allInvitationsInContext:(id)arg1;
+(id)invitationsMatchingPredicate:(id)arg1 context:(id)arg2;
+(id)makeInvitationIfNeededWithShareURL:(id)arg1 account:(id)arg2 context:(id)arg3;
+(id)makeInvitationWithShareURL:(id)arg1 account:(id)arg2 context:(id)arg3;
+(id)predicateForPendingInvitationsInAccount:(id)arg1;
+(id)predicateForPendingInvitationsInAccount:(id)arg1 receivedSince:(id)arg2;
+(id)shareSystemFieldsTransformer;
-(void)setServerShare:(id)arg1;
-(id)serverShare;
@end
