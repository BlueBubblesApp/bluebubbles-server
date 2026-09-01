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

@interface TULinkShareItem : NSObject {

	TUConversationLink *_tuConversationLink;
	NSString *_title;
	NSURL *_placeholder;
}
@property (retain, nonatomic) TUConversationLink * tuConversationLink;
@property (copy, nonatomic) NSString * title;
@property (copy, nonatomic) NSURL * placeholder;
-(void)setTitle:(id)arg1;
-(id)title;
-(id)placeholder;
-(void)setPlaceholder:(id)arg1;
-(id)initWithTUConversationLink:(id)arg1;
-(id)initWithTUConversationLink:(id)arg1 title:(id)arg2 placeholder:(id)arg3;
-(void)setTuConversationLink:(id)arg1;
-(id)tuConversationLink;
@end
