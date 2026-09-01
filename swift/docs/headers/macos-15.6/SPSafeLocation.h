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

#import <SPOwner/NSSecureCoding-Protocol.h>
#import <SPOwner/NSCopying-Protocol.h>

@interface SPSafeLocation : NSObject <NSSecureCoding, NSCopying> {

	NSUUID *_identifier;
	long long _type;
	NSString *_name;
	CLLocation *_location;
	long long _approvalState;
	NSSet *_associatedBeacons;
}
@property (copy, nonatomic) NSUUID * identifier;
@property (nonatomic, assign) long long type;
@property (copy, nonatomic) NSString * name;
@property (copy, nonatomic) CLLocation * location;
@property (nonatomic, assign) long long approvalState;
@property (copy, nonatomic) NSSet * associatedBeacons;
@property (readonly, nonatomic) double latitude;
@property (readonly, nonatomic) double longitude;
@property (readonly, nonatomic) double horizontalAccuracy;
@property (readonly, nonatomic) double altitude;
@property (readonly, nonatomic) double verticalAccuracy;
@property (readonly, nonatomic) double speed;
@property (readonly, nonatomic) double speedAccuracy;
@property (readonly, nonatomic) double course;
@property (readonly, nonatomic) double courseAccuracy;
+(BOOL)supportsSecureCoding;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)debugDescription;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)name;
-(void)encodeWithCoder:(id)arg1;
-(id)identifier;
-(id)initWithCoder:(id)arg1;
-(void)setName:(id)arg1;
-(void)setType:(long long)arg1;
-(long long)type;
-(void)setIdentifier:(id)arg1;
-(id)location;
-(void)setLocation:(id)arg1;
-(double)speed;
-(double)altitude;
-(double)latitude;
-(double)longitude;
-(double)course;
-(double)horizontalAccuracy;
-(double)verticalAccuracy;
-(double)courseAccuracy;
-(double)speedAccuracy;
-(long long)approvalState;
-(void)setApprovalState:(long long)arg1;
-(id)associatedBeacons;
-(id)initWithIdentifier:(id)arg1 type:(long long)arg2 name:(id)arg3 location:(id)arg4 associatedBeacons:(id)arg5 approvalState:(long long)arg6;
-(id)initWithType:(long long)arg1 name:(id)arg2 location:(id)arg3 approvalState:(long long)arg4;
-(id)mutableSafeLocation;
-(void)setAssociatedBeacons:(id)arg1;
@end
