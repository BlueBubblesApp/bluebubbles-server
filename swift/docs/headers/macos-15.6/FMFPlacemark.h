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

@interface FMFPlacemark : NSObject <NSCopying, NSSecureCoding> {

	NSString *_locality;
	NSString *_administrativeArea;
	NSString *_country;
	NSString *_state;
	NSString *_streetAddress;
	NSString *_streetName;
	NSArray *_formattedAddressLines;
}
@property (retain, nonatomic) NSArray * formattedAddressLines;
@property (retain, nonatomic) NSString * locality;
@property (retain, nonatomic) NSString * administrativeArea;
@property (retain, nonatomic) NSString * country;
@property (retain, nonatomic) NSString * state;
@property (retain, nonatomic) NSString * streetAddress;
@property (retain, nonatomic) NSString * streetName;
+(BOOL)supportsSecureCoding;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)initWithDictionary:(id)arg1;
-(id)state;
-(void)setState:(id)arg1;
-(id)country;
-(id)dictionaryValue;
-(id)administrativeArea;
-(id)formattedAddressLines;
-(id)locality;
-(void)setCountry:(id)arg1;
-(void)setAdministrativeArea:(id)arg1;
-(void)setLocality:(id)arg1;
-(void)setFormattedAddressLines:(id)arg1;
-(void)setStreetAddress:(id)arg1;
-(id)streetAddress;
-(id)formattedAddress;
-(id)initWithLocality:(id)arg1 administrativeArea:(id)arg2 country:(id)arg3 state:(id)arg4 streetAddress:(id)arg5 streetName:(id)arg6;
-(void)setStreetName:(id)arg1;
-(id)streetName;
@end
