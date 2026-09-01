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

#import "FindMyDevice_Structs.h"

@interface FMDFMMManager : NSObject {

	struct AuthorizationOpaqueRef *_authRef;
	FMNSXPCConnection *_disableFMMConnection;
	FMDFMMAccountInfo *_cachedAccountInfo;
	LAContext *_laContext;
}
@property (nonatomic, assign) struct AuthorizationOpaqueRef * authRef;
@property (retain, nonatomic) FMNSXPCConnection * disableFMMConnection;
@property (retain) FMDFMMAccountInfo * cachedAccountInfo;
@property (retain) LAContext * laContext;
+(id)sharedInstance;
-(void)dealloc;
-(id)init;
-(BOOL)isFMMEnabled;
-(void)didReceiveLostModeExitAuthToken:(id)arg1;
-(void)disableFMMUsingToken:(id)arg1 inContext:(unsigned long long)arg2 usingCallback:(void (^)(void))arg3;
-(BOOL)needsLostModeExitAuth;
-(id)retrieveFMMAccount:(id *)arg1;
-(void)registerObservers;
-(id)_genericErrorForDisableContext:(unsigned long long)arg1;
-(void)_invalidateDisableFMMConnection;
-(struct AuthorizationOpaqueRef *)authRef;
-(void)clearFMMAccountsWithCompletion:(void (^)(void))arg1;
-(id)_adminAuthDataForRight:(char *)arg1;
-(void)_createAuthRight;
-(void)_storeDisableFMMConnection:(id)arg1;
-(void)activationLockInfoForContext:(id)arg1 withCompletion:(void (^)(void))arg2;
-(void)activationLockInfoForUnlockWithCompletion:(void (^)(void))arg1;
-(void)activationLockInfoForValidationWithCompletion:(void (^)(void))arg1;
-(id)addFMMAccount:(id)arg1;
-(void)addFMMAccount:(id)arg1 withCompletion:(void (^)(void))arg2;
-(void)authenticateDeviceOwnerWithCallback:(void (^)(void))arg1;
-(id)cachedAccountInfo;
-(void)didChangeFMMAccountInfo:(id)arg1;
-(void)didRemoveLocalFindableAccessory:(id)arg1 completion:(void (^)(void))arg2;
-(id)disableFMMConnection;
-(void)disableFMMUsingToken:(id)arg1 deviceOwnerCredentials:(id)arg2 inContext:(unsigned long long)arg3 usingCallback:(void (^)(void))arg4;
-(void)enableActivationLockWithCompletion:(void (^)(void))arg1;
-(void)eraseAllContentAndSettingsUsingCallback:(void (^)(void))arg1;
-(void)fetchAPNSTokenWithCompletion:(void (^)(void))arg1;
-(void)fetchDeviceOwnerAuthContext:(void (^)(void))arg1;
-(void)initiateLostModeExitAuthWithCompletion:(void (^)(void))arg1;
-(void)isActivationLockCapableWithCompletion:(void (^)(void))arg1;
-(void)isActivationLockedWithCompletion:(void (^)(void))arg1;
-(id)laContext;
-(void)locationCommandWithCompletion:(void (^)(void))arg1;
-(void)locationPayloadWithCompletion:(void (^)(void))arg1;
-(void)needsDeviceOwnerCredentials:(void (^)(void))arg1;
-(id)newErrorForCode:(int)arg1 message:(id)arg2;
-(void)performActivationLockOperationWithContext:(id)arg1 withCompletion:(void (^)(void))arg2;
-(void)removeActivationLockForMacOSUserWithPassword:(id)arg1 withCompletion:(void (^)(void))arg2;
-(void)removeActivationLockForiCloudUser:(id)arg1 authenticationPET:(id)arg2 withCompletion:(void (^)(void))arg3;
-(id)removeFMMAccountWithUsername:(id)arg1;
-(id)removeFMMAccountWithUsername:(id)arg1 authRight:(id)arg2;
-(void)removeFMMAccountWithUsername:(id)arg1 authRight:(id)arg2 completion:(void (^)(void))arg3;
-(void)removeFMMAccountWithUsername:(id)arg1 authRight:(id)arg2 deviceOwnerCredentials:(id)arg3 completion:(void (^)(void))arg4;
-(void)removeFMMAccountWithUsername:(id)arg1 completion:(void (^)(void))arg2;
-(void)removeManagedActivationLockWithCode:(id)arg1 withCompletion:(void (^)(void))arg2;
-(void)retrieveFMMAccountWithCompletion:(void (^)(void))arg1;
-(void)setAuthRef:(struct AuthorizationOpaqueRef *)arg1;
-(void)setCachedAccountInfo:(id)arg1;
-(void)setDisableFMMConnection:(id)arg1;
-(void)setLaContext:(id)arg1;
-(void)shouldPromptForCredentialsForDeviceActivation:(void (^)(void))arg1;
-(void)shouldResumeCardsForUser:(id)arg1 withCompletion:(void (^)(void))arg2;
-(void)signatureHeadersWithData:(id)arg1 completion:(void (^)(void))arg2;
-(void)simulatePushWithPayload:(id)arg1 completion:(void (^)(void))arg2;
-(void)unregisterObservers;
-(void)updateCredentialsContextForDeviceActivation:(id)arg1 completion:(void (^)(void))arg2;
-(void)validateActivationLockForiCloudUser:(id)arg1 authenticationPET:(id)arg2 withCompletion:(void (^)(void))arg3;
@end
