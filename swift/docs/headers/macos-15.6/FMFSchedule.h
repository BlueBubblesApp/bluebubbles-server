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

#import "FMF_Structs.h"

#import <FMF/NSSecureCoding-Protocol.h>
#import <FMF/NSCopying-Protocol.h>

@interface FMFSchedule : NSObject <NSSecureCoding, NSCopying> {

	NSCalendar *_gregorian;
	unsigned long long _startHour;
	unsigned long long _startMin;
	long long _daysOfWeek;
	unsigned long long _endHour;
	unsigned long long _endMin;
	unsigned long long _spanDays;
	NSTimeZone *_timeZone;
}
@property (readonly, nonatomic) NSString * localizedDaysOfWeekString;
@property (readonly, nonatomic) NSString * localizedStartTimeString;
@property (readonly, nonatomic) NSString * localizedEndTimeString;
@property (readonly, nonatomic) NSCalendar * _gregorian;
@property (readonly, nonatomic) NSDictionary * dictionary;
@property (readonly) NSString * validityError;
@property (nonatomic, assign) unsigned long long startHour;
@property (nonatomic, assign) unsigned long long startMin;
@property (nonatomic, assign) long long daysOfWeek;
@property (nonatomic, assign) unsigned long long endHour;
@property (nonatomic, assign) unsigned long long endMin;
@property (nonatomic, assign) unsigned long long spanDays;
@property (retain, nonatomic) NSTimeZone * timeZone;
+(BOOL)supportsSecureCoding;
+(id)_dateFromHour:(unsigned long long)arg1 andMinute:(unsigned long long)arg2;
+(id)_dayStringForDayOfWeek:(long long)arg1;
+(void)_enumerateDaysOfWeekInFMFDaysOfWeek:(long long)arg1 callback:(void (^)(void))arg2;
+(id)_stringForDaysOfWeek:(long long)arg1;
+(id)firstDateFromDates:(id)arg1 order:(long long)arg2;
+(id)localizedDaysOfWeekStringFor:(long long)arg1;
+(id)localizedTimeStringForHour:(unsigned long long)arg1 andMinute:(unsigned long long)arg2;
+(id)localizedTimeStringForHour:(unsigned long long)arg1 andMinute:(unsigned long long)arg2 timeStyle:(unsigned long long)arg3;
-(id)copyWithZone:(struct _NSZone *)arg1;
-(id)description;
-(unsigned long long)hash;
-(BOOL)isEqual:(id)arg1;
-(id)dictionary;
-(void)encodeWithCoder:(id)arg1;
-(id)initWithCoder:(id)arg1;
-(id)initWithDictionary:(id)arg1;
-(void)setTimeZone:(id)arg1;
-(id)timeZone;
-(id)_daysOfWeek;
-(long long)daysOfWeek;
-(void)setDaysOfWeek:(long long)arg1;
-(void)setEndHour:(unsigned long long)arg1;
-(void)setStartHour:(unsigned long long)arg1;
-(unsigned long long)endHour;
-(id)_endDateForStartDate:(id)arg1;
-(id)_gregorian;
-(id)_nextStartDateOnDayOfWeek:(long long)arg1 from:(id)arg2 options:(unsigned long long)arg3;
-(unsigned long long)endMin;
-(BOOL)isCurrentAt:(id)arg1;
-(id)localizedDaysOfWeekString;
-(id)localizedEndTimeString;
-(id)localizedStartTimeString;
-(id)nextStartDateFrom:(id)arg1 options:(unsigned long long)arg2;
-(id)nextStartOrEndDateFrom:(id)arg1;
-(id)previousStartDateFrom:(id)arg1;
-(void)setEndMin:(unsigned long long)arg1;
-(void)setSpanDays:(unsigned long long)arg1;
-(void)setStartMin:(unsigned long long)arg1;
-(unsigned long long)spanDays;
-(unsigned long long)startHour;
-(unsigned long long)startMin;
-(id)validityError;
@end
