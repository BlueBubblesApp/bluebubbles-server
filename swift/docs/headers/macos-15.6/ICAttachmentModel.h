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

#import "NotesShared_Structs.h"

#import <NotesShared/ICAttachmentModelUI-Protocol.h>

@interface ICAttachmentModel : NSObject <ICAttachmentModelUI> {

	BOOL _previewGenerationOperationCancelled;
	BOOL _mergeableDataDirty;
	BOOL _generatingPreviews;
	BOOL _hasDeepLink;
	ICAttachment *_attachment;
}
@property (assign) BOOL previewGenerationOperationCancelled;
@property (readonly, nonatomic) double placeholderWidth;
@property (readonly, nonatomic) double placeholderHeight;
@property (readonly, __weak, nonatomic) ICAttachment * attachment;
@property (readonly, nonatomic) BOOL shouldShowInContentInfoText;
@property (readonly, nonatomic) BOOL isIncludedInGenericAttachmentCount;
@property (nonatomic, getter=, assign) BOOL mergeableDataDirty;
@property (readonly, copy, nonatomic) NSUUID * currentReplicaID;
@property (readonly, nonatomic) struct CGSize intrinsicContentSize;
@property (readonly, nonatomic) BOOL hasPreviews;
@property (readonly, nonatomic) BOOL previewsSupportMultipleAppearances;
@property (readonly, nonatomic) BOOL preferLocalPreviewImages;
@property (readonly, nonatomic) BOOL needsFullSizePreview;
@property (readonly, nonatomic) BOOL requiresPostProcessing;
@property (readonly, nonatomic) BOOL supportsOCR;
@property (readonly, nonatomic) BOOL supportsImageClassification;
@property (readonly, nonatomic) NSString * previewImageTypeUTI;
@property (readonly, nonatomic) NSString * hardLinkVersion;
@property (readonly, nonatomic) BOOL hasThumbnailImage;
@property (readonly, nonatomic) BOOL showThumbnailInNoteList;
@property (readonly, nonatomic) BOOL canMarkup;
@property (readonly, nonatomic) BOOL supportsQuickLook;
@property (readonly, nonatomic) NSURL * saveURL;
@property (readonly, nonatomic) BOOL canSaveURL;
@property (readonly, nonatomic) BOOL canSaveURLWithOtherAttachments;
@property (nonatomic, getter=, assign) BOOL generatingPreviews;
@property (nonatomic, assign) BOOL hasDeepLink;
@property (readonly, nonatomic) BOOL shouldUsePlaceholderBoundsIfNecessary;
@property (readonly, nonatomic) NSString * placeholderImageSystemName;
@property (readonly, nonatomic) AVAsset * asset;
@property (readonly) unsigned long long hash;
@property (readonly) Class superclass;
@property (readonly, copy) NSString * description;
@property (readonly, copy) NSString * debugDescription;
+(id)contentInfoTextWithAttachmentCount:(unsigned long long)arg1;
+(void)deletePreviewItemHardLinkURLs;
+(Class)modelClassForAttachmentType:(short)arg1;
-(void)dealloc;
-(BOOL)requiresPostProcessing;
-(id)asset;
-(id)attachment;
-(struct CGSize)intrinsicContentSize;
-(id)previewItemTitle;
-(id)previewItemURL;
-(id)providerDataTypes;
-(id)providerFileTypes;
-(id)localizedFallbackTitle;
-(id)saveURL;
-(id)initWithAttachment:(id)arg1;
-(void)setHasDeepLink:(BOOL)arg1;
-(BOOL)hasDeepLink;
-(BOOL)hasThumbnailImage;
-(double)placeholderHeight;
-(double)placeholderWidth;
-(id)hardLinkVersion;
-(BOOL)shouldCropImage;
-(void)addLocation;
-(void)addMergeableDataToCloudKitRecord:(id)arg1 approach:(long long)arg2 mergeableFieldState:(id)arg3;
-(id)additionalIndexableTextContentInNote;
-(void)assetWithCompletion:(void (^)(void))arg1;
-(void)attachmentAwakeFromFetch;
-(void)attachmentDidRefresh:(BOOL)arg1;
-(void)attachmentIsDeallocating:(id)arg1;
-(void)attachmentWillRefresh:(BOOL)arg1;
-(void)attachmentWillTurnIntoFault;
-(id)attributesForSharingHTMLWithTagName:(id *)arg1 textContent:(id *)arg2;
-(BOOL)canConvertToHTMLForSharing;
-(BOOL)canMarkup;
-(BOOL)canSaveURL;
-(BOOL)canSaveURLWithOtherAttachments;
-(id)correctedHardlinkURLFileExtensionForExtension:(id)arg1;
-(id)currentReplicaID;
-(id)dataForQuickLook;
-(id)dataForTypeIdentifier:(id)arg1;
-(void)deleteChildAttachments;
-(id)fileURLForTypeIdentifier:(id)arg1;
-(id)generateHardLinkURLIfNecessaryForURL:(id)arg1;
-(id)generateHardLinkURLIfNecessaryForURL:(id)arg1 withFileName:(id)arg2;
-(id)generateTemporaryURLWithExtension:(id)arg1;
-(id)hardLinkFolderURL;
-(BOOL)hasPreviews;
-(BOOL)hidesSubAttachmentsInAttachmentBrowser;
-(BOOL)isGeneratingPreviews;
-(BOOL)isIncludedInGenericAttachmentCount;
-(BOOL)isMergeableDataDirty;
-(BOOL)isReadyToPresent;
-(id)localizedFallbackSubtitleIOS;
-(id)localizedFallbackSubtitleMac;
-(void)mergeMergeableDataFromCloudKitRecord:(id)arg1 approach:(long long)arg2 mergeableFieldState:(id)arg3;
-(BOOL)mergeWithMergeableData:(id)arg1;
-(BOOL)mergeWithMergeableData:(id)arg1 mergeableFieldState:(id)arg2;
-(id)mergeableDataForCopying;
-(id)mergeableDataForCopying:(id *)arg1;
-(BOOL)needsFullSizePreview;
-(void)persistPendingChanges;
-(id)placeholderImageSystemName;
-(BOOL)preferLocalPreviewImages;
-(BOOL)previewGenerationOperationCancelled;
-(struct CGAffineTransform)previewImageOrientationTransform;
-(id)previewImageTypeUTI;
-(BOOL)previewsSupportMultipleAppearances;
-(BOOL)providesStandaloneTitleForNote;
-(BOOL)providesTextContentInNote;
-(void)redactAuthorAttributionsToCurrentUser;
-(void)regenerateTextContentInNote;
-(void)removeTimestampsForReplicaID:(id)arg1;
-(void)replaceChildInlineAttachment:(id)arg1 withText:(id)arg2;
-(id)searchableTextContent;
-(id)searchableTextContentForLocation;
-(id)searchableTextContentInNote;
-(short)sectionForSubAttachments;
-(void)setGeneratingPreviews:(BOOL)arg1;
-(void)setMergeableDataDirty:(BOOL)arg1;
-(void)setPreviewGenerationOperationCancelled:(BOOL)arg1;
-(BOOL)shouldGeneratePreviewAfterChangeInSubAttachmentWithIdentifier:(id)arg1;
-(BOOL)shouldShowInContentInfoText;
-(BOOL)shouldSyncPreviewImageToCloud:(id)arg1;
-(BOOL)shouldUsePlaceholderBoundsIfNecessary;
-(BOOL)showThumbnailInNoteList;
-(id)standaloneTitleForNote;
-(BOOL)supportsImageClassification;
-(BOOL)supportsOCR;
-(BOOL)supportsQuickLook;
-(id)textContentInNote;
-(id)titleForSubAttachment:(id)arg1;
-(void)undeleteChildAttachments;
-(void)updateAfterLoadWithInlineAttachmentIdentifierMap:(id)arg1;
-(void)updateAfterLoadWithSubAttachmentIdentifierMap:(id)arg1;
-(void)updateAttachmentMarkedForDeletionStateAttachmentIsInUse:(BOOL)arg1;
-(void)updateAttachmentSize;
-(void)updateFileBasedAttributes;
-(BOOL)usesChildAttachment:(id)arg1;
-(void)willMarkAttachmentForDeletion;
-(void)writeMergeableData;
@end
