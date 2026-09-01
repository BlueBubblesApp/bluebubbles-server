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

#import "FMF_Structs.h"

#import <FMF/NSCopying-Protocol.h>
#import <FMF/NSSecureCoding-Protocol.h>
#import <FMF/FMAnnotation-Protocol.h>

@interface FMFLocation : NSObject <NSCopying, NSSecureCoding, FMAnnotation> {

	BOOL _locatingInProgress;
	BOOL _isBorderEnabled;
	long long _locationType;
	CLLocation *_location;
	long long _activityState;
	FMAccuracyOverlay *_overlay;
	double _horizontalAccuracy;
	NSImage *_smallAnnotationIcon;
	NSImage *_smallOverlayIcon;
	NSImage *_largeOverlayIcon;
	NSImage *_largeAnnotationIcon;
	double _distanceFromUser;
	NSColor *_tintColor;
	FMFPlacemark *_placemark;
	FMFHandle *_handle;
	NSString *_longAddress;
	NSDate *_timestamp;
	NSString *_label;
	NSString *_shortAddressString;
	double _maxLocatingInterval;
	double _TTL;
	double _distance;
	NSString *_distanceDescription;
	NSString *_age;
	struct CLLocationCoordinate2D _coordinate;
}
@property (retain) FMFHandle * handle;
@property (retain) FMFPlacemark * placemark;
@property (assign) long long locationType;
@property (retain) CLLocation * location;
@property (assign) long long activityState;
@property (retain) NSString * label;
@property (getter=, assign) BOOL locatingInProgress;
@property (copy) NSString * shortAddressString;
@property (copy) NSString * longAddress;
@property (copy) NSDate * timestamp;
@property (assign) double maxLocatingInterval;
@property (assign) double TTL;
@property (assign) double distance;
@property (retain) NSString * distanceDescription;
@property (retain) NSString * age;
@property (readonly, copy) NSString * shortAddress;
@property (nonatomic, assign) struct CLLocationCoordinate2D coordinate;
@property (retain, nonatomic) FMAccuracyOverlay * overlay;
@property (nonatomic, assign) double horizontalAccuracy;
@property (nonatomic, assign) double distanceFromUser;
@property (nonatomic, assign) BOOL isBorderEnabled;
@property (retain, nonatomic) NSColor * tintColor;
@property (retain, nonatomic) NSImage * largeAnnotationIcon;
@property (retain, nonatomic) NSImage * smallAnnotationIcon;
@property (retain, nonatomic) NSImage * largeOverlayIcon;
@property (retain, nonatomic) NSImage * smallOverlayIcon;
@property (readonly, copy, nonatomic) NSString * title;
@property (readonly, copy, nonatomic) NSString * subtitle;
@property (readonly) unsigned long long hash;
@property (readonly) Class superclass;
@property (readonly, copy) NSString * description;
@property (readonly, copy) NSString * debugDescription;
+(BOOL)supportsSecureCoding;
-(BOOL)conformsToProtocol:(id)arg1;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(BOOL)isValid;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)timestamp;
-(id)label;
-(id)location;
-(void)setLabel:(id)arg1;
-(struct CLLocationCoordinate2D)coordinate;
-(id)subtitle;
-(id)title;
-(id)handle;
-(void)setLocation:(id)arg1;
-(void)setTimestamp:(id)arg1;
-(void)setTintColor:(id)arg1;
-(id)tintColor;
-(void)setHandle:(id)arg1;
-(double)distance;
-(void)setDistance:(double)arg1;
-(double)horizontalAccuracy;
-(void)setHorizontalAccuracy:(double)arg1;
-(id)initWithLatitude:(double)arg1 longitude:(double)arg2;
-(long long)locationType;
-(id)placemark;
-(void)setCoordinate:(struct CLLocationCoordinate2D)arg1;
-(id)overlay;
-(BOOL)isThisDevice;
-(id)age;
-(void)setAge:(id)arg1;
-(void)setLocationType:(long long)arg1;
-(id)shortAddress;
-(BOOL)hasKnownLocation;
-(void)setPlacemark:(id)arg1;
-(void)setOverlay:(id)arg1;
-(double)TTL;
-(BOOL)isBorderEnabled;
-(void)setLongAddress:(id)arg1;
-(void)setTTL:(double)arg1;
-(void)updateLocation:(id)arg1;
-(void)_updateLocation:(id)arg1;
-(long long)activityState;
-(id)agingItemTimestamp;
-(id)distanceDescription;
-(double)distanceFromUser;
-(long long)distanceThenNameCompare:(id)arg1;
-(id)initWithDictionary:(id)arg1 forHandle:(id)arg2 maxLocatingInterval:(double)arg3 TTL:(double)arg4;
-(id)initWithHandle:(id)arg1 locationType:(long long)arg2 location:(id)arg3 activityState:(long long)arg4 label:(id)arg5 locatingInProgress:(BOOL)arg6 shortAddress:(id)arg7 longAddress:(id)arg8 placemark:(id)arg9;
-(BOOL)isLocatingInProgress;
-(BOOL)isMoreRecentThan:(id)arg1;
-(id)largeAnnotationIcon;
-(id)largeOverlayIcon;
-(id)locationAge;
-(id)locationShortAddressWithAge;
-(id)locationShortAddressWithAgeIncludeLocating;
-(id)longAddress;
-(double)maxLocatingInterval;
-(void)resetLocateInProgress:(id)arg1;
-(void)resetLocateInProgressTimer;
-(void)setActivityState:(long long)arg1;
-(void)setDistanceDescription:(id)arg1;
-(void)setDistanceFromUser:(double)arg1;
-(void)setIsBorderEnabled:(BOOL)arg1;
-(void)setLargeAnnotationIcon:(id)arg1;
-(void)setLargeOverlayIcon:(id)arg1;
-(void)setLocatingInProgress:(BOOL)arg1;
-(void)setMaxLocatingInterval:(double)arg1;
-(void)setShortAddressString:(id)arg1;
-(void)setSmallAnnotationIcon:(id)arg1;
-(void)setSmallOverlayIcon:(id)arg1;
-(id)shortAddressString;
-(id)smallAnnotationIcon;
-(id)smallOverlayIcon;
-(void)updateHandle:(id)arg1;
-(void)updateLocationForCache:(id)arg1;
@end
