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

#import <NotesShared/ICNoteContainer-Protocol.h>

@interface ICNoteContext : NSObject <ICNoteContainer> {

	BOOL _delaySaving;
	BOOL _databaseOpenFailedDueToLowDiskSpace;
	BOOL _saving;
	BOOL _shouldEnsureLocalAccount;
	ICPersistentContainer *_persistentContainer;
	ICNotesCrossProcessChangeCoordinator *_crossProcessChangeCoordinator;
	NSManagedObjectContext *_managedObjectContext;
	ICNote *_currentNote;
	NSError *_databaseOpenError;
	NSTimer *_updateAttachmentLocationsTimer;
	unsigned long long _contextOptions;
	ICManagedObjectContextUpdater *_contextUpdater;
	ICAccountUtilities *_accountUtilities;
	NSTimer *_trashDeletionTimer;
	NSObject<OS_dispatch_queue> *_backgroundTaskQueue;
	NSDictionary *_persistentStoresByAccountId;
	unsigned long long _countOfPerformBackgroundTask;
}
@property (nonatomic, assign) unsigned long long contextOptions;
@property (retain) NSManagedObjectContext * managedObjectContext;
@property (retain, nonatomic) ICNotesCrossProcessChangeCoordinator * crossProcessChangeCoordinator;
@property (retain, nonatomic) ICManagedObjectContextUpdater * contextUpdater;
@property (getter=, assign) BOOL saving;
@property (retain, nonatomic) ICAccountUtilities * accountUtilities;
@property (retain, nonatomic) NSTimer * trashDeletionTimer;
@property (retain, nonatomic) NSObject<OS_dispatch_queue> * backgroundTaskQueue;
@property (nonatomic, assign) BOOL shouldEnsureLocalAccount;
@property (retain, nonatomic) NSDictionary * persistentStoresByAccountId;
@property (nonatomic, assign) unsigned long long countOfPerformBackgroundTask;
@property (nonatomic, assign) BOOL delaySaving;
@property (readonly, nonatomic) BOOL isSharedContext;
@property (readonly) ICPersistentContainer * persistentContainer;
@property (retain, nonatomic) ICNote * currentNote;
@property (retain, nonatomic) NSError * databaseOpenError;
@property (nonatomic, assign) BOOL databaseOpenFailedDueToLowDiskSpace;
@property (retain, nonatomic) NSTimer * updateAttachmentLocationsTimer;
@property (readonly, nonatomic) ICAccount * noteContainerAccount;
@property (readonly, nonatomic) ICFolderCustomNoteSortType * customNoteSortType;
@property (readonly, nonatomic) BOOL isSharedViaICloud;
@property (readonly, nonatomic) BOOL isSharedReadOnly;
@property (readonly, nonatomic) BOOL isAllNotesContainer;
@property (readonly, nonatomic) BOOL canBeSharedViaICloud;
@property (readonly, nonatomic) BOOL supportsEditingNotes;
@property (readonly, nonatomic) BOOL isTrashFolder;
@property (readonly, nonatomic) BOOL isModernCustomFolder;
@property (readonly, nonatomic) NSString * containerIdentifier;
@property (readonly, nonatomic) NSArray * visibleNotes;
@property (readonly, nonatomic) BOOL supportsDateHeaders;
@property (readonly, nonatomic) int dateHeadersType;
@property (readonly, nonatomic) BOOL isShowingDateHeaders;
@property (readonly, nonatomic) unsigned long long visibleNotesCount;
@property (readonly, copy, nonatomic) NSString * titleForNavigationBar;
@property (readonly, copy, nonatomic) NSString * titleForTableViewCell;
@property (readonly, copy, nonatomic) NSString * accountName;
@property (readonly, nonatomic) NSArray * visibleSubFolders;
@property (copy, nonatomic) NSData * subFolderOrderMergeableData;
@property (readonly, nonatomic, getter=) BOOL deleted;
@property (readonly) unsigned long long hash;
@property (readonly) Class superclass;
@property (readonly, copy) NSString * description;
@property (readonly, copy) NSString * debugDescription;
+(BOOL)isActive;
+(id)sharedContext;
+(void)clearSharedContext;
+(void)crashThisApp;
+(void)enableLocalAccount;
+(id)filenameFromFileWrapper:(id)arg1;
+(BOOL)hasContextOptions:(unsigned long long)arg1;
+(BOOL)hasSharedContext;
+(id)initializeSearchIndexerDataSourceWithPersistentContainer:(id)arg1;
+(BOOL)legacyNotesDisabled;
+(void)markOldTrashedNotesForDeletionInContext:(id)arg1;
+(id)performBackgroundTaskSerialQueue;
+(void)resetAppContainer;
+(void)resetAppState;
+(void)setLegacyNotesDisabled:(BOOL)arg1;
+(id)snapshotManagedObjectContextForContainer:(id)arg1;
+(void)startSharedContextWithOptions:(unsigned long long)arg1;
+(BOOL)updateSharedStateFile:(id)arg1 toState:(BOOL)arg2 error:(id *)arg3;
+(void)useContainerNamed:(id)arg1;
+(id)workerManagedObjectContextForContainer:(id)arg1;
-(void)dealloc;
-(id)initWithOptions:(unsigned long long)arg1;
-(BOOL)isTrashFolder;
-(id)objectID;
-(id)accountName;
-(id)containerIdentifier;
-(id)managedObjectContext;
-(id)persistentStoreCoordinator;
-(BOOL)save;
-(BOOL)save:(id *)arg1;
-(void)setManagedObjectContext:(id)arg1;
-(BOOL)isDeleted;
-(void)managedObjectContextDidSave:(id)arg1;
-(void)performBackgroundTask:(void (^)(void))arg1;
-(void)updateAccounts;
-(void)accountsDidChange:(id)arg1;
-(void)deleteEverything;
-(BOOL)isSaving;
-(id)persistentContainer;
-(void)applicationWillTerminate;
-(BOOL)isSharedViaICloud;
-(int)dateHeadersType;
-(BOOL)saveImmediately;
-(void)setCurrentNote:(id)arg1;
-(void)setDelaySaving:(BOOL)arg1;
-(void)setPersistentStoresByAccountId:(id)arg1;
-(BOOL)isSharedContext;
-(void)purgeEverything;
-(void)setSubFolderOrderMergeableData:(id)arg1;
-(id)accountUtilities;
-(void)addOrDeleteLocalAccountIfNecessary;
-(id)allICloudACAccounts;
-(void)applyDateHeadersType:(int)arg1;
-(id)backgroundTaskQueue;
-(BOOL)canBeSharedViaICloud;
-(void)cleanupAdditionalPersistentStores;
-(void)clearPersistentContainer;
-(void)cloudContextFetchRecordChangeOperationDidFinish:(id)arg1;
-(unsigned long long)contextOptions;
-(id)contextUpdater;
-(unsigned long long)countOfPerformBackgroundTask;
-(void)createAdditionalPersistentStoresWithAccountIdentifiers:(id)arg1 completionBlock:(void (^)(void))arg2;
-(void)createAdditionalPersistentStoresWithAccountIdentifiers:(id)arg1 persistentContainer:(id)arg2;
-(id)crossProcessChangeCoordinator;
-(id)currentNote;
-(id)customNoteSortType;
-(id)customNoteSortTypeValue;
-(id)databaseOpenError;
-(BOOL)databaseOpenFailedDueToLowDiskSpace;
-(id)defaultPersistentStoreFromPersistentStores:(id)arg1;
-(BOOL)delaySaving;
-(void)destroyPersistentStore;
-(void)ensureModernAccountExistsInContext:(id)arg1;
-(BOOL)hasAnyContextOptions:(unsigned long long)arg1;
-(BOOL)hasContextOptions:(unsigned long long)arg1;
-(id)inMemoryPersistentStoreFromPersistentStores:(id)arg1;
-(BOOL)isAllNotesContainer;
-(BOOL)isModernCustomFolder;
-(BOOL)isSharedReadOnly;
-(BOOL)isShowingDateHeaders;
-(void)loadAdditionalPersistentStores;
-(void)managedObjectContextUpdaterDidChangeObjectWithID:(id)arg1;
-(void)managedObjectContextUpdaterDidMerge:(id)arg1;
-(BOOL)mergeWithSubFolderMergeableData:(id)arg1;
-(id)noteContainerAccount;
-(BOOL)noteIsVisible:(id)arg1;
-(id)noteVisibilityTestingForSearchingAccount;
-(void)performSnapshotBackgroundTask:(void (^)(void))arg1;
-(id)persistentContainerQueue;
-(id)persistentStoreForAccountID:(id)arg1;
-(id)persistentStoresByAccountId;
-(id)predicateForPinnedNotes;
-(id)predicateForSearchableAttachments;
-(id)predicateForSearchableNotes;
-(id)predicateForVisibleNotes;
-(id)primaryICloudACAccount;
-(void)purgeDeletedObjectsInManagedObjectContext:(id)arg1;
-(BOOL)recoverFromSaveError;
-(void)refreshAll;
-(void)refreshPersistentStoresByAccountIdFromPersistentStores:(id)arg1;
-(void)reloadPersistentContainer;
-(void)saveSubFolderMergeableDataIfNeeded;
-(void)setAccountUtilities:(id)arg1;
-(void)setBackgroundTaskQueue:(id)arg1;
-(void)setContextOptions:(unsigned long long)arg1;
-(void)setContextUpdater:(id)arg1;
-(void)setCountOfPerformBackgroundTask:(unsigned long long)arg1;
-(void)setCrossProcessChangeCoordinator:(id)arg1;
-(void)setDatabaseOpenError:(id)arg1;
-(void)setDatabaseOpenFailedDueToLowDiskSpace:(BOOL)arg1;
-(void)setSaving:(BOOL)arg1;
-(void)setShouldEnsureLocalAccount:(BOOL)arg1;
-(void)setTrashDeletionTimer:(id)arg1;
-(void)setUpdateAttachmentLocationsTimer:(id)arg1;
-(void)setupCrossProcessChangeCoordinator;
-(void)setupTrashDeletionTimer;
-(BOOL)shouldEnsureLocalAccount;
-(id)snapshotManagedObjectContext;
-(void)startIndexingWithCoreSpotlightDelegateForDescription:(id)arg1 coordinator:(id)arg2;
-(void)startSearchIndexerChangeObservingIfNecessary;
-(id)storeFilenameForAccountIdentifier:(id)arg1;
-(id)subFolderOrderMergeableData;
-(BOOL)supportsDateHeaders;
-(BOOL)supportsEditingNotes;
-(BOOL)supportsVisibilityTestingType:(long long)arg1;
-(id)titleForNavigationBar;
-(id)titleForTableViewCell;
-(id)trashDeletionTimer;
-(id)updateAttachmentLocationsTimer;
-(void)updateSubFolderMergeableDataChangeCount;
-(id)visibleNotes;
-(unsigned long long)visibleNotesCount;
-(id)visibleSubFolders;
-(id)workerManagedObjectContext;
@end
