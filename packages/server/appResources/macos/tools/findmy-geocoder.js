// Reverse geocodes coordinates with Apple's on-device CLGeocoder, through the
// JavaScript for Automation bridge that ships with macOS. Run as:
//   osascript -l JavaScript findmy-geocoder.js
// Input (stdin): one "latitude longitude" pair per line.
// Output (stdout): one JSON object per resolved line, in input order: {"i", "short", "long"}.
// Lines that are malformed or that Apple cannot place produce no output.
ObjC.import("CoreLocation");
ObjC.import("Foundation");

function clean(value) {
    if (!value || value.isNil()) return null;
    const trimmed = ObjC.unwrap(value).trim();
    return trimmed.length > 0 ? trimmed : null;
}

function reverseGeocode(geocoder, latitude, longitude) {
    let placemark = null;
    let finished = false;
    const location = $.CLLocation.alloc.initWithLatitudeLongitude(latitude, longitude);
    geocoder.reverseGeocodeLocationCompletionHandler(location, (placemarks, error) => {
        if ((!error || error.isNil()) && placemarks && placemarks.count > 0) placemark = placemarks.objectAtIndex(0);
        finished = true;
    });

    const deadline = $.NSDate.dateWithTimeIntervalSinceNow(5.0);
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode, $.NSDate.dateWithTimeIntervalSinceNow(0.05));
    }
    if (!finished) geocoder.cancelGeocode;
    return placemark;
}

function labels(placemark) {
    // Short: "City, ST", falling back to region or country. Long: street or venue, else short.
    const locality = clean(placemark.locality);
    const area = clean(placemark.administrativeArea);
    const shortLabel = locality && area ? `${locality}, ${area}` : locality || area || clean(placemark.country);
    if (!shortLabel) return null;

    const street = clean(placemark.thoroughfare);
    const number = clean(placemark.subThoroughfare);
    const name = clean(placemark.name);
    const longLabel = street ? (name && name.includes(street) ? name : number ? `${number} ${street}` : street) : name;
    return { short: shortLabel, long: longLabel || shortLabel };
}

function run() {
    const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding)) || "";
    const stdout = $.NSFileHandle.fileHandleWithStandardOutput;
    const geocoder = $.CLGeocoder.alloc.init;

    const lines = text.split("\n");
    if (lines[lines.length - 1] === "") lines.pop();
    lines.forEach((line, index) => {
        const parts = line.trim().split(/\s+/).map(Number);
        const [latitude, longitude] = parts;
        if (
            parts.length !== 2 ||
            !Number.isFinite(latitude) ||
            !Number.isFinite(longitude) ||
            Math.abs(latitude) > 90 ||
            Math.abs(longitude) > 180
        ) {
            return;
        }

        const placemark = reverseGeocode(geocoder, latitude, longitude);
        const result = placemark ? labels(placemark) : null;
        if (!result) return;

        const json = JSON.stringify({ i: index, short: result.short, long: result.long }) + "\n";
        stdout.writeData($(json).dataUsingEncoding($.NSUTF8StringEncoding));
    });

    // osascript prints a script's return value; return nothing so stdout stays JSON lines.
    return undefined;
}
