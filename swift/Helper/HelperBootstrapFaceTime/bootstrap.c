#include "include/HelperBootstrapFaceTime.h"

extern void bluebubbles_facetime_helper_main(void);

//  The FaceTime helper's dylib constructor.
//
//  A distinct symbol from the Messages helper's `bluebubbles_helper_main`, so the two dylibs
//  can be linked into one binary (the test bundle does exactly that) without a duplicate
//  symbol. In production each is its own dylib and either name would do; the distinct name is
//  what keeps `swift test` linkable.
__attribute__((constructor))
static void bluebubbles_facetime_helper_constructor(void) {
    bluebubbles_facetime_helper_main();
}
