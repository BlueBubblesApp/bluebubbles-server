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

#import <TelephonyUtilities/NSCopying-Protocol.h>
#import <TelephonyUtilities/NSSecureCoding-Protocol.h>

@interface TUConversationLink : NSObject <NSCopying, NSSecureCoding> {

	BOOL _locallyCreated;
	NSString *_pseudonym;
	NSData *_publicKey;
	NSDate *_creationDate;
	NSDate *_deletionDate;
	NSUUID *_groupUUID;
	TUHandle *_originatorHandle;
	long long _linkLifetimeScope;
	long long _deleteReason;
	NSString *_URLFragment;
	NSString *_linkName;
	NSDate *_expirationDate;
	NSSet *_invitedMemberHandles;
}
@property (retain, nonatomic) NSDate * creationDate;
@property (retain, nonatomic) NSDate * deletionDate;
@property (retain, nonatomic) NSUUID * groupUUID;
@property (nonatomic, getter=, assign) BOOL locallyCreated;
@property (retain, nonatomic) TUHandle * originatorHandle;
@property (copy, nonatomic) NSString * pseudonym;
@property (copy, nonatomic) NSData * publicKey;
@property (nonatomic, assign) long long linkLifetimeScope;
@property (nonatomic, assign) long long deleteReason;
@property (retain, nonatomic) NSString * URLFragment;
@property (copy, nonatomic) NSString * linkName;
@property (readonly, copy, nonatomic) NSString * displayName;
@property (retain, nonatomic) NSDate * expirationDate;
@property (copy, nonatomic) NSSet * invitedMemberHandles;
@property (readonly, nonatomic) NSURL * URL;
+(BOOL)supportsSecureCoding;
+(id)featureFlags;
+(id)baseURLs;
+(id)baseURLStrings;
+(id)baseURLComponentsForURL:(id)arg1;
+(BOOL)checkMatchingConversationLinkCriteriaForURL:(id)arg1;
+(id)conversationLinkComponentsFromURL:(id)arg1;
+(id)conversationLinkForURL:(id)arg1;
+(unsigned long long)conversationLinkVersion;
+(id)preferredBaseURL;
+(id)preferredBaseURLString;
+(id)prefixedPseudonymFor:(id)arg1;
+(id)publicKeyForBase64EncodedString:(id)arg1;
+(id)userConfiguration;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)URL;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(void)setGroupUUID:(id)arg1;
-(id)displayName;
-(id)valueForKey:(id)arg1;
-(id)expirationDate;
-(void)setExpirationDate:(id)arg1;
-(id)creationDate;
-(id)publicKey;
-(void)setPublicKey:(id)arg1;
-(void)setCreationDate:(id)arg1;
-(id)initWithDescriptor:(id)arg1;
-(id)linkName;
-(void)setLinkName:(id)arg1;
-(id)pseudonym;
-(id)groupUUID;
-(id)deletionDate;
-(void)setDeletionDate:(id)arg1;
-(BOOL)isEquivalentToConversationLink:(id)arg1;
-(void)setURLFragment:(id)arg1;
-(id)base64PublicKey;
-(id)URLFragment;
-(BOOL)allInvitedMembersInContactsChecking:(id)arg1;
-(BOOL)canCreateConversations;
-(long long)deleteReason;
-(id)fetchedResults;
-(id)generateDisplayName;
-(id)initWithPseudonym:(id)arg1 publicKey:(id)arg2 groupUUID:(id)arg3 originatorHandle:(id)arg4;
-(id)initWithPseudonym:(id)arg1 publicKey:(id)arg2 groupUUID:(id)arg3 originatorHandle:(id)arg4 creationDate:(id)arg5 deletionDate:(id)arg6 expirationDate:(id)arg7 invitedMemberHandles:(id)arg8 locallyCreated:(BOOL)arg9 linkName:(id)arg10 linkLifetimeScope:(long long)arg11 deleteReason:(long long)arg12;
-(id)invitedMemberHandles;
-(BOOL)isEqualToConversationLink:(id)arg1;
-(BOOL)isEquivalentToPseudonym:(id)arg1 andPublicKey:(id)arg2;
-(BOOL)isLocallyCreated;
-(long long)linkLifetimeScope;
-(id)originatorHandle;
-(void)setDeleteReason:(long long)arg1;
-(void)setInvitedMemberHandles:(id)arg1;
-(void)setLinkLifetimeScope:(long long)arg1;
-(void)setLocallyCreated:(BOOL)arg1;
-(void)setOriginatorHandle:(id)arg1;
-(void)setPseudonym:(id)arg1;
-(id)unprefixedPseudonym;
@end
