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

#import <TelephonyUtilities/NSSecureCoding-Protocol.h>

@interface TUJoinContinuityConversationRequest : NSObject <NSSecureCoding> {

	BOOL _isAudioEnabled;
	BOOL _isVideoEnabled;
	BOOL _wantsStagingArea;
	NSUUID *_uuid;
}
@property (readonly, nonatomic) NSUUID * uuid;
@property (readonly, nonatomic) BOOL isAudioEnabled;
@property (readonly, nonatomic) BOOL isVideoEnabled;
@property (readonly, nonatomic) BOOL wantsStagingArea;
+(BOOL)supportsSecureCoding;
+(id)requestForJoinWithUUID:(id)arg1 isAudioEnabled:(BOOL)arg2 isVideoEnabled:(BOOL)arg3;
+(id)requestForStagingAreaWithUUID:(id)arg1;
-(id)description;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)uuid;
-(BOOL)isAudioEnabled;
-(id)initWithUUID:(id)arg1 isAudioEnabled:(BOOL)arg2 isVideoEnabled:(BOOL)arg3 wantsStagingArea:(BOOL)arg4;
-(BOOL)isVideoEnabled;
-(BOOL)wantsStagingArea;
@end
