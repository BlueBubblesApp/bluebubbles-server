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

@interface TUHandle : NSObject <NSCopying, NSSecureCoding> {

	BOOL _hasSetISOCountryCode;
	long long _type;
	NSString *_value;
	NSString *_siriDisplayName;
	NSString *_isoCountryCode;
	NSString *_normalizedValue;
}
@property (nonatomic, assign) BOOL hasSetISOCountryCode;
@property (copy, nonatomic) NSString * isoCountryCode;
@property (readonly, copy, nonatomic) NSString * normalizedValue;
@property (readonly, copy, nonatomic) NSDictionary * dictionaryRepresentation;
@property (nonatomic, assign) long long type;
@property (copy, nonatomic) NSString * value;
@property (copy, nonatomic) NSString * siriDisplayName;
@property (readonly, nonatomic, getter=) BOOL shouldHideContact;
+(BOOL)supportsSecureCoding;
+(id)stringForType:(long long)arg1;
+(id)handleWithDestinationID:(id)arg1;
+(id)handleForCHRecentCall:(id)arg1;
+(id)handleForCHRecentCall:(id)arg1 validHandlesOnly:(BOOL)arg2;
+(id)handleFromMessagingData:(id)arg1;
+(long long)handleTypeForCHHandle:(id)arg1;
+(id)handleWithDictionaryRepresentation:(id)arg1;
+(id)handleWithPerson:(id)arg1;
+(id)handleWithPersonHandle:(id)arg1;
+(id)handlesForCHRecentCall:(id)arg1;
+(id)handlesForCHRecentCall:(id)arg1 validHandlesOnly:(BOOL)arg2;
+(id)normalizedEmailAddressHandleForValue:(id)arg1;
+(id)normalizedGenericHandleForValue:(id)arg1;
+(id)normalizedHandleWithDestinationID:(id)arg1;
+(id)normalizedPhoneNumberHandleForValue:(id)arg1 isoCountryCode:(id)arg2;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(id)init;
-(BOOL)isEqual:(id)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(void)setType:(long long)arg1;
-(long long)type;
-(id)value;
-(id)dictionaryRepresentation;
-(void)setValue:(id)arg1;
-(id)personHandle;
-(id)initWithHandle:(id)arg1;
-(BOOL)isEqualToHandle:(id)arg1;
-(id)isoCountryCode;
-(void)setIsoCountryCode:(id)arg1;
-(id)initWithType:(long long)arg1 value:(id)arg2;
-(id)normalizedValue;
-(BOOL)shouldHideContactWithLockState:(BOOL)arg1;
-(id)siriDisplayName;
-(id)canonicalHandleForISOCountryCode:(id)arg1;
-(BOOL)hasSetISOCountryCode;
-(id)initWithDestinationID:(id)arg1;
-(id)initWithType:(long long)arg1 value:(id)arg2 normalizedValue:(id)arg3;
-(id)initWithType:(long long)arg1 value:(id)arg2 siriDisplayName:(id)arg3;
-(BOOL)isCanonicallyEqualToHandle:(id)arg1 isoCountryCode:(id)arg2;
-(BOOL)isEquivalentToHandle:(id)arg1;
-(BOOL)isValidForISOCountryCode:(id)arg1;
-(id)messagingData;
-(void)setHasSetISOCountryCode:(BOOL)arg1;
-(void)setSiriDisplayName:(id)arg1;
-(BOOL)shouldHideContact;
@end
