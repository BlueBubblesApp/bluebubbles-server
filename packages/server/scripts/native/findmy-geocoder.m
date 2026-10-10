// Reverse geocodes coordinates with Apple's on-device CLGeocoder.
// Input (stdin): one "latitude longitude" pair per line.
// Output (stdout): one JSON object per resolved line, in input order: {"i", "short", "long"}.
// Build: clang -fobjc-arc -arch x86_64 -arch arm64 -mmacosx-version-min=12.0 \
//   -framework Foundation -framework CoreLocation findmy-geocoder.m -o findmy-geocoder
#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

static NSString *Clean(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return trimmed.length > 0 ? trimmed : nil;
}

int main(void) {
    @autoreleasepool {
        CLGeocoder *geocoder = [[CLGeocoder alloc] init];
        char line[256];
        int index = -1;

        while (fgets(line, sizeof(line), stdin) != NULL) {
            index++;
            double latitude, longitude;
            if (sscanf(line, "%lf %lf", &latitude, &longitude) != 2 || !isfinite(latitude) || !isfinite(longitude) ||
                fabs(latitude) > 90 || fabs(longitude) > 180) {
                continue;
            }

            __block CLPlacemark *placemark = nil;
            __block BOOL finished = NO;
            CLLocation *location = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
            [geocoder reverseGeocodeLocation:location
                           completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
                             placemark = error ? nil : placemarks.firstObject;
                             finished = YES;
                           }];

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
            while (!finished && deadline.timeIntervalSinceNow > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            if (!finished) [geocoder cancelGeocode];
            if (placemark == nil) continue;

            // Short: "City, ST", falling back to region or country. Long: street or venue, else short.
            NSString *locality = Clean(placemark.locality);
            NSString *area = Clean(placemark.administrativeArea);
            NSString *shortLabel = locality && area ? [NSString stringWithFormat:@"%@, %@", locality, area]
                                                    : (locality ?: area ?: Clean(placemark.country));
            if (shortLabel == nil) continue;

            NSString *street = Clean(placemark.thoroughfare);
            NSString *number = Clean(placemark.subThoroughfare);
            NSString *name = Clean(placemark.name);
            NSString *longLabel = street ? (name && [name containsString:street]
                                                ? name
                                                : (number ? [NSString stringWithFormat:@"%@ %@", number, street] : street))
                                         : name;

            NSDictionary *result = @{ @"i" : @(index), @"short" : shortLabel, @"long" : longLabel ?: shortLabel };
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            fflush(stdout);
        }
        return 0;
    }
}
