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

@interface ICNoteContainer : ICCloudSyncingObject <ICNoteContainer> {

	BOOL _subFolderOrderMergeableDataDirty;
	ICTTOrderedSetVersionedDocument *_subFolderIdentifiersOrderedSetDocument;
}
@property (retain, nonatomic) ICAccount * owner;
@property (retain, nonatomic) NSString * accountNameForAccountListSorting;
@property (nonatomic, assign) BOOL isHiddenNoteContainer;
@property (retain, nonatomic) NSString * nestedTitleForSorting;
@property (retain, nonatomic) ICTTOrderedSetVersionedDocument * subFolderIdentifiersOrderedSetDocument;
@property (readonly, copy, nonatomic) NSString * cacheKey;
@property (nonatomic, assign) int sortOrder;
@property (readonly, nonatomic) ICCROrderedSet * subFolderIdentifiersOrderedSet;
@property (nonatomic, getter=, assign) BOOL subFolderOrderMergeableDataDirty;
@property (nonatomic, assign) int dateHeadersType;
@property (readonly, nonatomic) ICAccount * noteContainerAccount;
@property (readonly) NSManagedObjectContext * managedObjectContext;
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
+(id)keyPathsForValuesAffectingCloudAccount;
-(BOOL)isTrashFolder;
-(id)accountName;
-(id)containerIdentifier;
-(void)willRefresh:(BOOL)arg1;
-(void)willSave;
-(void)willTurnIntoFault;
-(id)cacheKey;
-(id)cloudAccount;
-(BOOL)isSharedViaICloud;
-(void)setSubFolderOrderMergeableData:(id)arg1;
-(void)applyDateHeadersType:(int)arg1;
-(BOOL)canBeSharedViaICloud;
-(id)customNoteSortType;
-(BOOL)isAllNotesContainer;
-(BOOL)isModernCustomFolder;
-(BOOL)isSharedReadOnly;
-(BOOL)isShowingDateHeaders;
-(BOOL)isSubFolderOrderMergeableDataDirty;
-(BOOL)mergeWithSubFolderMergeableData:(id)arg1;
-(id)noteContainerAccount;
-(BOOL)noteIsVisible:(id)arg1;
-(id)noteVisibilityTestingForSearchingAccount;
-(id)predicateForPinnedNotes;
-(id)predicateForSearchableAttachments;
-(id)predicateForSearchableNotes;
-(id)predicateForVisibleNotes;
-(void)saveSubFolderMergeableDataIfNeeded;
-(void)setSubFolderIdentifiersOrderedSetDocument:(id)arg1;
-(void)setSubFolderOrderMergeableDataDirty:(BOOL)arg1;
-(id)subFolderIdentifiersOrderedSet;
-(id)subFolderIdentifiersOrderedSetDocument;
-(id)subFolderOrderMergeableData;
-(BOOL)supportsDateHeaders;
-(BOOL)supportsEditingNotes;
-(BOOL)supportsVisibilityTestingType:(long long)arg1;
-(id)titleForNavigationBar;
-(id)titleForTableViewCell;
-(void)updateSubFolderMergeableDataChangeCount;
-(id)visibleNotes;
-(unsigned long long)visibleNotesCount;
-(id)visibleSubFolders;
-(void)writeSubFolderMergeableData;
@end
