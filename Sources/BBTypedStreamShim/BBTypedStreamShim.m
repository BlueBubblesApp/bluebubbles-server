#import "BBTypedStreamShim.h"

NSString *const BBTypedStreamErrorDomain = @"com.bluebubbles.typedstream";

static NSError *BBMakeError(BBTypedStreamErrorCode code, NSString *reason) {
    return [NSError errorWithDomain:BBTypedStreamErrorDomain
                               code:code
                           userInfo:reason ? @{ NSLocalizedFailureReasonErrorKey: reason } : nil];
}

BOOL BBTypedStreamUnarchiverIsAvailable(void) {
    return NSClassFromString(@"NSUnarchiver") != nil;
}

NSAttributedString *_Nullable BBUnarchiveAttributedString(NSData *data, NSError *_Nullable *_Nullable error) {
    if (!BBTypedStreamUnarchiverIsAvailable()) {
        if (error) *error = BBMakeError(BBTypedStreamErrorCodeUnavailable, @"NSUnarchiver is not present on this system");
        return nil;
    }

    id decoded = nil;
    @try {
        // Deliberately suppressed: NSUnarchiver is deprecated and is also the only reader for
        // this format. NSKeyedUnarchiver, which the deprecation points at, reads a DIFFERENT
        // format and cannot open these archives at all.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        decoded = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
    } @catch (NSException *exception) {
        // The whole point of this file. Without it, a torn row terminates the server.
        if (error) {
            *error = BBMakeError(BBTypedStreamErrorCodeArchiveInconsistent,
                                 [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        }
        return nil;
    }

    if (decoded == nil) {
        if (error) *error = BBMakeError(BBTypedStreamErrorCodeEmptyArchive, @"the archive decoded to nil");
        return nil;
    }
    if ([decoded isKindOfClass:[NSAttributedString class]]) {
        return (NSAttributedString *)decoded;
    }
    // Some rows archive a bare string rather than an attributed one.
    if ([decoded isKindOfClass:[NSString class]]) {
        return [[NSAttributedString alloc] initWithString:(NSString *)decoded];
    }

    if (error) {
        *error = BBMakeError(BBTypedStreamErrorCodeUnexpectedRootObject,
                             [NSString stringWithFormat:@"root object was %@", NSStringFromClass([decoded class])]);
    }
    return nil;
}
