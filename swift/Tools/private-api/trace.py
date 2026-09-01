"""lldb commands for reading what a private method actually does.

A runtime header dump gives you a selector and a row of `id` arguments. That is often not
enough: `-[IMChat setTranscriptBackgroundAndSendToChat:transferID:]` takes two `id`s, and
knowing that the first is a *file URL string* and the second an IMFileTransfer GUID is the
difference between implementing it and guessing at it.

Two commands, both read-only — they disassemble, they never call anything:

    sels   [+]<Class> <selector> [instructions]
        Walks the method's BL instructions and resolves each `objc_msgSend$foo` stub back
        to its selector name, so a call graph falls out of a method whose source you cannot
        see. Prefix the class with + for a class method.

    consts [+]<Class> <selector> [instructions]
        The same walk, reporting NSString constants instead: GOT-loaded globals and inline
        CFStrings. This is where key names come from — "trabaid", "backgroundProperties",
        "com.apple.icloud.fmfd" were all recovered this way.

Both stop at the first unconditional branch. These methods usually tail-call rather than
return, and without that stop they run on into whatever function was linked next — which
reads as a plausible, wrong call graph.

Driven by trace.sh; see docs/private-api/tools.md for manual invocation.
"""

import struct

import lldb

# AArch64 encodings, matched by mask rather than through a disassembler: these five forms
# are all that is needed, and doing it by hand keeps the tool to one dependency-free file.
_BL = (0xFC000000, 0x94000000)          # bl <offset>
_B = (0xFC000000, 0x14000000)           # b <offset>, i.e. a tail call
_ADRP = (0x9F000000, 0x90000000)        # adrp xd, <page>
_LDR_IMM = (0xFFC00000, 0xF9400000)     # ldr xt, [xn, #offset]
_ADD_IMM = (0xFF800000, 0x91000000)     # add xd, xn, #imm
_RET = (0xD65F03C0, 0xD65F0FFF)         # ret, retab


def _emit(result, message):
    """Writes one message out.

    `print`, not `result.AppendMessage`, and it took a while to be sure of that.
    AppendMessage is the documented way for a script command to return output, but under
    `lldb --batch` — which is how trace.sh runs — it produces NOTHING. That silently
    swallowed every message on the failure paths, so a mistyped selector printed an empty
    report rather than saying the selector does not exist. Writing to both duplicated every
    line instead. `print` alone reaches the terminal in batch and interactive sessions
    equally, so `result` is accepted and ignored.
    """
    del result
    print(message)


def _matches(word, form):
    mask, value = form
    return word & mask == value


def _adrp_page(word, pc):
    immediate = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 3)
    if immediate & (1 << 20):
        immediate -= 1 << 21
    return ((pc >> 12) + immediate) << 12


def _implementation(frame, class_name, selector):
    """Address of a method's IMP, or 0 when the class does not implement it."""
    is_class_method = class_name.startswith("+")
    bare = class_name.lstrip("+")
    # Class methods live on the metaclass; asking the class for one returns the message
    # forwarding trampoline, which is a real address that disassembles into a plausible
    # few lines.
    target = (
        'object_getClass((id)objc_getClass("%s"))' % bare
        if is_class_method
        else 'objc_getClass("%s")' % bare
    )
    # class_getInstanceMethod, NOT class_getMethodImplementation. The latter answers a
    # selector the class does not implement with that same trampoline, so a typo in a
    # selector silently produces output instead of an error.
    method = frame.EvaluateExpression(
        '(void*)class_getInstanceMethod((Class)%s, (SEL)sel_registerName("%s"))'
        % (target, selector)
    ).GetValueAsUnsigned()
    if not method:
        return 0
    return frame.EvaluateExpression(
        "(void*)method_getImplementation((struct objc_method *)%d)" % method
    ).GetValueAsUnsigned()


def _selector_for_stub(process, frame, address):
    """Decodes an `objc_msgSend$foo` stub back to `foo`, or None."""
    error = lldb.SBError()
    raw = process.ReadMemory(address, 8, error)
    if error.Fail() or not raw:
        return None
    first, second = struct.unpack("<II", raw)
    if not (_matches(first, _ADRP) and _matches(second, _LDR_IMM)):
        return None
    slot = _adrp_page(first, address) + ((second >> 10) & 0xFFF) * 8
    pointer = process.ReadMemory(slot, 8, lldb.SBError())
    if not pointer:
        return None
    value = struct.unpack("<Q", pointer)[0]
    return frame.EvaluateExpression("(char*)sel_getName((SEL)%d)" % value).GetSummary()


