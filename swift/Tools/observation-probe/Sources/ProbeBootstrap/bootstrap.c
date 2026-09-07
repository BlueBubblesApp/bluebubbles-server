//  bootstrap.c
//  The dylib constructor.
//
//  A dylib loaded through DYLD_INSERT_LIBRARIES gets no cooperation from the host process —
//  Messages.app will never call into us — so something has to run at load time. Swift has no
//  portable way to declare a constructor, hence four lines of C.
//
//  This is the ONLY code here that runs on Messages.app's load path, so it does the minimum:
//  call into Swift and return. Anything slow or fallible belongs in Probe.swift, where a
//  failure degrades the probe rather than the host.

extern void probe_main(void);

__attribute__((constructor))
static void bluebubbles_probe_constructor(void) {
    probe_main();
}
