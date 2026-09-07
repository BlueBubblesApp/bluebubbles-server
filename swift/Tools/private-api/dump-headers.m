//  dump-headers
//  Emits Objective-C headers for private classes, read from the RUNTIME on this machine.
//
//  The FindMy and IMCore headers this project used to work from were ktool dumps of an iOS
//  16 SDK, and they had drifted: they describe `FMFSessionDataManager`, which does not exist
//  on macOS 26, and omit `IMFindMyHandle` / `IMFindMyLocation` / `IMFindMyDevice`, which do.
//  A header that disagrees with the running system is worse than no header, because it is
//  read as authoritative.
//
//  So this reads the classes that are actually loaded, rather than parsing a binary. That
//  costs nothing in fidelity — `objc_copyMethodList` reports what the runtime will dispatch
//  — and it means the output can be regenerated on any macOS by running it there, which is
//  the whole point: one directory per OS version, checked in, diffable across releases.
//
//  Type encodings are decoded back into declarations. `@` becomes `id`, `q` becomes
//  `long long`, `@?` becomes a block, and a known class name recovered from a property's
//  attribute string is preferred over bare `id` where one is available.
//
//  Build and run through dump.sh, which also names the output directory after the running
//  macOS version.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// MARK: - Type encoding -> declaration

/// Decodes one Objective-C type encoding into something that reads as C.
///
/// Partial by design: struct and union encodings are passed through verbatim rather than
/// expanded, because expanding them needs field names the encoding does not carry, and a
/// half-invented struct body would be a lie in a file whose whole purpose is to be trusted.
static NSString *BBDecodeType(const char *encoding) {
    if (encoding == NULL || *encoding == '\0') { return @"void"; }

    // Method encodings carry qualifiers (`r` const, `n` in, `N` inout, ...) before the type.
    while (*encoding == 'r' || *encoding == 'n' || *encoding == 'N' || *encoding == 'o'
           || *encoding == 'O' || *encoding == 'R' || *encoding == 'V') {
        encoding++;
    }

    if (strncmp(encoding, "@?", 2) == 0) { return @"id /* block */"; }

    switch (encoding[0]) {
        case 'c': return @"char";            // BOOL on some ABIs; `B` is the C99 bool
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned int";
        case 'l': return @"long";
        case 'L': return @"unsigned long";
        case 'q': return @"long long";
        case 'Q': return @"unsigned long long";
        case 'f': return @"float";
        case 'd': return @"double";
        case 'B': return @"bool";
        case 'v': return @"void";
        case '*': return @"char *";
        case '#': return @"Class";
        case ':': return @"SEL";
        case '^': return [NSString stringWithFormat:@"%@ *", BBDecodeType(encoding + 1)];
        case '@': {
            // `@"NSString"` carries the class; bare `@` does not.
            if (encoding[1] == '"') {
                const char *close = strchr(encoding + 2, '"');
                if (close != NULL) {
                    NSString *name = [[NSString alloc]
                        initWithBytes:encoding + 2
                               length:(NSUInteger)(close - (encoding + 2))
                             encoding:NSUTF8StringEncoding];
                    // A protocol-qualified type reads as `id<Foo>`, not `Foo *`.
                    if ([name hasPrefix:@"<"]) { return [NSString stringWithFormat:@"id%@", name]; }
                    return [NSString stringWithFormat:@"%@ *", name];
                }
            }
            return @"id";
        }
        case '{': case '(': {
            // `{CLLocationCoordinate2D=dd}` -> `CLLocationCoordinate2D`. The name is real;
            // the field list is not reconstructed.
            const char *equals = strchr(encoding, '=');
            const char *end = strchr(encoding, encoding[0] == '{' ? '}' : ')');
            if (equals != NULL && (end == NULL || equals < end)) {
                return [[NSString alloc] initWithBytes:encoding + 1
                                                length:(NSUInteger)(equals - (encoding + 1))
                                              encoding:NSUTF8StringEncoding];
            }
            return @"struct /* opaque */";
        }
        default:
            return [NSString stringWithFormat:@"/* '%s' */ id", encoding];
    }
}

