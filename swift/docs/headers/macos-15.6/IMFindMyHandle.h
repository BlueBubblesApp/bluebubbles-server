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
// Image: /System/Library/PrivateFrameworks/IMCore.framework/Versions/A/IMCore
// Image source: dyld_shared_cache (arm64e)

@interface IMFindMyHandle : NSObject {

	NSString *_identifier;
	FMFHandle *_fmfHandle;
	FMLHandle *_fmlHandle;
}
@property (retain, nonatomic) NSString * identifier;
@property (readonly, nonatomic) FMFHandle * fmfHandle;
@property (readonly, nonatomic) FMLHandle * fmlHandle;
+(id)handleWithFMFHandle:(id)arg1;
+(id)handleWithFMLHandle:(id)arg1;
+(id)handleWithIdentifier:(id)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)identifier;
-(id)initWithIdentifier:(id)arg1;
-(void)setIdentifier:(id)arg1;
-(id)fmfHandle;
-(id)fmlHandle;
@end
