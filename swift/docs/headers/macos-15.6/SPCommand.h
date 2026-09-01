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

@interface SPCommand : NSObject <NSCopying, NSSecureCoding> {

	BOOL _enableLostMode;
	NSUUID *_identifier;
	NSUUID *_beaconIdentifier;
	long long _type;
	NSDate *_expiration;
	NSNumber *_duration;
	long long _playSoundContext;
	SPHandle *_handle;
	NSString *_lostModeEmail;
	NSString *_lostModeMessage;
	NSString *_lostModePhoneNumber;
	NSString *_obfuscatedIdentifier;
}
@property (copy, nonatomic) NSUUID * identifier;
@property (copy, nonatomic) NSUUID * beaconIdentifier;
@property (nonatomic, assign) long long type;
@property (copy, nonatomic) NSDate * expiration;
@property (copy, nonatomic) NSNumber * duration;
@property (nonatomic, assign) long long playSoundContext;
@property (copy, nonatomic) SPHandle * handle;
@property (copy, nonatomic) NSString * lostModeEmail;
@property (copy, nonatomic) NSString * lostModeMessage;
@property (copy, nonatomic) NSString * lostModePhoneNumber;
@property (copy, nonatomic) NSString * obfuscatedIdentifier;
@property (nonatomic, assign) BOOL enableLostMode;
@property (readonly, copy, nonatomic) NSString * taskName;
+(BOOL)supportsSecureCoding;
+(id)locate:(id)arg1;
+(id)beginLeashingWithBeaconUUID:(id)arg1;
+(id)connectToBeaconUUID:(id)arg1;
+(id)disableLostModeForBeaconUUID:(id)arg1;
+(id)disableNotifyWhenFound:(id)arg1;
+(id)disconnectFromBeaconUUID:(id)arg1;
+(id)enableLostModeForBeaconUUID:(id)arg1 message:(id)arg2 phoneNumber:(id)arg3 email:(id)arg4;
+(id)enableNotifyWhenFound:(id)arg1;
+(id)endLeashingWithBeaconUUID:(id)arg1;
+(id)playSoundWithBeaconUUID:(id)arg1;
+(id)playSoundWithBeaconUUID:(id)arg1 duration:(double)arg2;
+(id)playSoundWithBeaconUUID:(id)arg1 withContext:(long long)arg2;
+(id)setObfuscatedIdentifier:(id)arg1;
+(id)startBTFindingWithBeaconUUID:(id)arg1;
+(id)startNotifyWhenFound:(id)arg1;
+(id)stopBTFindingWithBeaconUUID:(id)arg1;
+(id)stopNotifyWhenFound:(id)arg1;
+(id)stopSoundWithBeaconUUID:(id)arg1;
+(id)unpairWithBeaconUUID:(id)arg1;
+(id)updateAccessoryFirmware:(id)arg1;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)identifier;
-(id)initWithCoder:(id)arg1;
-(void)setType:(long long)arg1;
-(long long)type;
-(void)setIdentifier:(id)arg1;
-(id)duration;
-(void)setDuration:(id)arg1;
-(id)handle;
-(void)setHandle:(id)arg1;
-(id)expiration;
-(void)setExpiration:(id)arg1;
-(id)taskName;
-(id)lostModeMessage;
-(id)beaconIdentifier;
-(BOOL)enableLostMode;
-(id)initWithBeaconUUID:(id)arg1 type:(long long)arg2 expiration:(id)arg3 duration:(id)arg4 handle:(id)arg5 lostModeEmail:(id)arg6 lostModeMessage:(id)arg7 lostModePhoneNumber:(id)arg8 obfuscatedIdentifier:(id)arg9 identifier:(id)arg10;
-(id)initWithBeaconUUID:(id)arg1 type:(long long)arg2 expiration:(id)arg3 duration:(id)arg4 handle:(id)arg5 lostModeMessage:(id)arg6 lostModePhoneNumber:(id)arg7 obfuscatedIdentifier:(id)arg8;
-(id)initWithBeaconUUID:(id)arg1 type:(long long)arg2 expiration:(id)arg3 duration:(id)arg4 playSoundContext:(long long)arg5 handle:(id)arg6 lostModeMessage:(id)arg7 lostModePhoneNumber:(id)arg8 obfuscatedIdentifier:(id)arg9 identifier:(id)arg10;
-(id)lostModeEmail;
-(id)lostModePhoneNumber;
-(id)obfuscatedIdentifier;
-(long long)playSoundContext;
-(void)setBeaconIdentifier:(id)arg1;
-(void)setEnableLostMode:(BOOL)arg1;
-(void)setLostModeEmail:(id)arg1;
-(void)setLostModeMessage:(id)arg1;
-(void)setLostModePhoneNumber:(id)arg1;
-(void)setObfuscatedIdentifier:(id)arg1;
-(void)setPlaySoundContext:(long long)arg1;
@end
