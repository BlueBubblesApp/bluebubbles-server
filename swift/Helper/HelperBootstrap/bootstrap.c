#include "include/HelperBootstrap.h"

extern void bluebubbles_helper_main(void);

__attribute__((constructor))
static void bluebubbles_helper_constructor(void) {
    bluebubbles_helper_main();
}
