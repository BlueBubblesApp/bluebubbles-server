//  probe
//  Asks the Objective-C runtime three questions about the private frameworks on this Mac.
//
//  This is the tool for "does anything, anywhere, know the word `wallpaper`" — the question
//  you ask BEFORE you know which class to point dump-headers at. It replaces three
//  throwaway scripts that each answered one of these and drifted apart.
//
//      probe classes   [pattern ...]   every class, and the image it came from
//      probe selectors <pattern ...>   every selector matching any pattern
//      probe members   <Class ...>     how much ObjC surface a class actually has
//
//  `members` exists for one specific trap. Large parts of FindMy (FMIPCore, FMFCore) and of
//  FindMyLocate are PURE SWIFT: the class name resolves, `NSClassFromString` succeeds, and
//  the class has zero methods the runtime will dispatch. Header-dumping such a class emits
//  an empty @interface that reads as "exists, has no API", which is worse than absent. Run
//  `members` first; a 0/0/0 row means no selector-based approach will ever reach it.
//
//  Output is TSV so it pipes into cut/sort/grep without quoting games.
//
//  Build and run through probe.sh, which handles the Catalyst-vs-macOS choice.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static void BBLoadFrameworks(void) {
    const char *list = getenv("BB_PROBE_FRAMEWORKS");
    if (list == NULL || *list == '\0') { return; }
    for (NSString *path in [@(list) componentsSeparatedByString:@":"]) {
        if (path.length == 0) { continue; }
        if (dlopen(path.UTF8String, RTLD_LAZY) == NULL) {
            fprintf(stderr, "warning: could not load %s: %s\n", path.UTF8String, dlerror());
        }
    }
}

static NSString *BBImageName(Class cls) {
    const char *image = class_getImageName(cls);
    return image ? @(image).lastPathComponent : @"?";
}

/// Case-insensitive substring match against any of the patterns; no patterns matches all.
static BOOL BBMatches(NSString *haystack, NSArray<NSString *> *patterns) {
    if (patterns.count == 0) { return YES; }
    for (NSString *pattern in patterns) {
        if ([haystack rangeOfString:pattern
                            options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static int BBClasses(NSArray<NSString *> *patterns) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        NSString *image = BBImageName(classes[i]);
        // Either half may match, so `probe classes IMCore` lists a framework's whole
        // contents and `probe classes IMChat` finds one class wherever it lives.
        if (BBMatches(name, patterns) || BBMatches(image, patterns)) {
            printf("%s\t%s\n", image.UTF8String, name.UTF8String);
        }
    }
    free(classes);
    return 0;
}

static int BBSelectors(NSArray<NSString *> *patterns) {
    if (patterns.count == 0) {
        fprintf(stderr, "error: selectors needs at least one pattern\n");
        return 64;
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *className = NSStringFromClass(classes[i]);
        NSString *image = BBImageName(classes[i]);
        // Instance methods live on the class, class methods on the metaclass. Missing the
        // second pass hides every `+sharedInstance`-style entry point, which is usually the
        // one you were looking for.
        for (int pass = 0; pass < 2; pass++) {
            Class target = pass ? object_getClass(classes[i]) : classes[i];
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(target, &methodCount);
            for (unsigned int j = 0; j < methodCount; j++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[j]));
                if (BBMatches(selector, patterns)) {
                    printf("%s\t%s\t%s%s\n", image.UTF8String, className.UTF8String,
                           pass ? "+" : "-", selector.UTF8String);
                }
            }
            free(methods);
        }
    }
    free(classes);
    return 0;
}

static int BBMembers(NSArray<NSString *> *names) {
    if (names.count == 0) {
        fprintf(stderr, "error: members needs at least one class name\n");
        return 64;
    }
    printf("class\tinstance\tclass_methods\tproperties\timage\n");
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (cls == NULL) {
            printf("%s\tABSENT\tABSENT\tABSENT\t-\n", name.UTF8String);
            continue;
        }
        unsigned int instanceCount = 0, classCount = 0, propertyCount = 0;
        Method *methods = class_copyMethodList(cls, &instanceCount); free(methods);
        methods = class_copyMethodList(object_getClass(cls), &classCount); free(methods);
        objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
        free(properties);
        printf("%s\t%u\t%u\t%u\t%s\n", name.UTF8String,
               instanceCount, classCount, propertyCount, BBImageName(cls).UTF8String);
    }
    return 0;
}

static int BBProtocols(NSArray<NSString *> *patterns) {
    unsigned int count = 0;
    Protocol * __unsafe_unretained *protocols = objc_copyProtocolList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = @(protocol_getName(protocols[i]));
        if (BBMatches(name, patterns)) { printf("%s\n", name.UTF8String); }
    }
    free(protocols);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "usage: probe <classes|selectors|members|protocols> [argument ...]\n"
                "  set BB_PROBE_FRAMEWORKS to a colon-separated list of framework binaries\n"
                "  to dlopen first; a class in a framework nothing loaded reads as absent.\n");
            return 64;
        }
        BBLoadFrameworks();

        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        for (int i = 2; i < argc; i++) { [arguments addObject:@(argv[i])]; }

        NSString *command = @(argv[1]);
        if ([command isEqualToString:@"classes"])   { return BBClasses(arguments); }
        if ([command isEqualToString:@"selectors"]) { return BBSelectors(arguments); }
        if ([command isEqualToString:@"members"])   { return BBMembers(arguments); }
        if ([command isEqualToString:@"protocols"]) { return BBProtocols(arguments); }

        fprintf(stderr, "error: unknown command '%s'\n", argv[1]);
        return 64;
    }
}