def _read_string(frame, address):
    """The value of an NSString at `address`, or None if it is not one.

    Two filters, both learned the hard way. The class check stops every pointer-sized
    global that happens to be readable from being sent through -UTF8String; the printable
    check catches the ones that survive it anyway and come back as escape soup. A constant
    worth finding has never needed more than printable ASCII.
    """
    class_name = frame.EvaluateExpression(
        "(char*)object_getClassName((id)%d)" % address
    ).GetSummary()
    if not class_name or "String" not in class_name:
        return None
    text = frame.EvaluateExpression("(char*)[(id)%d UTF8String]" % address).GetSummary()
    if not text:
        return None
    body = text.strip('"')
    if not body or not all(" " <= character <= "~" for character in body):
        return None
    return text


def _walk(command, result, want):
    arguments = command.split()
    if len(arguments) < 2:
        _emit(result, "usage: %s [+]<Class> <selector> [instructions]" % want)
        return
    class_name, selector = arguments[0], arguments[1]
    limit = int(arguments[2]) if len(arguments) > 2 else 400

    target = lldb.debugger.GetSelectedTarget()
    process = target.GetProcess()
    frame = process.GetSelectedThread().GetSelectedFrame()

    address = _implementation(frame, class_name, selector)
    if not address:
        _emit(result, "%s does not implement %s here. If you expected it to, the framework "
                      "holding it is probably not loaded — try --host, or --load."
                      % (class_name, selector))
        return

    error = lldb.SBError()
    code = process.ReadMemory(address, limit * 4, error)
    if error.Fail():
        _emit(result, "could not read %s: %s" % (hex(address), error))
        return

    lines = []
    pages = {}
    seen = []
    for index in range(limit):
        word = struct.unpack_from("<I", code, index * 4)[0]
        pc = address + index * 4
        offset = index * 4

        if want == "sels" and _matches(word, _BL):
            branch = word & 0x03FFFFFF
            if branch & (1 << 25):
                branch -= 1 << 26
            destination = pc + branch * 4
            name = _selector_for_stub(process, frame, destination)
            if name:
                lines.append("+%-5d msgSend %s" % (offset, name))
            else:
                symbol = target.ResolveLoadAddress(destination).GetSymbol().GetName()
                lines.append("+%-5d call    %s" % (offset, symbol or hex(destination)))

        elif want == "consts":
            if _matches(word, _ADRP):
                pages[word & 0x1F] = _adrp_page(word, pc)
            elif _matches(word, _LDR_IMM):
                base = (word >> 5) & 0x1F
                if base in pages:
                    cursor = pages.pop(base) + ((word >> 10) & 0xFFF) * 8
                    # Two hops: the GOT slot holds a pointer to the global, which holds the
                    # NSString. Which depth applies varies, so both are tried.
                    for _ in range(2):
                        raw = process.ReadMemory(cursor, 8, lldb.SBError())
                        if not raw:
                            break
                        cursor = struct.unpack("<Q", raw)[0]
                        text = _read_string(frame, cursor)
                        if text and text not in seen:
                            seen.append(text)
                            lines.append("+%-5d const %s" % (offset, text))
                            break
            elif _matches(word, _ADD_IMM):
                base = (word >> 5) & 0x1F
                if base in pages:
                    literal = pages.pop(base) + ((word >> 10) & 0xFFF)
                    text = _read_string(frame, literal)
                    if text and text not in seen:
                        seen.append(text)
                        lines.append("+%-5d cfstr %s" % (offset, text))

        if word in _RET or _matches(word, _B):
            break

    _emit(result, "\n".join(lines) if lines
          else "no %s found in the first %d instructions" % (want, limit))


def sels(debugger, command, result, internal_dict):
    _walk(command, result, "sels")


def consts(debugger, command, result, internal_dict):
    _walk(command, result, "consts")


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f trace.sels sels")
    debugger.HandleCommand("command script add -f trace.consts consts")
