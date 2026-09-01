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
// Image: /System/Library/PrivateFrameworks/FMF.framework/Versions/A/FMF
// Image source: dyld_shared_cache (arm64e)

#import <FMF/NSCopying-Protocol.h>
#import <FMF/NSSecureCoding-Protocol.h>

@interface FMFHandle : NSObject <NSCopying, NSSecureCoding> {

	BOOL _isFamilyMember;
	BOOL _pending;
	BOOL _reachable;
	NSString *_identifier;
	NSString *_serverId;
	NSNumber *_dsid;
	NSArray *_aliasServerIds;
	NSArray *_invitationSentToIds;
	NSDictionary *_expiresByGroupId;
	NSString *_hashedDSID;
	NSNumber *_trackingTimestamp;
	NSNumber *_favoriteOrder;
	NSString *__prettyNameInternal;
	long long _idsStatus;
	NSString *_qualifiedIdentifier;
	NSString *__idsCorrelationIdentifierInternal;
}
@property (copy) NSString * identifier;
@property (copy, nonatomic) NSString * serverId;
@property (copy, nonatomic) NSNumber * dsid;
@property (nonatomic, assign) BOOL isFamilyMember;
@property (copy, nonatomic) NSArray * aliasServerIds;
@property (copy, nonatomic) NSArray * invitationSentToIds;
@property (copy, nonatomic) NSDictionary * expiresByGroupId;
@property (copy, nonatomic) NSString * hashedDSID;
@property (getter=, assign) BOOL pending;
@property (copy) NSNumber * trackingTimestamp;
@property (copy, nonatomic) NSNumber * favoriteOrder;
@property (copy, nonatomic) NSString * _prettyNameInternal;
@property (assign) long long idsStatus;
@property (assign) BOOL reachable;
@property (copy) NSString * qualifiedIdentifier;
@property (copy, nonatomic) NSString * _idsCorrelationIdentifierInternal;
+(BOOL)supportsSecureCoding;
+(id)familyHandleWithId:(id)arg1 dsid:(id)arg2;
+(id)handleWithId:(id)arg1;
+(id)handleWithId:(id)arg1 serverId:(id)arg2;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)debugDescription;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)identifier;
-(id)initWithCoder:(id)arg1;
-(void)setIdentifier:(id)arg1;
-(id)dsid;
-(void)setDsid:(id)arg1;
-(BOOL)isPending;
-(void)setPending:(BOOL)arg1;
-(id)recordId;
-(id)sanitizePhoneNumber:(id)arg1;
-(BOOL)isPhoneNumber;
-(id)hashedDSID;
-(BOOL)isFamilyMember;
-(BOOL)reachable;
-(void)setReachable:(BOOL)arg1;
-(id)IDSRecipientFromHandle:(id)arg1;
-(id)_idsCorrelationIdentifierInternal;
-(id)_prettyNameInternal;
-(void)abPreferencesDidChange;
-(void)addressBookDidChange;
-(id)aliasServerIds;
-(id)cachedPrettyName;
-(void)clearFavoriteOrder;
-(id)comparisonIdentifier;
-(void)correlationIdentifierForHandle:(id)arg1 withCompletion:(void (^)(void))arg2;
-(id)expiresByGroupId;
-(id)favoriteOrder;
-(void)idsCorrelationIdentifierWithCompletion:(void (^)(void))arg1;
-(long long)idsStatus;
-(id)invitationSentToIds;
-(BOOL)isSharingThroughGroupId:(id)arg1;
-(id)prettyName;
-(long long)prettyNameCompare:(id)arg1;
-(void)prettyNameWithCompletion:(void (^)(void))arg1;
-(id)qualifiedIdentifier;
-(id)serverId;
-(void)setAliasServerIds:(id)arg1;
-(void)setExpiresByGroupId:(id)arg1;
-(void)setFavoriteOrder:(id)arg1;
-(void)setHashedDSID:(id)arg1;
-(void)setICloudId:(id)arg1;
-(void)setIdsStatus:(long long)arg1;
-(void)setInvitationSentToIds:(id)arg1;
-(void)setIsFamilyMember:(BOOL)arg1;
-(void)setQualifiedIdentifier:(id)arg1;
-(void)setServerId:(id)arg1;
-(void)setTrackingTimestamp:(id)arg1;
-(void)set_idsCorrelationIdentifierInternal:(id)arg1;
-(void)set_prettyNameInternal:(id)arg1;
-(id)trackingTimestamp;
@end
