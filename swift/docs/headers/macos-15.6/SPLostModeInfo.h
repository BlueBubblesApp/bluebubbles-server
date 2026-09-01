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

@interface SPLostModeInfo : NSObject <NSCopying, NSSecureCoding> {

	NSDate *_timestamp;
	NSString *_message;
	NSString *_phoneNumber;
	NSString *_email;
}
@property (copy, nonatomic) NSDate * timestamp;
@property (copy, nonatomic) NSString * message;
@property (copy, nonatomic) NSString * phoneNumber;
@property (copy, nonatomic) NSString * email;
+(BOOL)supportsSecureCoding;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)timestamp;
-(id)message;
-(void)setMessage:(id)arg1;
-(id)phoneNumber;
-(void)setTimestamp:(id)arg1;
-(void)setPhoneNumber:(id)arg1;
-(id)email;
-(void)setEmail:(id)arg1;
-(id)initWithMessage:(id)arg1 email:(id)arg2 phoneNumber:(id)arg3 timestamp:(id)arg4;
@end
