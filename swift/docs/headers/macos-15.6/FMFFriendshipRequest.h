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

@interface FMFFriendshipRequest : NSObject <NSCopying, NSSecureCoding> {

	long long _requestType;
	FMFHandle *_fromHandle;
	NSSet *_toHandles;
	NSDate *_endDate;
	NSString *_groupId;
	NSString *_requestId;
}
@property (retain) NSString * requestId;
@property (assign) long long requestType;
@property (retain) FMFHandle * fromHandle;
@property (retain) NSSet * toHandles;
@property (retain) NSDate * endDate;
@property (retain) NSString * groupId;
+(BOOL)supportsSecureCoding;
+(id)friendshipRequestToHandles:(id)arg1 fromHandle:(id)arg2 withType:(long long)arg3 groupId:(id)arg4 withEndDate:(id)arg5;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)endDate;
-(void)setEndDate:(id)arg1;
-(long long)requestType;
-(void)setRequestType:(long long)arg1;
-(id)groupId;
-(id)requestId;
-(void)setRequestId:(id)arg1;
-(void)setGroupId:(id)arg1;
-(id)fromHandle;
-(id)toHandles;
-(id)initWithFromHandle:(id)arg1 toHandle:(id)arg2 ofType:(long long)arg3 groupId:(id)arg4 endDate:(id)arg5 requestId:(id)arg6;
-(void)setFromHandle:(id)arg1;
-(void)setToHandles:(id)arg1;
@end