/// Splits a method's type encoding into its return type and argument types.
///
/// `method_copyArgumentType` is used rather than parsing the whole string by hand: the
/// encoding interleaves stack offsets with types, and skipping those correctly is exactly
/// the kind of detail that produces a plausible, wrong header.
static NSString *BBDeclarationForMethod(Method method, BOOL isClassMethod) {
    SEL selector = method_getName(method);
    NSString *name = NSStringFromSelector(selector);

    char *returnEncoding = method_copyReturnType(method);
    NSString *returnType = BBDecodeType(returnEncoding);
    free(returnEncoding);

    unsigned int argumentCount = method_getNumberOfArguments(method);
    NSMutableString *declaration = [NSMutableString stringWithFormat:@"%@ (%@)",
                                    isClassMethod ? @"+" : @"-", returnType];

    NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
    if (argumentCount <= 2) {
        [declaration appendString:name];
        [declaration appendString:@";"];
        return declaration;
    }

    // Argument 0 is self and 1 is _cmd; the explicit ones start at 2.
    for (unsigned int index = 2; index < argumentCount; index++) {
        char *argumentEncoding = method_copyArgumentType(method, index);
        NSString *argumentType = BBDecodeType(argumentEncoding);
        free(argumentEncoding);

        NSString *keyword = (index - 2) < parts.count ? parts[index - 2] : @"";
        [declaration appendFormat:@"%@%@:(%@)arg%u",
            index == 2 ? @"" : @" ", keyword, argumentType, index - 2];
    }
    [declaration appendString:@";"];
    return declaration;
}

// MARK: - Properties

static NSString *BBDeclarationForProperty(objc_property_t property) {
    NSString *name = @(property_getName(property));
    NSString *attributes = @(property_getAttributes(property));

    NSMutableArray<NSString *> *qualifiers = [NSMutableArray array];
    NSString *type = @"id";

    for (NSString *component in [attributes componentsSeparatedByString:@","]) {
        if (component.length == 0) { continue; }
        unichar tag = [component characterAtIndex:0];
        NSString *value = [component substringFromIndex:1];
        switch (tag) {
            case 'T': type = BBDecodeType(value.UTF8String); break;
            case 'R': [qualifiers addObject:@"readonly"]; break;
            case 'C': [qualifiers addObject:@"copy"]; break;
            case '&': [qualifiers addObject:@"retain"]; break;
            case 'W': [qualifiers addObject:@"weak"]; break;
            case 'N': [qualifiers addObject:@"nonatomic"]; break;
            default: break;
        }
    }
    if (qualifiers.count == 0) { [qualifiers addObject:@"assign"]; }

    BOOL pointer = [type hasSuffix:@"*"];
    return [NSString stringWithFormat:@"@property (%@) %@%@%@;",
            [qualifiers componentsJoinedByString:@", "],
            type, pointer ? @"" : @" ", name];
}

// MARK: - Emission

