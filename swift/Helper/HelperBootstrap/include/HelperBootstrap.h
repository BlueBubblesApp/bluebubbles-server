//  HelperBootstrap
//  The dylib constructor for the injected helper.
//
//  A dylib loaded through DYLD_INSERT_LIBRARIES gets no cooperation from its host —
//  Messages.app will never call into us — so something has to run at load time. Swift has no
//  portable way to declare a constructor, hence a few lines of C.
//
//  This is the ONLY code that runs on Messages.app's load path, so it does the minimum: hand
//  off to Swift and return. Anything slow or fallible belongs on the Swift side, where a
//  failure degrades the helper rather than the host application.

#ifndef BLUEBUBBLES_HELPER_BOOTSTRAP_H
#define BLUEBUBBLES_HELPER_BOOTSTRAP_H

#endif
