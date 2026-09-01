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

@interface ICNoteData : NSManagedObject {

	BOOL needsToBeSaved;
	BOOL settingNoteData;
	BOOL didBlockLastSave;
}
@property (nonatomic, getter=, assign) BOOL settingNoteData;
@property (retain, nonatomic) NSData * cryptoInitializationVector;
@property (retain, nonatomic) NSData * cryptoTag;
@property (nonatomic, assign) BOOL needsToBeSaved;
@property (nonatomic, assign) BOOL didBlockLastSave;
@property (retain, nonatomic) NSData * data;
@property (retain, nonatomic) ICNote * note;
@property (readonly, nonatomic) NSData * primitiveData;
-(void)willAccessValueForKey:(id)arg1;
-(void)willSave;
-(BOOL)didBlockLastSave;
-(BOOL)isSettingNoteData;
-(BOOL)needsToBeSaved;
-(BOOL)saveNoteDataIfNeeded;
-(void)setCryptoInitializationVector:(id)arg1;
-(void)setCryptoTag:(id)arg1;
-(void)setDidBlockLastSave:(BOOL)arg1;
-(void)setNeedsToBeSaved:(BOOL)arg1;
-(void)setSettingNoteData:(BOOL)arg1;
@end
