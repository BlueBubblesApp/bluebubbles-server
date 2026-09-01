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
// Image: /System/Library/PrivateFrameworks/FindMyDevice.framework/Versions/A/FindMyDevice
// Image source: dyld_shared_cache (arm64e)

@interface FMDSharedConfiguration : NSObject

@property (readonly, nonatomic) NSString * localeString;+(id)sharedInstance;
+(id)localizedStringWithKey:(id)arg1;
-(id)localeString;
-(id)_createAwarenessStringsDictionaryWithData:(id)arg1 key:(id)arg2 deviceClasses:(id)arg3;
-(id)_createFollowUpStringsDictionaryWithData:(id)arg1 key:(id)arg2 deviceClasses:(id)arg3;
-(id)contentsWithLocale:(id)arg1;
-(id)defaultEntryForConfiguration:(id)arg1 deviceClasses:(id)arg2;
-(void)downloadWithLocale:(id)arg1 reply:(void (^)(void))arg2;
-(void)downloadWithReply:(void (^)(void))arg1;
-(id)entryForConfiguration:(id)arg1 deviceClasses:(id)arg2;
-(id)entryForConfiguration:(id)arg1 deviceClasses:(id)arg2 locale:(id)arg3;
-(id)expiryDateWithContents:(id)arg1;
-(id)fileURLWithLocale:(id)arg1;
-(void)forceDownloadWithLocale:(id)arg1 reply:(void (^)(void))arg2;
-(void)forceDownloadWithReply:(void (^)(void))arg1;
-(void)getTheftAndLossCoverageWithSerialNumber:(id)arg1 reply:(void (^)(void))arg2;
-(id)sharedConfigurationDictionaryFromData:(id)arg1 key:(id)arg2 deviceClasses:(id)arg3;
@end
