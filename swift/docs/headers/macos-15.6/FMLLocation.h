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

@interface FMLLocation : NSObject {

	int _floorLevel;
	FMLPlaceMark *_address;
	double _altitude;
	double _longitude;
	double _speed;
	double _horizontalAccuracy;
	NSArray *_labels;
	double _latitude;
	double _timestamp;
	double _verticalAccuracy;
	long long _type;
	NSString *_coarseAddressLabel;
	long long _locationType;
}
@property (retain) FMLPlaceMark * address;
@property (assign) double altitude;
@property (assign) double longitude;
@property (assign) double speed;
@property (assign) int floorLevel;
@property (assign) double horizontalAccuracy;
@property (copy) NSArray * labels;
@property (assign) double latitude;
@property (assign) double timestamp;
@property (assign) double verticalAccuracy;
@property (assign) long long locationType;
@property (copy) NSString * coarseAddressLabel;
@property (readonly) long long type;
-(id)debugDescription;
-(id)description;
-(double)timestamp;
-(long long)type;
-(id)address;
-(void)setAddress:(id)arg1;
-(void)setTimestamp:(double)arg1;
-(void)setSpeed:(double)arg1;
-(double)speed;
-(double)altitude;
-(double)latitude;
-(double)longitude;
-(id)labels;
-(void)setLabels:(id)arg1;
-(void)setAltitude:(double)arg1;
-(double)horizontalAccuracy;
-(void)setHorizontalAccuracy:(double)arg1;
-(void)setLatitude:(double)arg1;
-(void)setLongitude:(double)arg1;
-(void)setVerticalAccuracy:(double)arg1;
-(double)verticalAccuracy;
-(long long)locationType;
-(void)setLocationType:(long long)arg1;
-(int)floorLevel;
-(void)setFloorLevel:(int)arg1;
-(id)coarseAddressLabel;
-(id)initWithAddress:(id)arg1 altitude:(double)arg2 longitude:(double)arg3 speed:(double)arg4 floorLevel:(int)arg5 horizontalAccuracy:(double)arg6 labels:(id)arg7 latitude:(double)arg8 timestamp:(double)arg9 verticalAccuracy:(double)arg10 locationType:(long long)arg11 coarseAddressLabel:(id)arg12;
-(id)locationTypeDescription;
-(void)setCoarseAddressLabel:(id)arg1;
@end
