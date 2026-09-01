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

@interface TUConversationMember : NSObject <NSCopying, NSSecureCoding> {

	BOOL _isLightweightMember;
	BOOL _joinedFromLetMeIn;
	BOOL _isOtherInvitedHandle;
	TUHandle *_handle;
	NSString *_nickname;
	long long _validationSource;
	NSDate *_dateReceivedLetMeIn;
	NSDate *_dateInitiatedLetMeIn;
	TUHandle *_lightweightPrimary;
	unsigned long long _lightweightPrimaryParticipantIdentifier;
	TUConversationMemberAssociation *_association;
	TUVoucher *_associationVoucher;
}
@property (readonly, nonatomic) BOOL needsContactLookupForDisplayName;
@property (readonly, copy, nonatomic) NSString * idsFromID;
@property (readonly, copy, nonatomic) NSString * idsDestination;
@property (copy, nonatomic) NSString * nickname;
@property (nonatomic, assign) BOOL joinedFromLetMeIn;
@property (nonatomic, assign) BOOL isOtherInvitedHandle;
@property (nonatomic, assign) long long validationSource;
@property (copy, nonatomic) TUConversationMemberAssociation * association;
@property (retain, nonatomic) TUVoucher * associationVoucher;
@property (readonly, copy, nonatomic) NSArray * idsDestinations;
@property (readonly, nonatomic) TUHandle * handle;
@property (readonly, nonatomic, getter=) BOOL validated;
@property (nonatomic, assign) BOOL isSplitSessionMember;
@property (nonatomic, assign) BOOL isLightweightMember;
@property (retain, nonatomic) NSDate * dateReceivedLetMeIn;
@property (retain, nonatomic) NSDate * dateInitiatedLetMeIn;
@property (copy, nonatomic) TUHandle * splitSessionPrimary;
@property (copy, nonatomic) TUHandle * lightweightPrimary;
@property (nonatomic, assign) unsigned long long lightweightPrimaryParticipantIdentifier;
@property (readonly, copy, nonatomic) NSSet * handles;
+(BOOL)supportsSecureCoding;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)nickname;
-(void)setNickname:(id)arg1;
-(id)handle;
-(id)handles;
-(id)initWithHandle:(id)arg1;
-(BOOL)pseudonym;
-(id)initWithDestinations:(id)arg1;
-(id)initWithContact:(id)arg1;
-(id)initWithHandles:(id)arg1;
-(id)initWithDestination:(id)arg1;
-(id)idsDestination;
-(id)idsDestinations;
-(void)setAssociation:(id)arg1;
-(id)association;
-(id)associationVoucher;
-(id)dateInitiatedLetMeIn;
-(id)dateReceivedLetMeIn;
-(id)idsFromID;
-(id)initWithContact:(id)arg1 additionalHandles:(id)arg2;
-(id)initWithHandle:(id)arg1 nickname:(id)arg2;
-(id)initWithHandle:(id)arg1 nickname:(id)arg2 joinedFromLetMeIn:(BOOL)arg3;
-(BOOL)isEqualToMember:(id)arg1;
-(BOOL)isLightweightMember;
-(BOOL)isOtherInvitedHandle;
-(BOOL)isSplitSessionMember;
-(BOOL)isValidated;
-(BOOL)joinedFromLetMeIn;
-(id)lightweightPrimary;
-(unsigned long long)lightweightPrimaryParticipantIdentifier;
-(BOOL)needsContactLookupForDisplayName;
-(BOOL)representsSameMemberAs:(id)arg1;
-(void)setAssociationVoucher:(id)arg1;
-(void)setDateInitiatedLetMeIn:(id)arg1;
-(void)setDateReceivedLetMeIn:(id)arg1;
-(void)setIsLightweightMember:(BOOL)arg1;
-(void)setIsOtherInvitedHandle:(BOOL)arg1;
-(void)setIsSplitSessionMember:(BOOL)arg1;
-(void)setJoinedFromLetMeIn:(BOOL)arg1;
-(void)setLightweightPrimary:(id)arg1;
-(void)setLightweightPrimaryParticipantIdentifier:(unsigned long long)arg1;
-(void)setSplitSessionPrimary:(id)arg1;
-(void)setValidationSource:(long long)arg1;
-(id)splitSessionPrimary;
-(long long)validationSource;
@end
