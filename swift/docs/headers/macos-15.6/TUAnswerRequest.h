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

#import "TelephonyUtilities_Structs.h"

#import <TelephonyUtilities/NSSecureCoding-Protocol.h>
#import <TelephonyUtilities/TUCallRequest-Protocol.h>
#import <TelephonyUtilities/TUVideoRequest-Protocol.h>

@interface TUAnswerRequest : NSObject <NSSecureCoding, TUCallRequest, TUVideoRequest> {

	BOOL _wantsHoldMusic;
	BOOL _pauseVideoToStart;
	BOOL _downgradeToAudio;
	BOOL _sendToScreening;
	BOOL _screeningDueToUserInteraction;
	BOOL _allowBluetoothAnswerWithoutDowngrade;
	NSString *_uniqueProxyIdentifier;
	NSString *_sourceIdentifier;
	IDSDestination *_endpointIDSDestination;
	NSString *_endpointRapportMediaSystemIdentifier;
	NSString *_endpointRapportEffectiveIdentifier;
	long long _behavior;
	NSDate *_dateAnswered;
	struct CGSize _localLandscapeAspectRatio;
	struct CGSize _localPortraitAspectRatio;
}
@property (retain, nonatomic) NSDate * dateAnswered;
@property (nonatomic, assign) BOOL allowBluetoothAnswerWithoutDowngrade;
@property (copy, nonatomic) NSString * sourceIdentifier;
@property (retain, nonatomic) IDSDestination * endpointIDSDestination;
@property (retain, nonatomic) NSString * endpointRapportMediaSystemIdentifier;
@property (retain, nonatomic) NSString * endpointRapportEffectiveIdentifier;
@property (nonatomic, assign) BOOL wantsHoldMusic;
@property (nonatomic, assign) BOOL pauseVideoToStart;
@property (nonatomic, assign) BOOL downgradeToAudio;
@property (nonatomic, assign) long long behavior;
@property (nonatomic, assign) BOOL sendToScreening;
@property (nonatomic, assign) BOOL screeningDueToUserInteraction;
@property (copy, nonatomic) NSString * uniqueProxyIdentifier;
@property (readonly) unsigned long long hash;
@property (readonly) Class superclass;
@property (readonly, copy) NSString * description;
@property (readonly, copy) NSString * debugDescription;
@property (nonatomic, assign) struct CGSize localLandscapeAspectRatio;
@property (nonatomic, assign) struct CGSize localPortraitAspectRatio;
+(BOOL)supportsSecureCoding;
-(id)description;
-(id)init;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(long long)behavior;
-(void)setBehavior:(long long)arg1;
-(void)setSourceIdentifier:(id)arg1;
-(id)sourceIdentifier;
-(BOOL)sendToScreening;
-(BOOL)allowBluetoothAnswerWithoutDowngrade;
-(id)dateAnswered;
-(BOOL)downgradeToAudio;
-(id)endpointIDSDestination;
-(id)endpointRapportEffectiveIdentifier;
-(id)endpointRapportMediaSystemIdentifier;
-(id)initWithCall:(id)arg1;
-(id)initWithUniqueProxyIdentifier:(id)arg1;
-(struct CGSize)localLandscapeAspectRatio;
-(struct CGSize)localPortraitAspectRatio;
-(BOOL)pauseVideoToStart;
-(BOOL)screeningDueToUserInteraction;
-(void)setAllowBluetoothAnswerWithoutDowngrade:(BOOL)arg1;
-(void)setDateAnswered:(id)arg1;
-(void)setDowngradeToAudio:(BOOL)arg1;
-(void)setEndpointIDSDestination:(id)arg1;
-(void)setEndpointRapportEffectiveIdentifier:(id)arg1;
-(void)setEndpointRapportMediaSystemIdentifier:(id)arg1;
-(void)setLocalLandscapeAspectRatio:(struct CGSize)arg1;
-(void)setLocalPortraitAspectRatio:(struct CGSize)arg1;
-(void)setPauseVideoToStart:(BOOL)arg1;
-(void)setScreeningDueToUserInteraction:(BOOL)arg1;
-(void)setSendToScreening:(BOOL)arg1;
-(void)setUniqueProxyIdentifier:(id)arg1;
-(void)setWantsHoldMusic:(BOOL)arg1;
-(id)uniqueProxyIdentifier;
-(BOOL)wantsHoldMusic;
@end
