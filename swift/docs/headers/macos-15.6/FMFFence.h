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

@interface FMFFence : NSObject <NSCopying, NSSecureCoding> {

	BOOL _active;
	BOOL _recurring;
	BOOL _fromMe;
	NSString *_identifier;
	NSString *_label;
	CLLocation *_location;
	FMFPlacemark *_placemark;
	NSArray *_recipients;
	NSArray *_followerIds;
	NSString *_trigger;
	NSString *_type;
	unsigned long long _locationType;
	NSString *_acceptanceStatus;
	FMFSchedule *_schedule;
	NSDate *_muteEndDate;
	NSString *_ckRecordName;
	NSString *_ckRecordZoneOwnerName;
	NSString *_friendIdentifier;
	NSString *_createdByIdentifier;
	NSString *_pendingIdentifier;
	NSDate *_timestamp;
}
@property (readonly, nonatomic) NSString * displayLocationName;
@property (retain, nonatomic) NSString * identifier;
@property (retain, nonatomic) NSString * friendIdentifier;
@property (retain, nonatomic) NSString * createdByIdentifier;
@property (retain, nonatomic) NSString * pendingIdentifier;
@property (retain, nonatomic) NSString * label;
@property (retain, nonatomic) CLLocation * location;
@property (retain, nonatomic) FMFPlacemark * placemark;
@property (retain, nonatomic) NSArray * recipients;
@property (retain, nonatomic) NSArray * followerIds;
@property (retain, nonatomic) NSString * trigger;
@property (retain, nonatomic) NSString * type;
@property (nonatomic, assign) unsigned long long locationType;
@property (nonatomic, getter=, assign) BOOL active;
@property (nonatomic, getter=, assign) BOOL recurring;
@property (nonatomic, getter=, assign) BOOL fromMe;
@property (retain, nonatomic) FMFSchedule * schedule;
@property (retain, nonatomic) NSDate * muteEndDate;
@property (retain, nonatomic) NSDate * timestamp;
@property (retain, nonatomic) NSString * ckRecordName;
@property (retain, nonatomic) NSString * ckRecordZoneOwnerName;
@property (retain, nonatomic) NSString * acceptanceStatus;
@property (readonly, nonatomic, getter=) BOOL regionAllowed;
@property (readonly, nonatomic, getter=) BOOL onMe;
@property (readonly, getter=) BOOL supported;
@property (readonly, nonatomic, getter=) BOOL useCloudKitStore;
@property (readonly, nonatomic, getter=) BOOL useIDSTrigger;
@property (readonly, nonatomic, getter=) BOOL isMuted;
@property (readonly, nonatomic, getter=) NSDate * inviteDate;
+(BOOL)supportsSecureCoding;
+(id)endDateForMuteTimespan:(unsigned long long)arg1;
+(id)genericFriendName;
+(BOOL)isAllowedAtLocation:(struct CLLocationCoordinate2D)arg1;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(void)encodeWithCoder:(id)arg1;
-(id)identifier;
-(id)initWithCoder:(id)arg1;
-(id)initWithDictionary:(id)arg1;
-(void)setType:(id)arg1;
-(id)timestamp;
-(id)type;
-(BOOL)isActive;
-(void)setIdentifier:(id)arg1;
-(id)label;
-(id)location;
-(void)setLabel:(id)arg1;
-(BOOL)isMuted;
-(id)trigger;
-(id)recipients;
-(void)setLocation:(id)arg1;
-(void)setTimestamp:(id)arg1;
-(void)setActive:(BOOL)arg1;
-(void)setRecipients:(id)arg1;
-(void)setTrigger:(id)arg1;
-(id)acceptanceStatus;
-(id)ckRecordName;
-(void)setCkRecordName:(id)arg1;
-(id)schedule;
-(BOOL)isSupported;
-(void)setAcceptanceStatus:(id)arg1;
-(unsigned long long)locationType;
-(id)placemark;
-(BOOL)isFromMe;
-(void)setSchedule:(id)arg1;
-(void)setLocationType:(unsigned long long)arg1;
-(id)inviteDate;
-(void)setPlacemark:(id)arg1;
-(BOOL)isRecurring;
-(void)setRecurring:(BOOL)arg1;
-(void)setMuteEndDate:(id)arg1;
-(BOOL)isRegionAllowed;
-(void)setFollowerIds:(id)arg1;
-(id)ckRecordZoneOwnerName;
-(id)createdByIdentifier;
-(id)displayLocationName;
-(id)followerIds;
-(id)friendIdentifier;
-(id)handlesForArray:(id)arg1;
-(id)initWithRecipient:(id)arg1 location:(id)arg2 placemark:(id)arg3 label:(id)arg4 trigger:(id)arg5 type:(id)arg6 locationType:(unsigned long long)arg7 recurring:(BOOL)arg8;
-(BOOL)isOnMe;
-(id)localizedNotificationStringForFollower:(id)arg1 locationName:(id)arg2;
-(id)localizedRequestNotificationStringForFollower:(id)arg1 locationName:(id)arg2;
-(id)localizedSubtitleStringWithLocationName:(id)arg1;
-(id)localizedWillBeNotifiedStringForFollower:(id)arg1 locationName:(id)arg2;
-(id)locationForDictionary:(id)arg1;
-(id)muteEndDate;
-(id)pendingIdentifier;
-(void)setCkRecordZoneOwnerName:(id)arg1;
-(void)setCreatedByIdentifier:(id)arg1;
-(void)setFriendIdentifier:(id)arg1;
-(void)setFromMe:(BOOL)arg1;
-(void)setPendingIdentifier:(id)arg1;
-(BOOL)shouldUseCloudKitStore;
-(BOOL)shouldUseIDSTrigger;
-(void)updateFenceLocation:(id)arg1 placemark:(id)arg2 label:(id)arg3 trigger:(id)arg4 type:(id)arg5 locationType:(unsigned long long)arg6;
-(void)updateFenceMuteEndDate:(id)arg1;
@end
