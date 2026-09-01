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

@interface FMLFriend : NSObject {

	BOOL _originatedFromTheSameClient;
	FMLHandle *_handle;
	long long _handleType;
	NSDate *_createdAt;
	NSDate *_expiry;
	long long _origin;
}
@property (retain) FMLHandle * handle;
@property (assign) long long handleType;
@property (retain) NSDate * createdAt;
@property (retain) NSDate * expiry;
@property (assign) long long origin;
@property (assign) BOOL originatedFromTheSameClient;
-(id)debugDescription;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)handle;
-(long long)origin;
-(void)setOrigin:(long long)arg1;
-(void)setHandle:(id)arg1;
-(long long)handleType;
-(void)setHandleType:(long long)arg1;
-(id)createdAt;
-(void)setCreatedAt:(id)arg1;
-(id)expiry;
-(void)setExpiry:(id)arg1;
-(id)comparisonIdentifier;
-(BOOL)originatedFromTheSameClient;
-(void)setOriginatedFromTheSameClient:(BOOL)arg1;
-(id)initWithHandle:(id)arg1 handleType:(long long)arg2 createDate:(id)arg3 expiry:(id)arg4 origin:(long long)arg5 originatedFromTheSameClient:(BOOL)arg6;
@end
