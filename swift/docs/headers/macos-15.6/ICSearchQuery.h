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
// Image: /System/Library/PrivateFrameworks/NotesShared.framework/Versions/A/NotesShared
// Image source: dyld_shared_cache (arm64e)

@interface ICSearchQuery : NSObject {

	BOOL _wasForceStopped;
	BOOL _modernResultsOnly;
	ICRankingQueriesDefinition *_rankingQueriesDefinition;
	NSObject<OS_dispatch_semaphore> *_synchronousSemaphore;
	CSSearchQuery *_searchQuery;
	NSMutableDictionary *_mutableQueryResults;
	NSArray *_externalRankingQueries;
}
@property (retain, nonatomic) NSObject<OS_dispatch_semaphore> * synchronousSemaphore;
@property (nonatomic, assign) BOOL wasForceStopped;
@property (retain, nonatomic) CSSearchQuery * searchQuery;
@property (retain, nonatomic) NSMutableDictionary * mutableQueryResults;
@property (retain, nonatomic) ICRankingQueriesDefinition * rankingQueriesDefinition;
@property (retain, nonatomic) NSArray * externalRankingQueries;
@property (readonly, nonatomic) NSDictionary * queryResults;
@property (readonly, nonatomic) BOOL modernResultsOnly;
+(id)defaultAttributesToReturnFromCoreSpotlight;
-(double)timeoutInterval;
-(void)cancel;
-(id)rankingQueries;
-(void)setSearchQuery:(id)arg1;
-(id)searchQuery;
-(BOOL)run:(id *)arg1;
-(id)attributesToFetch;
-(id)queryResults;
-(void)forceStop;
-(id)initWithExternalRankingQueries:(id)arg1;
-(BOOL)wasForceStopped;
-(id)externalRankingQueries;
-(id)initWithRankingQueriesDefinition:(id)arg1;
-(BOOL)modernResultsOnly;
-(id)mutableQueryResults;
-(id)newSearchQueryContext;
-(id)newSearchQueryWithContext:(id)arg1;
-(void)queryFinishedRunningWithError:(id)arg1;
-(id)queryResultsToAddFromBatch:(id)arg1;
-(id)rankingQueriesDefinition;
-(void)setExternalRankingQueries:(id)arg1;
-(void)setMutableQueryResults:(id)arg1;
-(void)setRankingQueriesDefinition:(id)arg1;
-(void)setSynchronousSemaphore:(id)arg1;
-(void)setWasForceStopped:(BOOL)arg1;
-(void)setupWithAttributes:(id)arg1;
-(id)synchronousSemaphore;
@end
