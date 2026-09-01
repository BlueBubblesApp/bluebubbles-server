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

@interface FMLDevice : NSObject {

	BOOL _isActive;
	BOOL _isThisDevice;
	BOOL _isCompanion;
	BOOL _isAutoMeCapable;
	NSString *_identifier;
	NSString *_deviceName;
	NSString *_idsDeviceId;
}
@property (copy) NSString * identifier;
@property (copy) NSString * deviceName;
@property (copy) NSString * idsDeviceId;
@property (assign) BOOL isActive;
@property (assign) BOOL isThisDevice;
@property (assign) BOOL isCompanion;
@property (assign) BOOL isAutoMeCapable;
-(id)debugDescription;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)identifier;
-(BOOL)isActive;
-(void)setIdentifier:(id)arg1;
-(void)setIsActive:(BOOL)arg1;
-(id)deviceName;
-(BOOL)isCompanion;
-(void)setDeviceName:(id)arg1;
-(id)idsDeviceId;
-(BOOL)isThisDevice;
-(BOOL)isAutoMeCapable;
-(void)setIdsDeviceId:(id)arg1;
-(id)comparisonIdentifier;
-(void)setIsAutoMeCapable:(BOOL)arg1;
-(void)setIsThisDevice:(BOOL)arg1;
-(void)setIsCompanion:(BOOL)arg1;
-(id)initWithIdentifier:(id)arg1 deviceName:(id)arg2 idsDeviceId:(id)arg3 isActive:(BOOL)arg4 isThisDevice:(BOOL)arg5 isCompanion:(BOOL)arg6 isAutoMeCapable:(BOOL)arg7;
@end
