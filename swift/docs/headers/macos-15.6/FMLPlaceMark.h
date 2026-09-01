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
// Image: /System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework/Versions/A/FindMyLocateObjCWrapper
// Image source: dyld_shared_cache (arm64e)

@interface FMLPlaceMark : NSObject {

	NSString *_locality;
	NSString *_administrativeArea;
	NSString *_country;
	NSString *_stateCode;
	NSString *_streetAddress;
	NSString *_streetName;
	NSArray *_formattedAddressLines;
}
@property (copy) NSString * locality;
@property (copy) NSString * administrativeArea;
@property (copy) NSString * country;
@property (copy) NSString * stateCode;
@property (copy) NSString * streetAddress;
@property (copy) NSString * streetName;
@property (copy) NSArray * formattedAddressLines;
-(id)debugDescription;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)country;
-(id)administrativeArea;
-(id)formattedAddressLines;
-(id)locality;
-(void)setCountry:(id)arg1;
-(void)setAdministrativeArea:(id)arg1;
-(void)setLocality:(id)arg1;
-(void)setFormattedAddressLines:(id)arg1;
-(void)setStreetAddress:(id)arg1;
-(id)streetAddress;
-(void)setStateCode:(id)arg1;
-(id)stateCode;
-(id)comparisonIdentifier;
-(void)setStreetName:(id)arg1;
-(id)streetName;
-(id)initWithLocality:(id)arg1 administrativeArea:(id)arg2 country:(id)arg3 stateCode:(id)arg4 streetAddress:(id)arg5 streetName:(id)arg6 formattedAddressLines:(id)arg7;
@end
