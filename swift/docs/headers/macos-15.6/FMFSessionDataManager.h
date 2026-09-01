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

@interface FMFSessionDataManager : NSObject {

	NSSet *_followers;
	NSSet *_following;
	NSSet *_locations;
	NSSet *_fences;
	NSMutableDictionary *_locationsCache;
}
@property (retain, nonatomic) NSMutableDictionary * locationsCache;
@property (retain, nonatomic) NSSet * followers;
@property (retain, nonatomic) NSSet * following;
@property (retain, nonatomic) NSSet * locations;
@property (retain, nonatomic) NSSet * fences;
+(id)sharedInstance;
-(void)setLocations:(id)arg1;
-(id)locations;
-(id)locationsCache;
-(void)setLocationsCache:(id)arg1;
-(void)abDidChange;
-(void)abPreferencesDidChange;
-(id)favoritesOrdered;
-(id)fences;
-(id)followerForHandle:(id)arg1;
-(id)followers;
-(id)following;
-(id)followingForHandle:(id)arg1;
-(id)locationForHandle:(id)arg1;
-(id)offerExpirationForHandle:(id)arg1 groupId:(id)arg2;
-(void)setFences:(id)arg1;
-(void)setFollowers:(id)arg1;
-(void)setFollowing:(id)arg1;
@end
