// IMNickname, IMNicknameAvatar, IMNicknameAvatarImage
//
// Obtained by ObjC-runtime introspection of IMCore on macOS 26.5.2 (build 25F84), not by
// class-dump: IMCore ships inside the dyld shared cache with no on-disk binary to dump.
// Property attribute strings are as `property_getAttributes` reported them.
//
// These back `icloud.contactCard` / `get-nickname-info`. The selectors that matter:
//
//   IMNicknameController  personalNickname        -> IMNickname   (the local user's card)
//                         nicknameForHandle:      -> IMNickname   (one handle's card)
//                         imageDataForHandle:     -> NSData
//   IMNickname            displayName, firstName, lastName, handle, avatar
//   IMNicknameAvatarImage imageFilePath, imageExists, hasImage, loadAndReturnImageData
//
// BOTH controller selectors return an IMNickname OBJECT, not a dictionary. An earlier
// implementation called `currentNicknameForHandleIDs:` and subscripted the result as
// [String: Any], which silently yielded nil for every field.

@interface IMNickname : NSObject

  @property hasObservedTransition   TB,N,R
  @property isActive   TB,N,R
  @property isIgnored   TB,N,R
  @property firstName   T@"NSString",C,N,V_firstName
  @property lastName   T@"NSString",C,N,V_lastName
  @property avatar   T@"IMNicknameAvatarImage",&,N,V_avatar
  @property avatarRecipe   T@"IMNicknameAvatarRecipe",&,N,V_avatarRecipe
  @property wallpaper   T@"IMWallpaper",&,N,V_wallpaper
  @property pronouns   T@"_NSAttributedStringGrammarInflection",&,N,V_pronouns
  @property displayName   T@"NSString",&,N,V_displayName
  @property archivedDate   T@"NSDate",C,N,V_archivedDate
  @property handle   T@"NSString",&,N,V_handle
  @property recordID   T@"NSString",&,N,V_recordID
  @property nameHash   T@"NSString",R,N,V_nameHash
  @property imageHash   T@"NSData",R,N,V_imageHash
  @property wallpaperImageHash   T@"NSData",R,N,V_wallpaperImageHash
  @property wallpaperLowResImageHash   T@"NSData",R,N,V_wallpaperLowResImageHash
  @property concatenatedImageHash   T@"NSString",R,N,V_concatenatedImageHash
  @property preBlastDoorPayloadData   T@"NSDictionary",&,N,V_preBlastDoorPayloadData

  - (id).cxx_destruct;
  - (id)_imageHashCreatedInChunks:;
  - (id)_sharingState;
  - (id)archivedDate;
  - (id)avatar;
  - (id)avatarRecipe;
  - (id)concatenatedImageHash;
  - (id)copyWithZone:;
  - (id)dataRepresentation;
  - (id)description;
  - (id)dictionaryRepresentation;
  - (id)displayName;
  - (id)encodeWithCoder:;
  - (id)firstName;
  - (id)handle;
  - (id)hasObservedTransition;
  - (id)imageHash;
  - (id)init;
  - (id)initWithCoder:;
  - (id)initWithDictionaryRepresentation:;
  - (id)initWithFirstName:lastName:avatar:pronouns:;
  - (id)initWithFirstName:lastName:avatar:pronouns:wallpaper:;
  - (id)initWithFirstName:lastName:avatar:pronouns:wallpaper:avatarRecipe:;
  - (id)initWithMeContact:;
  - (id)initWithPublicDictionaryRepresentationWithoutAvatar:;
  - (id)isActive;
  - (id)isEqual:;
  - (id)isEqualToNickname:options:;
  - (id)isIgnored;
  - (id)isUpdateFromNickname:withOptions:;
  - (id)lastName;
  - (id)nameHash;
  - (id)persistedDictionaryRepresentation;
  - (id)preBlastDoorPayloadData;
  - (id)pronouns;
  - (id)publicDictionaryRepresentation;
  - (id)publicDictionaryRepresentationWithoutAvatar;
  - (id)recordID;
  - (id)setArchivedDate:;
  - (id)setAvatar:;
  - (id)setAvatarRecipe:;
  - (id)setDisplayName:;
  - (id)setFirstName:;
  - (id)setHandle:;
  - (id)setLastName:;
  - (id)setPreBlastDoorPayloadData:;
  - (id)setPronouns:;
  - (id)setRecordID:;
  - (id)setWallpaper:;
  - (id)updateNameFromContact:;
  - (id)wallpaper;
  - (id)wallpaperImageHash;
  - (id)wallpaperLowResImageHash;

@end

@interface IMNicknameAvatar : NSObject

  - (id)copyWithZone:;
  - (id)encodeWithCoder:;
  - (id)initWithCoder:;

@end

@interface IMNicknameAvatarImage : IMNicknameAvatar

  @property hasImage   TB,R,N
  @property imageName   T@"NSString",R,C,N,V_imageName
  @property imageFilePath   T@"NSString",R,C,N,V_imageFilePath
  @property imageExists   TB,R,N
  @property contentIsSensitive   TB,R,N,V_contentIsSensitive

  - (id).cxx_destruct;
  - (id)_writeImageData:path:error:;
  - (id)contentIsSensitive;
  - (id)copyWithZone:;
  - (id)description;
  - (id)dictionaryRepresentation;
  - (id)encodeWithCoder:;
  - (id)hasImage;
  - (id)imageData;
  - (id)imageExists;
  - (id)imageFilePath;
  - (id)imageName;
  - (id)init;
  - (id)initWithCoder:;
  - (id)initWithDictionaryRepresentation:;
  - (id)initWithImageName:imageData:imageFilePath:contentIsSensitive:;
  - (id)initWithImageName:imageData:imageFilePath:contentIsSensitive:error:;
  - (id)initWithImageName:imageFilePath:contentIsSensitive:;
  - (id)initWithPublicDictionaryMetadataRepresentation:;
  - (id)initWithPublicDictionaryMetadataRepresentation:imageData:imageFilePath:contentIsSensitive:error:;
  - (id)loadAndReturnImageData;
  - (id)publicDictionaryMetadataRepresentation;
  - (id)publicDictionaryRepresentation;

@end
