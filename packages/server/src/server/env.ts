import * as macosVersion from "macos-version";

export const isMinSequoia = macosVersion.isGreaterThanOrEqualTo("15.0");
// macOS 14.4 is where Apple started encrypting the Find My location cache (and where the
// Private API helper stopped working for Find My). At/after this version we read locations
// by decrypting the cache instead of relying on the Private API injection.
export const isMinSonoma14_4 = macosVersion.isGreaterThanOrEqualTo("14.4");
export const isMinSonoma = macosVersion.isGreaterThanOrEqualTo("14.0");
export const isMinVentura = macosVersion.isGreaterThanOrEqualTo("13.0");
export const isMinMonterey = macosVersion.isGreaterThanOrEqualTo("12.0");
export const isMinBigSur = macosVersion.isGreaterThanOrEqualTo("11.0");
export const isMinCatalina = macosVersion.isGreaterThanOrEqualTo("10.15");
export const isMinMojave = macosVersion.isGreaterThanOrEqualTo("10.14");
export const isMinHighSierra = macosVersion.isGreaterThanOrEqualTo("10.13");
export const isMinSierra = macosVersion.isGreaterThanOrEqualTo("10.12");