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
// Image: /System/Library/PrivateFrameworks/SPOwner.framework/Versions/A/SPOwner
// Image source: dyld_shared_cache (arm64e)

#import <SPOwner/NSCopying-Protocol.h>
#import <SPOwner/NSSecureCoding-Protocol.h>

@interface SPBeacon : NSObject <NSCopying, NSSecureCoding> {

	BOOL _accepted;
	BOOL _isZeus;
	BOOL _connected;
	BOOL _canBeLeashedByHost;
	BOOL _connectionAllowed;
	BOOL _isAppleAudioAccessory;
	NSUUID *_identifier;
	NSUUID *_groupIdentifier;
	long long _partIdentifier;
	SPHandle *_owner;
	NSString *_name;
	NSString *_model;
	SPBeaconRole *_role;
	SPLostModeInfo *_lostModeInfo;
	NSSet *_shares;
	NSDictionary *_taskInformation;
	NSString *_systemVersion;
	NSUUID *_productUUID;
	long long _vendorId;
	long long _productId;
	NSString *_type;
	long long _batteryLevel;
	long long _connectableDeviceCount;
	NSString *_separationState;
	long long _beaconSeparationState;
	NSSet *_safeLocations;
	NSSet *_locationProviders;
	SPDiscoveredAccessoryProductInformation *_accessoryProductInfo;
	NSString *_stableIdentifier;
	NSDate *_pairingDate;
	NSString *_correlationIdentifier;
	NSDate *_connectedStateExpiryDate;
	NSString *_serialNumber;
	unsigned long long _keySyncLastObservedIndex;
	NSDate *_keySyncLastIndexObservationDate;
	unsigned long long _keySyncWildIndexFallback;
	unsigned long long _keyAlignmentLastObservedIndex;
	NSDate *_keyAlignmentLastIndexObservationDate;
	long long _internalShareType;
	NSUUID *_ownerBeaconIdentifier;
}
@property (copy, nonatomic) NSUUID * identifier;
@property (copy, nonatomic) NSUUID * groupIdentifier;
@property (nonatomic, assign) long long partIdentifier;
@property (copy, nonatomic) NSString * stableIdentifier;
@property (copy, nonatomic) SPHandle * owner;
@property (nonatomic, assign) BOOL accepted;
@property (copy, nonatomic) NSDate * pairingDate;
@property (copy, nonatomic) NSString * name;
@property (copy, nonatomic) NSString * model;
@property (copy, nonatomic) SPBeaconRole * role;
@property (copy, nonatomic) SPLostModeInfo * lostModeInfo;
@property (copy, nonatomic) NSSet * shares;
@property (copy, nonatomic) NSDictionary * taskInformation;
@property (copy, nonatomic) NSString * correlationIdentifier;
@property (copy, nonatomic) NSString * systemVersion;
@property (copy, nonatomic) NSUUID * productUUID;
@property (nonatomic, assign) long long vendorId;
@property (nonatomic, assign) long long productId;
@property (copy, nonatomic) NSString * type;
@property (nonatomic, assign) BOOL isZeus;
@property (nonatomic, assign) BOOL canBeLeashedByHost;
@property (nonatomic, assign) BOOL connectionAllowed;
@property (nonatomic, assign) long long connectableDeviceCount;
@property (copy, nonatomic) NSDate * connectedStateExpiryDate;
@property (nonatomic, assign) BOOL connected;
@property (copy, nonatomic) NSString * separationState;
@property (nonatomic, assign) long long beaconSeparationState;
@property (copy, nonatomic) NSSet * safeLocations;
@property (copy, nonatomic) NSString * serialNumber;
@property (copy, nonatomic) NSSet * locationProviders;
@property (nonatomic, assign) unsigned long long keySyncLastObservedIndex;
@property (copy, nonatomic) NSDate * keySyncLastIndexObservationDate;
@property (nonatomic, assign) unsigned long long keySyncWildIndexFallback;
@property (nonatomic, assign) unsigned long long keyAlignmentLastObservedIndex;
@property (copy, nonatomic) NSDate * keyAlignmentLastIndexObservationDate;
@property (copy, nonatomic) SPDiscoveredAccessoryProductInformation * accessoryProductInfo;
@property (nonatomic, assign) long long internalShareType;
@property (copy, nonatomic) NSUUID * ownerBeaconIdentifier;
@property (nonatomic, assign) BOOL isAppleAudioAccessory;
@property (nonatomic, assign) long long batteryLevel;
+(BOOL)supportsSecureCoding;
+(id)SPOwner;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)debugDescription;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)name;
-(void)encodeWithCoder:(id)arg1;
-(id)identifier;
-(id)initWithCoder:(id)arg1;
-(void)setName:(id)arg1;
-(void)setOwner:(id)arg1;
-(void)setType:(id)arg1;
-(id)type;
-(id)role;
-(void)setIdentifier:(id)arg1;
-(id)groupIdentifier;
-(void)setGroupIdentifier:(id)arg1;
-(id)systemVersion;
-(id)owner;
-(id)serialNumber;
-(id)model;
-(void)setModel:(id)arg1;
-(BOOL)connected;
-(long long)productId;
-(void)setConnected:(BOOL)arg1;
-(void)setProductId:(long long)arg1;
-(void)setSerialNumber:(id)arg1;
-(void)setVendorId:(long long)arg1;
-(long long)vendorId;
-(id)correlationIdentifier;
-(void)setCorrelationIdentifier:(id)arg1;
-(void)setRole:(id)arg1;
-(void)setSystemVersion:(id)arg1;
-(long long)batteryLevel;
-(void)setBatteryLevel:(long long)arg1;
-(void)setStableIdentifier:(id)arg1;
-(id)stableIdentifier;
-(void)setAccepted:(BOOL)arg1;
-(id)shares;
-(BOOL)accepted;
-(id)keySyncLastIndexObservationDate;
-(id)separationState;
-(void)setProductUUID:(id)arg1;
-(id)taskInformation;
-(void)setPairingDate:(id)arg1;
-(id)accessoryProductInfo;
-(long long)beaconSeparationState;
-(BOOL)canBeLeashedByHost;
-(long long)connectableDeviceCount;
-(id)connectedStateExpiryDate;
-(BOOL)connectionAllowed;
-(long long)internalShareType;
-(BOOL)isAppleAudioAccessory;
-(BOOL)isZeus;
-(id)keyAlignmentLastIndexObservationDate;
-(unsigned long long)keyAlignmentLastObservedIndex;
-(unsigned long long)keySyncLastObservedIndex;
-(unsigned long long)keySyncWildIndexFallback;
-(id)locationProviders;
-(id)lostModeInfo;
-(id)ownerBeaconIdentifier;
-(id)pairingDate;
-(long long)partIdentifier;
-(id)productUUID;
-(id)safeLocations;
-(void)setAccessoryProductInfo:(id)arg1;
-(void)setBeaconSeparationState:(long long)arg1;
-(void)setCanBeLeashedByHost:(BOOL)arg1;
-(void)setConnectableDeviceCount:(long long)arg1;
-(void)setConnectedStateExpiryDate:(id)arg1;
-(void)setConnectionAllowed:(BOOL)arg1;
-(void)setInternalShareType:(long long)arg1;
-(void)setIsAppleAudioAccessory:(BOOL)arg1;
-(void)setIsZeus:(BOOL)arg1;
-(void)setKeyAlignmentLastIndexObservationDate:(id)arg1;
-(void)setKeyAlignmentLastObservedIndex:(unsigned long long)arg1;
-(void)setKeySyncLastIndexObservationDate:(id)arg1;
-(void)setKeySyncLastObservedIndex:(unsigned long long)arg1;
-(void)setKeySyncWildIndexFallback:(unsigned long long)arg1;
-(void)setLocationProviders:(id)arg1;
-(void)setLostModeInfo:(id)arg1;
-(void)setOwnerBeaconIdentifier:(id)arg1;
-(void)setPartIdentifier:(long long)arg1;
-(void)setSafeLocations:(id)arg1;
-(void)setSeparationState:(id)arg1;
-(void)setShares:(id)arg1;
-(void)setTaskInformation:(id)arg1;
@end
