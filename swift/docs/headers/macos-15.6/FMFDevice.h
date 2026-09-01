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

@interface FMFDevice : NSObject <NSCopying, NSSecureCoding> {

	BOOL _isActiveDevice;
	BOOL _isThisDevice;
	BOOL _isCompanionDevice;
	BOOL _isAutoMeCapable;
	NSString *_deviceId;
	NSString *_deviceName;
	NSString *_idsDeviceId;
}
@property (copy) NSString * deviceId;
@property (copy) NSString * deviceName;
@property (assign) BOOL isActiveDevice;
@property (assign) BOOL isThisDevice;
@property (assign) BOOL isCompanionDevice;
@property (assign) BOOL isAutoMeCapable;
@property (copy) NSString * idsDeviceId;
+(BOOL)supportsSecureCoding;
+(id)deviceWithId:(id)arg1 name:(id)arg2 idsDeviceId:(id)arg3 isActive:(BOOL)arg4 isThisDevice:(BOOL)arg5 isCompanionDevice:(BOOL)arg6 isAutoMeCapable:(BOOL)arg7;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)debugDescription;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)deviceName;
-(id)deviceId;
-(void)setDeviceName:(id)arg1;
-(id)idsDeviceId;
-(BOOL)isThisDevice;
-(BOOL)isActiveDevice;
-(void)setDeviceId:(id)arg1;
-(BOOL)isAutoMeCapable;
-(void)setIdsDeviceId:(id)arg1;
-(BOOL)isCompanionDevice;
-(void)setIsActiveDevice:(BOOL)arg1;
-(void)setIsAutoMeCapable:(BOOL)arg1;
-(void)setIsCompanionDevice:(BOOL)arg1;
-(void)setIsThisDevice:(BOOL)arg1;
-(void)updateIsActive:(BOOL)arg1 isThisDevice:(BOOL)arg2;
@end
