//  Exports
//  Everything in `BBTestCore` is part of this target's surface too.
//
//  The light helpers (the source scanner, the repository's paths, policy rules, the test clock
//  and the waits) live in `BBTestCore` so a test target that needs only those does not depend
//  on the domain modules this target links. A target that imports this one keeps reaching them
//  without a second import.

@_exported import BBTestCore
