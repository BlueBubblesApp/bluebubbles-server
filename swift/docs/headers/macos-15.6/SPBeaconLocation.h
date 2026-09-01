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
// Image: /System/Library/PrivateFrameworks/SPOwner.framework/Versions/A/SPOwner
// Image source: dyld_shared_cache (arm64e)

#import <SPOwner/NSCopying-Protocol.h>
#import <SPOwner/NSSecureCoding-Protocol.h>

@interface SPBeaconLocation : NSObject <NSCopying, NSSecureCoding> {

	NSDate *_timestamp;
	double _latitude;
	double _longitude;
	double _horizontalAccuracy;
	NSString *_source;
}
@property (copy, nonatomic) NSDate * timestamp;
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
@property (copy, nonatomic) NSString * source;
@property (readonly, nonatomic) double horizontalAccuracy;
+(BOOL)supportsSecureCoding;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)debugDescription;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)timestamp;
-(id)source;
-(void)setTimestamp:(id)arg1;
-(void)setSource:(id)arg1;
-(double)latitude;
-(double)longitude;
-(double)horizontalAccuracy;
-(void)setLatitude:(double)arg1;
-(void)setLongitude:(double)arg1;
-(id)initWithTimestamp:(id)arg1 latitude:(double)arg2 longitude:(double)arg3 horizontalAccuracy:(double)arg4 source:(id)arg5;
@end
