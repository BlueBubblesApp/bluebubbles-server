//  BBTypedStreamShim
//  An exception barrier around NSUnarchiver.
//
//  `message.attributedBody` holds a `typedstream` archive, and NSUnarchiver is the only thing
//  on the system that reads that format. It is also unsafe to call directly from Swift: on a
//  truncated or malformed archive it raises `NSArchiverArchiveInconsistency`, an Objective-C
//  exception. Swift cannot catch those, so the process terminates — measured, not assumed:
//  a 13-byte truncated archive aborts with SIGABRT.
//
//  chat.db is a live database being written by another process while we read it, and rows do
//  get torn. One corrupt attributedBody must cost one message's formatting, never the server.
//
//  So this file exists for exactly one reason: @try/@catch is available here and nowhere else.
//  It is deliberately the thinnest possible wrapper — no parsing, no policy, no allocation
//  beyond what Foundation does.

#ifndef BB_TYPEDSTREAM_SHIM_H
#define BB_TYPEDSTREAM_SHIM_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for failures originating in this shim.
extern NSString *const BBTypedStreamErrorDomain;

typedef NS_ENUM(NSInteger, BBTypedStreamErrorCode) {
    /// NSUnarchiver raised. `userInfo[NSLocalizedFailureReasonErrorKey]` carries its reason.
    BBTypedStreamErrorCodeArchiveInconsistent = 1,
    /// It returned an object, but not a string-shaped one.
    BBTypedStreamErrorCodeUnexpectedRootObject = 2,
    /// It returned nil without raising.
    BBTypedStreamErrorCodeEmptyArchive = 3,
    /// NSUnarchiver is not present on this system.
    BBTypedStreamErrorCodeUnavailable = 4
};

/// Decodes a `typedstream` archive into its attributed string.
///
/// Returns nil and populates `error` on any failure, including one that would otherwise have
/// terminated the process.
NSAttributedString *_Nullable BBUnarchiveAttributedString(NSData *data, NSError *_Nullable *_Nullable error);

/// Whether NSUnarchiver exists on this system.
///
/// It has been deprecated since macOS 10.13 and is still present as of macOS 26, but a
/// deprecated API is one that can be removed. Checked at runtime so its removal degrades to a
/// reported failure rather than a launch-time crash.
BOOL BBTypedStreamUnarchiverIsAvailable(void);

NS_ASSUME_NONNULL_END

#endif