static NSString *BBHeaderForClass(NSString *className) {
    Class cls = NSClassFromString(className);
    NSMutableString *out = [NSMutableString string];

    if (cls == NULL) {
        [out appendFormat:@"// %@ is NOT PRESENT on this system.\n", className];
        return out;
    }

    const char *image = class_getImageName(cls);
    Class superclass = class_getSuperclass(cls);

    [out appendFormat:@"// Image: %s\n", image ?: "unknown"];

    unsigned int protocolCount = 0;
    __unsafe_unretained Protocol **protocols = class_copyProtocolList(cls, &protocolCount);
    NSMutableArray<NSString *> *protocolNames = [NSMutableArray array];
    for (unsigned int i = 0; i < protocolCount; i++) {
        [protocolNames addObject:@(protocol_getName(protocols[i]))];
    }
    free(protocols);

    [out appendFormat:@"@interface %@ : %@%@\n\n",
        className,
        superclass ? NSStringFromClass(superclass) : @"/* root */",
        protocolNames.count > 0
            ? [NSString stringWithFormat:@" <%@>", [protocolNames componentsJoinedByString:@", "]]
            : @""];

    unsigned int propertyCount = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
    NSMutableArray<NSString *> *propertyLines = [NSMutableArray array];
    for (unsigned int i = 0; i < propertyCount; i++) {
        [propertyLines addObject:BBDeclarationForProperty(properties[i])];
    }
    free(properties);
    [propertyLines sortUsingSelector:@selector(compare:)];
    for (NSString *line in propertyLines) { [out appendFormat:@"%@\n", line]; }
    if (propertyLines.count > 0) { [out appendString:@"\n"]; }

    // Class methods live on the metaclass.
    unsigned int classMethodCount = 0;
    Method *classMethods = class_copyMethodList(object_getClass(cls), &classMethodCount);
    NSMutableArray<NSString *> *classLines = [NSMutableArray array];
    for (unsigned int i = 0; i < classMethodCount; i++) {
        [classLines addObject:BBDeclarationForMethod(classMethods[i], YES)];
    }
    free(classMethods);
    [classLines sortUsingSelector:@selector(compare:)];
    for (NSString *line in classLines) { [out appendFormat:@"%@\n", line]; }
    if (classLines.count > 0) { [out appendString:@"\n"]; }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (unsigned int i = 0; i < methodCount; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        // ARC's destructor is an artifact of compilation, not part of the interface.
        if ([name isEqualToString:@".cxx_destruct"]) { continue; }
        [lines addObject:BBDeclarationForMethod(methods[i], NO)];
    }
    free(methods);
    [lines sortUsingSelector:@selector(compare:)];
    for (NSString *line in lines) { [out appendFormat:@"%@\n", line]; }

    [out appendString:@"\n@end\n"];
    return out;
}

static NSString *BBHeaderForProtocol(NSString *protocolName) {
    Protocol *proto = NSProtocolFromString(protocolName);
    NSMutableString *out = [NSMutableString string];
    if (proto == NULL) {
        [out appendFormat:@"// %@ is NOT PRESENT on this system.\n", protocolName];
        return out;
    }

    [out appendFormat:@"@protocol %@\n\n", protocolName];
    // required/optional x instance/class. Optional is the interesting half for a delegate.
    struct { BOOL required; BOOL instance; NSString *banner; } passes[] = {
        {YES, YES, @"// required"},
        {NO,  YES, @"@optional"},
    };
    for (int pass = 0; pass < 2; pass++) {
        unsigned int count = 0;
        struct objc_method_description *descriptions =
            protocol_copyMethodDescriptionList(proto, passes[pass].required,
                                               passes[pass].instance, &count);
        if (count > 0) { [out appendFormat:@"%@\n", passes[pass].banner]; }
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(descriptions[i].name);
            NSArray<NSString *> *parts = [name componentsSeparatedByString:@":"];
            NSMutableString *line = [NSMutableString stringWithString:@"- (void)"];
            if (parts.count <= 1) {
                [line appendString:name];
            } else {
                for (NSUInteger p = 0; p + 1 < parts.count; p++) {
                    [line appendFormat:@"%@%@:(id)arg%lu",
                        p == 0 ? @"" : @" ", parts[p], (unsigned long)p];
                }
            }
            [line appendString:@";"];
            [lines addObject:line];
        }
        free(descriptions);
        [lines sortUsingSelector:@selector(compare:)];
        for (NSString *line in lines) { [out appendFormat:@"%@\n", line]; }
        if (count > 0) { [out appendString:@"\n"]; }
    }
    [out appendString:@"@end\n"];
    return out;
}

