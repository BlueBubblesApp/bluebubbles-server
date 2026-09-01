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

@interface TUConversationLinkDescriptor : NSObject <NSCopying, NSSecureCoding> {

	BOOL _activated;
	int _version;
	NSDate *_creationDate;
	NSDate *_deletionDate;
	NSDate *_expirationDate;
	long long _linkLifetimeScope;
	long long _deleteReason;
	NSUUID *_groupUUID;
	NSSet *_invitedHandles;
	NSString *_name;
	TUConversationLinkOriginator *_originator;
	NSData *_privateKey;
	NSString *_pseudonym;
	NSData *_publicKey;
}
@property (nonatomic, getter=, assign) BOOL activated;
@property (retain, nonatomic) NSDate * creationDate;
@property (retain, nonatomic) NSDate * deletionDate;
@property (retain, nonatomic) NSDate * expirationDate;
@property (retain, nonatomic) NSUUID * groupUUID;
@property (copy, nonatomic) NSSet * invitedHandles;
@property (copy, nonatomic) NSString * name;
@property (retain, nonatomic) TUConversationLinkOriginator * originator;
@property (copy, nonatomic) NSData * privateKey;
@property (copy, nonatomic) NSString * pseudonym;
@property (copy, nonatomic) NSData * publicKey;
@property (nonatomic, assign) int version;
@property (nonatomic, assign) long long linkLifetimeScope;
@property (nonatomic, assign) long long deleteReason;
+(BOOL)supportsSecureCoding;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)mutableCopyWithZone:(struct _NSZone *)arg1;
-(id)name;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(void)setGroupUUID:(id)arg1;
-(void)setName:(id)arg1;
-(int)version;
-(id)expirationDate;
-(void)setExpirationDate:(id)arg1;
-(void)setVersion:(int)arg1;
-(id)creationDate;
-(id)privateKey;
-(id)publicKey;
-(void)setPrivateKey:(id)arg1;
-(void)setPublicKey:(id)arg1;
-(void)setCreationDate:(id)arg1;
-(id)originator;
-(void)setOriginator:(id)arg1;
-(BOOL)isActivated;
-(id)invitedHandles;
-(id)pseudonym;
-(void)setInvitedHandles:(id)arg1;
-(id)groupUUID;
-(void)setActivated:(BOOL)arg1;
-(id)deletionDate;
-(void)setDeletionDate:(id)arg1;
-(long long)deleteReason;
-(id)initWithConversationLinkDescriptor:(id)arg1;
-(id)initWithGroupUUID:(id)arg1 originator:(id)arg2 pseudonym:(id)arg3 publicKey:(id)arg4;
-(BOOL)isEqualToConversationLinkDescriptor:(id)arg1;
-(long long)linkLifetimeScope;
-(void)setDeleteReason:(long long)arg1;
-(void)setLinkLifetimeScope:(long long)arg1;
-(void)setPseudonym:(id)arg1;
@end