// MARK: - Driver

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr,
                "usage: dump-headers <output-directory> <Class|@Protocol> [...]\n"
                "  set BB_DUMP_FRAMEWORKS to a colon-separated list of framework binaries to\n"
                "  dlopen first; a class in a framework nothing has loaded reads as absent.\n");
            return 64;
        }

        // The classes have to be loaded before the runtime can see them, and a class in a
        // framework nothing pulled in reads as absent — indistinguishable from one Apple
        // removed. The FindMy and IMCore defaults are loaded always; anything else the
        // caller needs (TelephonyUtilities for FaceTime) comes through BB_DUMP_FRAMEWORKS,
        // so the tool stays general rather than growing a hardcoded list per feature.
        //
        // WHICH COPY of a framework you get is decided by the PLATFORM OF THIS PROCESS, not
        // by the path named here. Several private frameworks ship twice — once under
        // /System/Library and once under /System/iOSSupport for Catalyst — and a Catalyst
        // process asking for the /System/Library path is redirected to the iOSSupport one.
        // A macOS process cannot reach the iOSSupport copy at all ("wrong platform to load
        // into process"); it silently gets the macOS copy, which is a DIFFERENT class (on
        // 26.5.2 the two IMChats differ by 36 members). That is why dump.sh builds this
        // file twice, once per platform, and picks the build that matches the host app.
        // The emitted `// Image:` line records which copy actually answered.
        const char *frameworks[] = {
            "/System/Library/PrivateFrameworks/IMCore.framework/IMCore",
            "/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities",
            "/System/Library/PrivateFrameworks/FindMyLocateObjCWrapper.framework/FindMyLocateObjCWrapper",
            NULL
        };
        for (int i = 0; frameworks[i] != NULL; i++) {
            if (dlopen(frameworks[i], RTLD_LAZY) == NULL) {
                fprintf(stderr, "warning: could not load %s\n", frameworks[i]);
            }
        }

        const char *extra = getenv("BB_DUMP_FRAMEWORKS");
        if (extra != NULL && *extra != '\0') {
            for (NSString *path in [@(extra) componentsSeparatedByString:@":"]) {
                if (path.length == 0) { continue; }
                if (dlopen(path.UTF8String, RTLD_LAZY) == NULL) {
                    fprintf(stderr, "warning: could not load %s: %s\n",
                            path.UTF8String, dlerror());
                }
            }
        }

        NSString *directory = @(argv[1]);
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&error]) {
            fprintf(stderr, "error: %s\n", error.localizedDescription.UTF8String);
            return 74;
        }

        NSOperatingSystemVersion version =
            NSProcessInfo.processInfo.operatingSystemVersion;
        NSString *banner = [NSString stringWithFormat:
            @"// Generated by swift/Tools/private-api on macOS %ld.%ld.%ld.\n"
            @"// Read from the Objective-C runtime, not from a binary — see dump-headers.m.\n"
            @"// DO NOT EDIT: regenerate with Tools/private-api/dump-headers.sh.\n\n",
            (long)version.majorVersion, (long)version.minorVersion,
            (long)version.patchVersion];

        for (int i = 2; i < argc; i++) {
            NSString *name = @(argv[i]);
            BOOL isProtocol = [name hasPrefix:@"@"];
            if (isProtocol) { name = [name substringFromIndex:1]; }

            NSString *body = isProtocol ? BBHeaderForProtocol(name) : BBHeaderForClass(name);
            NSString *path = [directory stringByAppendingPathComponent:
                              [name stringByAppendingPathExtension:@"h"]];
            NSString *contents = [banner stringByAppendingString:body];
            if (![contents writeToFile:path atomically:YES
                              encoding:NSUTF8StringEncoding error:&error]) {
                fprintf(stderr, "error writing %s: %s\n",
                        path.UTF8String, error.localizedDescription.UTF8String);
                return 74;
            }
            printf("%s %s\n",
                   [body hasPrefix:@"// "] && [body containsString:@"NOT PRESENT"]
                       ? "absent " : "wrote  ",
                   path.UTF8String);
        }
    }
    return 0;
}
