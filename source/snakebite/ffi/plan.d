module snakebite.ffi.plan;


import snakebite.ffi.callback: CallbackBridge;
import snakebite.ffi.symbol: Resolver;


private:


// Everything about calling one already-compiled function that does not
// change between calls: where the code is, and what each of its arguments
// and its result must become to travel in a register.
//
// This is the FFI barrier's whole point. Deciding those things means
// mangling a symbol name, asking the dynamic linker for its address, and
// walking the dmd type of every parameter - work that costs far more than
// the call it prepares, and none of which can change from one call to the
// next. A plan holds the answers so that a call is only loading slots into
// registers and jumping.
//
// A plan is immutable once built, and holds no dmd types, so calling
// through one touches nothing the frontend owns. Its heart is a list of
// moves: for every eightbyte of every argument, where its bytes come from
// and which `CallFrame` slot (ADR-0001) it lands in. That shape - which
// eightbyte reaches which integer register, SSE register or stack word -
// depends only on the callee's signature, never on an argument's value, so
// `prepare`/`ofRawAddress` compute it once, in `buildMoves`. `buildMoves`
// also picks which of the System V stub's two entries (`snakebite.ffi.
// sysv`) the plan uses - the general one, or the leaner integer-only one
// for a plan with no SSE argument registers and no stack words - and
// keeps its address. `callAt` only replays the moves: read a word, write
// it into the frame, call that one entry once, and read the result back.
public struct CallPlan {
    import snakebite.ffi.abi: ArgumentPlan, Register;
    import snakebite.ffi.sysv:
        CallEntry, CallFrame, snakebite_ffi_call_sysv_amd64,
        snakebite_ffi_call_sysv_amd64_integer;

    // The System V `CallFrame` (ADR-0001) plus this plan's own stack word
    // storage, laid out contiguously right after it. Every move - whether
    // it lands in an integer register, an SSE register or a stack word -
    // then writes through the same flat byte offset from `&frame`, with no
    // switch on which region it is: `integerBase`, `sseBase` and
    // `stackBase` below are where each region starts.
    private struct Frame {
        private CallFrame callFrame;
        private size_t[16] stackArea;
    }

    private enum size_t integerBase = CallFrame.integer.offsetof;
    private enum size_t sseBase = CallFrame.sse.offsetof;
    private enum size_t stackBase = Frame.stackArea.offsetof;

    // How to read one eightbyte's source bytes at call time, precomputed
    // once from the argument's `Register` at `buildMoves` time - a single
    // flat tag instead of `abi.word`'s two-level switch on `Register.Kind`
    // then size. A pointer, an 8-byte signed/unsigned integral and a full
    // eightbyte of an INTEGER/SSE-class aggregate all read the same way,
    // so they share `word64`; `copy` is the rare aggregate eightbyte
    // narrower than 8 bytes, the only case that still needs a byte count.
    private enum Load : ubyte {
        word64, zero8, zero16, zero32, sign8, sign16, sign32, copy,
    }

    // One eightbyte's source and destination, fixed at prepare time. The
    // source is `byteOffset` bytes into argument `parameterIndex`'s own
    // bytes, read as `load` says; `copyBytes` is only meaningful when
    // `load == copy`. `destinationOffset` is a byte offset into `Frame`,
    // already resolved to its integer/SSE/stack region - `callAt` never
    // has to ask which region a move belongs to. The hidden return
    // pointer, when this plan has one, is not a move - see
    // `_returnPointerOffset`. `byteOffset` is `ushort`, not `ubyte`: a
    // MEMORY-class argument's last eightbyte can start up to
    // `abi.ArgumentPlan.maxMemoryBytes - 8` bytes in (504 at the current
    // 512-byte limit), past what `ubyte` holds.
    private struct Move {
        private size_t parameterIndex;
        private size_t destinationOffset;
        private Load load;
        private ushort byteOffset;
        private ubyte copyBytes;
    }

    // How to write one result eightbyte back into `returnPlace`: a
    // truncated store sized to the register's own width, precomputed once
    // from `_return` at `buildMoves` time instead of `abi.writeWord`'s
    // runtime dispatch (which also re-validated a width every plan here
    // already fixed at prepare time).
    private enum Store : ubyte { byte1, byte2, byte4, byte8 }

    private struct ResultMove {
        private ushort sourceOffset;
        private Store store;
    }

    private void* _address;
    // Indexed by parameter, not by register: a dynamic-array parameter
    // reserves one entry here and two registers at call time, since the
    // two travel together as one argument the guest evaluated once.
    private ArgumentPlan[] _arguments;
    private size_t _parameterCount;
    private ArgumentPlan _return;
    // Whether `_return` is meaningless because the result travels through
    // a hidden pointer instead - see `needsHiddenReturnPointer`.
    private bool _hiddenReturnPointer;
    // A method or nested function receives its context before its explicit
    // parameters. The caller's first argument slot holds that pointer.
    private bool _hiddenContext;
    // dmd and ldc use different orders when both invisible arguments are
    // present. See `abi.contextPrecedesHiddenReturnPointer`.
    private bool _contextPrecedesHiddenReturnPointer;
    // Whether the callee reads its parameters out of the registers in
    // reverse declaration order - see `abi.reversedDParameters`.
    private bool _reversedArguments;
    // The moves `callAt` replays - see the module comment.
    private Move[] _moves;
    private size_t _moveCount;
    // One parameter whose value can carry a guest function word across
    // the barrier: a function pointer, a delegate, or a `lazy` parameter
    // (dmd's own implicit delegate). `callWithCallbacks` swaps such a word
    // for the guest function's pool entry (ADR-0003) before the call, and
    // swaps it back after the call for a `ref`/`out` parameter the host
    // could have written through.
    private struct CallbackArgument {
        size_t index;
        // `ref`/`out`: the argument slot holds the value's address, not
        // the value.
        bool indirect;
        // A delegate is two words with the function word second; a
        // function pointer is the one word itself.
        bool isDelegate;
    }
    private CallbackArgument[] _callbackArguments;
    // The backend instance's own registry of guest function words - the
    // one that knows which words are guest functions and owns their pool
    // entries. Shared mutable state owned by the `PlanCache`, never part
    // of this plan's own value: `callWithCallbacks` casts the `const`
    // away to reserve an entry on first use.
    private CallbackBridge* _callbacks;

    // `CallFrame.sseCount`: how many of the moves above land in an SSE
    // register, for a variadic callee's `%al`.
    private size_t _sseCount;
    private size_t _stackWordCount;
    // At most two result eightbytes - one INTEGER/SSE register each, or a
    // pair when the return classifies to two eightbytes.
    private ResultMove[2] _resultMoves;
    private size_t _resultCount;
    // The stub entry this plan calls through - `snakebite_ffi_call_sysv_
    // amd64` or `snakebite_ffi_call_sysv_amd64_integer`, chosen once in
    // `buildMoves` from `_sseCount`/`_stackWordCount`. This is a
    // prepare-time choice between two generic entries (see `sysv.
    // CallEntry`'s own doc), not per-signature code, which ADR-0011
    // reserves for a measured need: `callAt` below does one indirect call
    // through this field, with no branch of its own between the two.
    private CallEntry _entry;
    // Whether `_entry` is the integer-only stub - the same condition
    // `buildMoves` already computed to choose `_entry`, kept so `callAt`
    // can skip filling fields that entry never reads (see its own call
    // site below) instead of recomputing `_sseCount == 0 && _stackWordCount
    // == 0` on every call.
    private bool _integerOnly;
    private uint _returnPointerOffset;
    // Callback direction only (`ofCallback`): where each argument's own
    // bytes land in the handler's scratch area when the moves above are
    // replayed in reverse (`unpackArguments`), and where the result is
    // built before `packResult` loads it into the return registers.
    private size_t[] _argumentOffsets;
    private size_t _returnOffset;
    private size_t _scratchBytes;

    // Calls the function this plan was prepared for.
    //
    // `arguments` are the addresses of each argument's native bytes, in
    // declaration order, and the result is written to `returnPlace` in
    // native layout - the same convention `Backend.call` uses, so a caller
    // hands over slots it already has rather than copying anything.
    //
    // `returnPlace` may be `null` to discard the result, and must
    // otherwise be exactly the return type's size.
    pragma(inline, true) public void call(
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        callAt(_address, returnPlace, arguments);
    }

    // Calls another function with this plan's prepared ABI shape: fills a
    // `Frame` by replaying the moves `prepare`/`ofRawAddress` computed,
    // calls the System V stub's `_entry` once, and writes the result back.
    // Every step is an argument-count check, a loop of plain loads and
    // stores, the stub call, and at most two result stores - no `final
    // switch` on a destination region, no branch between the stub's two
    // entries (that choice is `buildMoves`', at prepare time - see
    // `_entry`'s own doc), and no throw expression inline in this body
    // (see `throwArgumentCountMismatch`/`throwMissingReturnPlace`).
    pragma(inline, true) public void callAt(
        const(void)* address,
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        if (arguments.length != _parameterCount)
            throwArgumentCountMismatch(_parameterCount, arguments.length);
        if (_hiddenReturnPointer && returnPlace is null)
            throwMissingReturnPlace;
        if (_callbackArguments.length) {
            callWithCallbacks(address, returnPlace, arguments);
            return;
        }

        callDirect(address, returnPlace, arguments);
    }

    // The second half of `callAt`, once every argument slot holds bytes the
    // host can read as they are.
    pragma(inline, true)
    private void callDirect(
        const(void)* address,
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        // Calls without SSE or stack arguments need only the register frame.
        if (_integerOnly) {
            CallFrame frame = void;
            auto frameBytes = cast(ubyte*) &frame;
            fillFrame(frameBytes, returnPlace, arguments);
            _entry(address, &frame);
            readResult(frameBytes, returnPlace);
            return;
        }

        Frame frame = void;
        // Keep small calls on the stack. The overflow storage has word
        // alignment and retains the flat offsets used by the prepared moves.
        auto storage = _stackWordCount <= frame.stackArea.length
            ? null : new size_t[stackBase / size_t.sizeof + _stackWordCount];
        auto frameBytes = storage is null
            ? cast(ubyte*) &frame : cast(ubyte*) storage.ptr;
        fillFrame(frameBytes, returnPlace, arguments);
        auto callFrame = cast(CallFrame*) frameBytes;
        callFrame.sseCount = _sseCount;
        callFrame.stack = cast(size_t*) (frameBytes + stackBase);
        callFrame.stackWords = _stackWordCount;
        _entry(address, callFrame);
        readResult(frameBytes, returnPlace);
    }

    // `callAt` for a plan with at least one callback-typed parameter
    // (`_callbackArguments`): every such argument's value is copied into
    // scratch storage, a guest function word in it is replaced by the
    // guest function's pool entry (ADR-0003), and the host is handed the
    // copy - the guest's own storage keeps its own representation of the
    // function, which is what guest code calls through. After the call, a
    // `ref`/`out` copy is written back to the guest's storage, with a pool
    // entry the host stored in it turned back into the guest word it
    // stands for, so the guest never sees an address it cannot call.
    pragma(inline, false)
    private void callWithCallbacks(
        const(void)* address,
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        import core.stdc.string: memcpy;
        import snakebite.callarguments: CallArguments;
        import snakebite.nativelayout:
            delegateFunctionOffset, delegateValueSize;

        // See `_callbacks`'s own doc for why the `const` goes.
        auto bridge = cast(CallbackBridge*) _callbacks;
        if (bridge is null)
            throw new Exception(
                "ffi: this plan has a callback-typed parameter, but no " ~
                    "callback bridge to give a guest function a pool entry",
            );

        auto shadow = CallArguments(arguments.length);
        // `const` would make the address slots read-only.
        auto values = shadow.values;
        values[] = arguments[];

        // One delegate-sized copy per callback argument, plus, for an
        // indirect one, the pointer slot the host reads the copy's
        // address from.
        enum inlineCopies = 8;
        align(16) ubyte[delegateValueSize * inlineCopies] inlineCopy = void;
        void*[inlineCopies] inlinePointer = void;
        const count = _callbackArguments.length;
        // `new void[]`, not `new ubyte[]`: a `ubyte[]` block is NO_SCAN,
        // and this copy briefly holds a callback argument's own bytes,
        // which the collector must still be able to trace (ADR-0005).
        auto copies = count <= inlineCopies
            ? inlineCopy[0 .. delegateValueSize * count]
            : cast(ubyte[]) new void[delegateValueSize * count];
        auto pointers = count <= inlineCopies
            ? inlinePointer[0 .. count] : new void*[count];

        foreach (k, argument; _callbackArguments) {
            const(void)* place = arguments[argument.index];
            if (argument.indirect)
                place = *cast(const(void*)*) place;
            if (place is null)
                continue;

            const bytes = argument.isDelegate
                ? delegateValueSize : size_t.sizeof;
            const wordOffset =
                argument.isDelegate ? delegateFunctionOffset : 0;
            auto copy = copies.ptr + k * delegateValueSize;
            memcpy(copy, place, bytes);
            auto word = cast(const(void)**) (copy + wordOffset);
            if (auto entry = bridge.entryOf(*word))
                *word = entry;

            if (argument.indirect) {
                pointers[k] = copy;
                values[argument.index] = &pointers[k];
            } else
                values[argument.index] = copy;
        }

        callDirect(address, returnPlace, values);

        foreach (k, argument; _callbackArguments) {
            if (!argument.indirect)
                continue;
            auto place = cast(ubyte*) *cast(const(void*)*)
                arguments[argument.index];
            if (place is null)
                continue;

            const bytes = argument.isDelegate
                ? delegateValueSize : size_t.sizeof;
            const wordOffset =
                argument.isDelegate ? delegateFunctionOffset : 0;
            auto copy = copies.ptr + k * delegateValueSize;
            auto word = cast(const(void)**) (copy + wordOffset);
            if (auto guest = bridge.wordOf(*word))
                *word = guest;
            memcpy(place, copy, bytes);
        }
    }

    // The number of arguments a callback through this plan receives,
    // hidden context included - the length `unpackArguments` fills.
    package size_t callbackArgumentCount() const {
        return _parameterCount;
    }

    package bool hasHiddenContext() const {
        return _hiddenContext;
    }

    // How many bytes of scratch storage `unpackArguments` and
    // `callbackReturnPlace` need, together.
    package size_t callbackScratchBytes() const {
        return _scratchBytes;
    }

    // The forward moves replayed backwards, for a callback (ADR-0003):
    // every eightbyte the host placed in a register or a stack word is
    // read from `frame` - the registers spilled by
    // `snakebite_ffi_callback_common`, the stack words through
    // `frame.stack` - and written into the argument's own bytes in
    // `scratch`, at the width the forward load would have read. `addresses`
    // receives one entry per argument, hidden context included, pointing
    // at those bytes in the same shape `call` takes its arguments in.
    package void unpackArguments(
        const(CallFrame)* frame,
        ubyte* scratch,
        scope void*[] addresses,
    ) const {
        import core.stdc.string: memcpy;

        foreach (i; 0 .. _parameterCount)
            addresses[i] = scratch + _argumentOffsets[i];

        auto frameBytes = cast(const(ubyte)*) frame;
        foreach (ref move; _moves[0 .. _moveCount]) {
            const word = move.destinationOffset >= stackBase
                ? frame.stack[
                    (move.destinationOffset - stackBase) / size_t.sizeof]
                : *cast(const(size_t)*)
                    (frameBytes + move.destinationOffset);
            memcpy(
                scratch + _argumentOffsets[move.parameterIndex]
                    + move.byteOffset,
                &word,
                widthOf(move),
            );
        }
    }

    // Where the backend writes a callback's result: through the hidden
    // pointer the host passed, for a MEMORY-class return; into `scratch`,
    // for a register-class one; nowhere, for `void`.
    package void* callbackReturnPlace(
        const(CallFrame)* frame, ubyte* scratch,
    ) const {
        if (_hiddenReturnPointer)
            return *cast(void**)
                (cast(const(ubyte)*) frame + _returnPointerOffset);
        if (_resultCount == 0)
            return null;
        return scratch + _returnOffset;
    }

    // Loads the result a backend left at `returnPlace` into the frame's
    // result words, which `snakebite_ffi_callback_common` moves into the
    // return registers. A MEMORY-class result is already where the host
    // expects it; the callee then returns the hidden pointer in `%rax`.
    package void packResult(
        CallFrame* frame, const(void)* returnPlace,
    ) const {
        if (_hiddenReturnPointer) {
            frame.integerResult[0] = cast(size_t) returnPlace;
            return;
        }

        auto frameBytes = cast(ubyte*) frame;
        foreach (i; 0 .. _resultCount) {
            const register = _return.registers[i];
            const move = Move(
                0, 0, loadOf(register), 0, copyBytesOf(register));
            *cast(size_t*) (frameBytes + _resultMoves[i].sourceOffset) =
                loadRare(
                    move,
                    cast(const(ubyte)*) returnPlace + i * size_t.sizeof,
                );
        }
    }

    // How many of an argument's own bytes one move carries - the width
    // its forward `Load` reads.
    private static size_t widthOf(in Move move) {
        final switch (move.load) with (Load) {
            case word64: return 8;
            case zero8, sign8: return 1;
            case zero16, sign16: return 2;
            case zero32, sign32: return 4;
            case copy: return move.copyBytes;
        }
    }

    // Lays out the scratch area `unpackArguments` fills: each argument's
    // own bytes at a 16-byte-aligned offset, then the result. Called once,
    // from `ofCallback`, after `buildMoves`.
    private void buildCallbackLayout() {
        _argumentOffsets.length = _parameterCount;
        size_t offset;
        foreach (i, argument; _arguments) {
            _argumentOffsets[i] = offset;
            offset += alignScratch(bytesOf(argument));
        }
        _returnOffset = offset;
        if (!_hiddenReturnPointer)
            offset += alignScratch(bytesOf(_return));
        _scratchBytes = offset;
    }

    private static size_t alignScratch(in size_t bytes) {
        return (bytes + 15) & ~size_t(15);
    }

    // The byte size of the value an `ArgumentPlan` describes: a MEMORY
    // value's own size, or the sum of its register widths - the last of
    // which `abi.aggregatePlan` already trimmed to the bytes left.
    private static size_t bytesOf(in ArgumentPlan argument) {
        if (argument.memory)
            return argument.memoryBytes;

        size_t bytes;
        foreach (register; argument.registers[0 .. argument.count])
            bytes += register.size;
        return bytes;
    }

    // Writes the hidden return pointer, when this plan has one, and every
    // move's loaded value, into `frameBytes` - the shared first half of
    // `callAt`'s two branches.
    pragma(inline, true)
    private void fillFrame(
        ubyte* frameBytes,
        void* returnPlace,
        scope const(void*)[] arguments,
    ) const {
        if (_hiddenReturnPointer)
            *cast(size_t*) (frameBytes + _returnPointerOffset) =
                cast(size_t) returnPlace;
        if (_moveCount != 0) {
            *cast(size_t*) (frameBytes + _moves[0].destinationOffset) =
                loadValue(_moves[0], arguments);
            foreach (ref move; _moves[1 .. _moveCount])
                *cast(size_t*) (frameBytes + move.destinationOffset) =
                    loadValue(move, arguments);
        }
    }

    // Reads the call's result out of `frameBytes` into `returnPlace` - the
    // shared second half of `callAt`'s two branches.
    //
    // A hidden-pointer return already left its bytes at `returnPlace`
    // through that pointer, not in the return registers - which the
    // callee leaves holding that same pointer, not the value. A `void`
    // callee leaves the registers holding whatever it last used them for,
    // so reading them in either case would be reading garbage or an
    // address, not the result.
    pragma(inline, true)
    private void readResult(ubyte* frameBytes, void* returnPlace) const {
        if (returnPlace is null || _resultCount == 0)
            return;

        auto bytes = cast(ubyte*) returnPlace;
        storeResult(_resultMoves[0].store,
            *cast(size_t*) (frameBytes + _resultMoves[0].sourceOffset),
            bytes);
        if (_resultCount > 1)
            storeResult(_resultMoves[1].store,
                *cast(size_t*) (frameBytes + _resultMoves[1].sourceOffset),
                bytes + size_t.sizeof);
    }

    // `move`'s source bytes, widened or truncated as `move.load` says.
    // Never called for a return-pointer move - `callAt` reads that one
    // directly from its own `returnPlace` argument instead.
    pragma(inline, true)
    private static size_t loadValue(
        in Move move, scope const(void*)[] arguments,
    ) {
        auto src = cast(ubyte*) arguments[move.parameterIndex]
            + move.byteOffset;
        if (move.load == Load.word64)
            return *cast(size_t*) src;
        if (move.load == Load.sign32)
            return cast(size_t) cast(long) *cast(int*) src;
        return loadRare(move, src);
    }

    pragma(inline, false)
    private static size_t loadRare(in Move move, const(ubyte)* src) {
        final switch (move.load) with (Load) {
            case word64: return *cast(size_t*) src;
            case zero8:  return *cast(ubyte*) src;
            case zero16: return *cast(ushort*) src;
            case zero32: return *cast(uint*) src;
            case sign8:  return cast(size_t) cast(long) *cast(byte*) src;
            case sign16: return cast(size_t) cast(long) *cast(short*) src;
            case sign32: return cast(size_t) cast(long) *cast(int*) src;
            case copy: {
                import core.stdc.string: memcpy;

                size_t result;
                memcpy(&result, src, move.copyBytes);
                return result;
            }
        }
    }

    // Writes `value`'s low bytes to `place`, truncated to `store`'s width -
    // the same raw-truncation rule `nativevalue.storeIntegral` uses, but
    // written directly rather than through `nativelayout.storeIntegral`'s
    // validate-and-throw wrapper: a plan's own register widths are already
    // known good, fixed once at prepare time, and never need re-checking -
    // or a second switch on the width `store` has already picked - on
    // every call.
    pragma(inline, true)
    private static void storeResult(
        in Store store, in size_t value, void* place,
    ) {
        if (store == Store.byte8) {
            *cast(size_t*) place = value;
            return;
        }
        if (store == Store.byte4) {
            *cast(uint*) place = cast(uint) value;
            return;
        }
        storeRare(store, value, place);
    }

    pragma(inline, false)
    private static void storeRare(
        in Store store, in size_t value, void* place,
    ) {
        final switch (store) with (Store) {
            case byte1: *cast(ubyte*) place = cast(ubyte) value; break;
            case byte2: *cast(ushort*) place = cast(ushort) value; break;
            case byte4: *cast(uint*) place = cast(uint) value; break;
            case byte8: *cast(size_t*) place = value; break;
        }
    }

    // Prepares a plan for a raw address that has no `FuncDeclaration`
    // behind it - a druntime glue-layer hook such as
    // `_d_arraybounds_indexp`, `gc_malloc` or `_d_arrayappendcd`, called
    // by linker symbol rather than a guest declaration `prepare` walks a
    // dmd type for. Every parameter here is one plain integer-class
    // register, already the exact width its own hook expects, so the
    // caller hands over the register shapes directly instead of this
    // classifying a dmd `Type`. `returnRegister` defaults to
    // `Register.Kind.none`, for a hook such as a bounds check that never
    // returns at all: no hidden pointer, nothing to read back. A hook
    // that does return a plain register-width value, such as `gc_malloc`'s
    // pointer, names its own register instead - never more than one
    // eightbyte, the one shape every hook this backend calls this way
    // needs.
    package static CallPlan ofRawAddress(
        const(void)* address,
        scope const(Register)[] parameterRegisters,
        Register returnRegister = Register(Register.Kind.none, 0),
    ) {
        CallPlan plan;
        plan._address = cast(void*) address;
        plan._parameterCount = parameterRegisters.length;
        plan._arguments.length = parameterRegisters.length;
        foreach (i, register; parameterRegisters)
            plan._arguments[i] =
                ArgumentPlan([register, Register.init], 1, false);
        if (returnRegister.kind != Register.Kind.none)
            plan._return =
                ArgumentPlan([returnRegister, Register.init], 1, false);
        plan.buildMoves;
        return plan;
    }

    // Whether this plan, built by `ofRawAddress`, was built from exactly
    // these register shapes - the cache keys such a plan by symbol name
    // alone, so a second caller naming the same symbol has to agree.
    private bool hasShape(
        scope const(Register)[] parameterRegisters,
        in Register returnRegister,
    ) const {
        if (_parameterCount != parameterRegisters.length)
            return false;

        foreach (i, register; parameterRegisters)
            if (_arguments[i].registers[0] != register)
                return false;

        const expectedReturn = returnRegister.kind == Register.Kind.none
            ? ArgumentPlan.init
            : ArgumentPlan([returnRegister, Register.init], 1, false);
        return _return == expectedReturn;
    }

    // Computes `_moves`, `_sseCount` and `_stackWordCount` from this plan's
    // shape alone - see the module comment. Called once, from `prepare`
    // and `ofRawAddress`, after every other field is set.
    private void buildMoves() {
        import snakebite.ffi.abi: maxFloatingArguments, maxIntegerArguments;
        import std.algorithm: sort;

        size_t integerCount;
        size_t floatingCount;
        size_t stackCount;
        size_t moveCount;
        // A register-class argument becomes at most two moves (`count`),
        // but a MEMORY-class one (issue #334 step 3) never reaches a
        // register at all and instead becomes one move per whole eightbyte
        // of its own size (`memoryWords`) - `_parameterCount * 2` alone
        // would undercount a plan with such an argument and overrun
        // `_moves` below.
        size_t totalMoves;
        foreach (argument; _arguments)
            totalMoves +=
                argument.memory ? argument.memoryWords : argument.count;
        _moves.length = totalMoves;

        void addRegisterMove(
            in Register register,
            in size_t parameterIndex,
            in size_t byteOffset,
            in bool toFloating,
        ) {
            const destinationOffset = toFloating
                ? sseBase + (floatingCount++) * size_t.sizeof
                : integerBase + (integerCount++) * size_t.sizeof;
            _moves[moveCount++] = Move(
                parameterIndex, destinationOffset, loadOf(register),
                cast(ushort) byteOffset, copyBytesOf(register),
            );
        }

        void addStackMove(
            in Register register,
            in size_t parameterIndex,
            in size_t byteOffset,
        ) {
            const destinationOffset =
                stackBase + (stackCount++) * size_t.sizeof;
            _moves[moveCount++] = Move(
                parameterIndex, destinationOffset, loadOf(register),
                cast(ushort) byteOffset, copyBytesOf(register),
            );
        }

        // Every eightbyte of argument `i` claims the next register in its
        // own file - only called once that file is known to have room for
        // all of them.
        void registerArgument(in size_t i) {
            const plan = _arguments[i];
            foreach (j; 0 .. plan.count) {
                const toFloating =
                    plan.registers[j].kind == Register.Kind.sse;
                addRegisterMove(
                    plan.registers[j], i, j * size_t.sizeof,
                    toFloating,
                );
            }
        }

        size_t firstExplicit;
        if (_hiddenContext) {
            firstExplicit = 1;
            if (_contextPrecedesHiddenReturnPointer)
                registerArgument(0);
        }

        if (_hiddenReturnPointer)
            _returnPointerOffset = cast(uint)
                (integerBase + (integerCount++) * size_t.sizeof);

        if (_hiddenContext && !_contextPrecedesHiddenReturnPointer)
            registerArgument(0);

        // dmd's reversed register assignment (see `_reversedArguments`)
        // reverses the stack order too: dmd compiles `extern(D)` on
        // x86-64 as the C convention applied to the fully reversed
        // parameter list, stack words included, so a spilled parameter's
        // place in that stack extension follows the same reversal, not
        // ordinary declaration order. A parameter that does not fit is
        // deferred to a second pass, in descending parameter index when
        // `_reversedArguments`, ascending otherwise, once every parameter
        // that does fit has claimed its register.
        auto spilled = new size_t[_parameterCount];
        size_t spilledCount;

        // Whether argument `i`'s own eightbytes all still fit in whichever
        // register file(s) they classify to - never a partial answer,
        // since the SysV ABI passes a value classified into more than one
        // eightbyte either entirely in registers or entirely on the
        // stack, never split across that boundary. A mixed INTEGER/SSE
        // pair (one lane of each) is no exception here: both its lanes
        // must find room in their own file, or the whole pair spills to
        // the stack together.
        void visit(in size_t i) {
            const plan = _arguments[i];

            // A MEMORY-class argument never reaches a register - the
            // SysV ABI classifies it onto the stack outright, skipping
            // register classification entirely (`abi.ArgumentPlan`'s own
            // doc) - so it always defers to the spilled pass below,
            // whatever room either register file has left.
            if (plan.memory) {
                spilled[spilledCount++] = i;
                return;
            }

            size_t integerLanes;
            size_t floatingLanes;
            foreach (register; plan.registers[0 .. plan.count])
                if (register.kind == Register.Kind.sse)
                    ++floatingLanes;
                else
                    ++integerLanes;

            const integerSpills = integerLanes > 0
                && integerCount + integerLanes > maxIntegerArguments;
            const floatingSpills = floatingLanes > 0
                && floatingCount + floatingLanes > maxFloatingArguments;

            if (!integerSpills && !floatingSpills)
                registerArgument(i);
            else
                spilled[spilledCount++] = i;
        }

        if (_reversedArguments)
            foreach_reverse (i; firstExplicit .. _parameterCount)
                visit(i);
        else
            foreach (i; firstExplicit .. _parameterCount)
                visit(i);

        void addSpilled(in size_t i) {
            const plan = _arguments[i];

            // A MEMORY-class argument's eightbytes were never classified
            // into `plan.registers` (there is no register shape to read -
            // see `abi.ArgumentPlan`'s own doc), so each one is built here
            // instead, straight from its byte size: a whole `word64` load
            // for every full eightbyte, and for a size that does not end
            // on an eightbyte boundary, one final `copy` load - `loadOf`/
            // `copyBytesOf` below already give a narrower-than-8 INTEGER
            // register exactly that load - sized to only the bytes still
            // left, so it never reads past the argument's own storage.
            if (plan.memory) {
                const alignment = plan.memoryAlignment / size_t.sizeof;
                if (alignment > 1)
                    stackCount = (stackCount + alignment - 1)
                        / alignment * alignment;
                const words = plan.memoryWords;
                foreach (j; 0 .. words) {
                    const offset = j * size_t.sizeof;
                    const remaining = plan.memoryBytes - offset;
                    const size = remaining < size_t.sizeof
                        ? remaining : size_t.sizeof;
                    addStackMove(
                        Register(Register.Kind.integer, cast(ubyte) size),
                        i, offset,
                    );
                }
                return;
            }

            foreach (j; 0 .. plan.count)
                addStackMove(plan.registers[j], i, j * size_t.sizeof);
        }

        sort(spilled[0 .. spilledCount]);
        if (_reversedArguments)
            foreach_reverse (i; spilled[0 .. spilledCount])
                addSpilled(i);
        else
            foreach (i; spilled[0 .. spilledCount])
                addSpilled(i);

        _moveCount = moveCount;
        _sseCount = floatingCount;
        _stackWordCount = stackCount;
        // The leaner entry is safe exactly when this plan fills no SSE
        // register and spills no stack word - see `_entry`'s own doc.
        _integerOnly = _sseCount == 0 && _stackWordCount == 0;
        _entry = _integerOnly
            ? &snakebite_ffi_call_sysv_amd64_integer
            : &snakebite_ffi_call_sysv_amd64;

        // At most two result eightbytes (`_return.count`), each read from
        // its own register file's next result slot - see `callAt`.
        size_t integerResultIndex;
        size_t floatingResultIndex;
        foreach (i; 0 .. _return.count) {
            const fromSse = _return.registers[i].kind == Register.Kind.sse;
            const sourceOffset = fromSse
                ? CallFrame.sseResult.offsetof
                    + (floatingResultIndex++) * size_t.sizeof
                : CallFrame.integerResult.offsetof
                    + (integerResultIndex++) * size_t.sizeof;
            _resultMoves[i] = ResultMove(
                cast(ushort) sourceOffset,
                storeOf(_return.registers[i].size),
            );
        }
        _resultCount = _return.count;
    }

    // `register`'s source bytes, as a `Load` tag - see `Load` and
    // `loadValue`. Called only at prepare time, from `buildMoves`.
    private static Load loadOf(in Register register) {
        final switch (register.kind) with (Register.Kind) {
            case pointer:
                return Load.word64;

            case unsigned:
                switch (register.size) {
                    case 1: return Load.zero8;
                    case 2: return Load.zero16;
                    case 4: return Load.zero32;
                    case 8: return Load.word64;
                    default: assert(false, "unsupported unsigned size");
                }

            case signed:
                switch (register.size) {
                    case 1: return Load.sign8;
                    case 2: return Load.sign16;
                    case 4: return Load.sign32;
                    case 8: return Load.word64;
                    default: assert(false, "unsupported signed size");
                }

            case integer:
                return register.size == 8 ? Load.word64 : Load.copy;

            // A scalar `float` argument classifies as `Register(sse, 4)`
            // - the common case, so it gets its own zero-extending load
            // like `unsigned`'s size 4 above, instead of `copy`'s
            // `memcpy`. Only a partial SSE-class aggregate eightbyte
            // (sizes 1-3 and 5-7) still needs `copy`.
            case sse:
                if (register.size == 8)
                    return Load.word64;
                return register.size == 4 ? Load.zero32 : Load.copy;

            case none:
                assert(false, "a `void` argument has nothing to pass");
        }
    }

    // How many bytes `loadValue`'s `copy` case reads - meaningless, and
    // left `0`, for every other `Load` tag.
    private static ubyte copyBytesOf(in Register register) {
        const partialAggregate =
            (register.kind == Register.Kind.integer
                || register.kind == Register.Kind.sse)
            && register.size != 8;
        return partialAggregate ? register.size : 0;
    }

    // `size`'s `Store` tag - see `Store` and `storeResult`. Called only at
    // prepare time, from `buildMoves`; a plan's `Register`s always carry
    // one of these four widths (see `abi.Register.size`'s own doc).
    private static Store storeOf(in ubyte size) {
        switch (size) {
            case 1: return Store.byte1;
            case 2: return Store.byte2;
            case 4: return Store.byte4;
            case 8: return Store.byte8;
            default: assert(false, "unsupported result register size");
        }
    }
}

// Split from `callAt`'s body so the hot path itself is only ever a compare
// and a branch to here, never an inlined exception construction.
private void throwArgumentCountMismatch(
    in size_t expected, in size_t got,
) {
    import std.conv: text;

    throw new Exception(
        text("ffi: this plan takes ", expected,
            " argument(s), got ", got),
    );
}

// As `throwArgumentCountMismatch`, for the other `callAt` precondition.
private void throwMissingReturnPlace() {
    throw new Exception(
        "ffi: this plan returns a value larger than a " ~
            "register, and needs somewhere to write it",
    );
}

// The DMD-free runtime entry point for a prepared call. Backends keep the
// plan opaque and hand this function addresses of values already stored in
// native layout.
public extern(C) void executeCallPlan(
    const(void)* opaquePlan,
    void* returnPlace,
    scope const(void*)* arguments,
    size_t argumentCount,
) {
    const plan = cast(const(CallPlan)*) opaquePlan;
    plan.call(returnPlace, arguments[0 .. argumentCount]);
}

public extern(C) bool executeIndirectCallPlan(
    const(void)* opaquePlan, const(void)* address, void* returnPlace,
    scope const(void*)* arguments, size_t argumentCount,
) {
    const plan = cast(const(CallPlan)*) opaquePlan;
    if (plan._callbacks !is null && plan._callbacks.contains(address))
        return false;
    plan.callAt(address, returnPlace, arguments[0 .. argumentCount]);
    return true;
}

// The plans already prepared, one per function. A backend owns one of
// these and keeps it for its whole life, so the second call to a function
// and every call after it reuses the first call's answers.
//
// Keyed by declaration rather than by call site: two call sites naming the
// same function need the very same plan, and the declaration is what both
// resolve to. A call site is the finer key, and would let a plan be found
// without hashing at all, but it needs somewhere on the call site to keep
// it, which is the caller's business and not this package's.
public struct PlanCache {
    // Holds `SharedTable`s (finding 2.4): a copy would share their
    // storage with the original until one side grows.
    @disable this(this);

    import dmd.func: FuncDeclaration;
    import dmd.mtype: TypeFunction;

    private CallbackBridge* _callbacks;

    public void* callableAddress(
        const(void)* word, FuncDeclaration declaration,
        in ptrdiff_t adjustment = 0,
    ) {
        if (word is null)
            word = of(declaration)._address;
        return cast(void*) _callbacks.adjustedEntryOf(
            word, declaration, adjustment);
    }

    public bool isGuestWord(const(void)* word) const {
        return _callbacks !is null && _callbacks.contains(word);
    }

    // `TypeFunction`, not `const(TypeFunction)`: a `SharedTable` entry
    // assigns its whole key by value on insert, which a `const` field
    // would refuse.
    private struct Signature {
        TypeFunction type;
        bool context;
    }
    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a signature's plan is prepared once, on its first
    // indirect call.
    private SharedTable!(Signature, CallPlan*) _signatures;

    public const(CallPlan)* signatureOf(
        TypeFunction type, in bool context,
    ) {
        auto key = Signature(type, context);
        if (auto cached = key in _signatures)
            return *cached;

        import snakebite.frontend.compiler: withCompilerLock;

        CallPlan* plan;
        withCompilerLock({
            if (auto cached = key in _signatures) {
                plan = *cached;
                return;
            }
            plan = new CallPlan;
            *plan = _shapeOf(type, context, type.linkage, null, false);
            plan._callbacks = _callbacks;
            plan = *_signatures.insert(key, plan);
        });
        return plan;
    }

    // The registry of this backend instance's guest function words, and
    // the owner of their pool entries (ADR-0003). A backend installs one
    // before it prepares any plan; every plan this cache prepares reads
    // it at call time to swap a guest function word for its entry.
    public void useCallbacks(CallbackBridge* callbacks) {
        _callbacks = callbacks;
    }

    // Records that `word` is what this backend stores for the guest
    // function `declaration` when guest code takes its address or makes
    // a delegate to it. Only a word a backend itself emitted is ever
    // registered: a host code address must never be inspected as a
    // frontend or bytecode object, and an unregistered word crosses the
    // barrier unchanged.
    public void registerGuestFunction(
        const(void)* word,
        imported!"dmd.func".FuncDeclaration declaration,
    ) {
        if (_callbacks is null)
            throw new Exception(
                "ffi: a guest function was registered before the " ~
                    "backend installed its callback bridge",
            );
        _callbacks.register(word, declaration);
    }

    import dmd.func: FuncDeclaration;
    import snakebite.sharedtable: SharedTable;

    // Read without a lock by every thread that runs guest code
    // (ADR-0006); a plan is prepared once, on its first use.
    private SharedTable!(FuncDeclaration, CallPlan*) _plans;
    private SharedTable!(string, CallPlan*) _rawPlans;
    private SharedTable!(FuncDeclaration, bool) _nativeSymbols;
    private Resolver _resolver;
    private shared size_t _preparations;
    version(unittest) private size_t _nativeSymbolLookups;

    // Resolves a linker name through the cache shared by this backend's
    // plan preparation and its other FFI operations.
    public void* resolve(in char[] name) {
        return _resolver.resolve(name);
    }

    // Whether `function_` has machine code in this process. Missing symbols
    // are cached too because a synthesized function with a body can validly
    // have no native counterpart.
    public bool hasNativeSymbol(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        import dmd.mangle: mangleExact;
        import snakebite.druntime.constructoratomic: nativeTarget;
        import std.string: fromStringz;

        if (auto cached = function_ in _nativeSymbols)
            return *cached;

        import snakebite.frontend.compiler: withCompilerLock;

        bool found;
        withCompilerLock({
            if (auto cached = function_ in _nativeSymbols) {
                found = *cached;
                return;
            }
            version(unittest) ++_nativeSymbolLookups;
            auto target = nativeTarget(function_);
            found = target.address !is null || resolve(
                mangleExact(function_).fromStringz,
            ) !is null;
            _nativeSymbols.insert(function_, found);
        });
        return found;
    }

    version(unittest)
    public size_t nativeSymbolLookups()
        @safe @nogc nothrow pure const scope
    {
        return _nativeSymbolLookups;
    }

    version(unittest)
    public size_t symbolLookups() @safe @nogc nothrow pure const scope {
        return _resolver.lookups;
    }

    // How many plans this has had to prepare - the expensive work the
    // cache exists to avoid, counted so that it can be asserted on.
    //
    // The address of a cached plan cannot stand in for this: an
    // associative array's slot keeps its address when its value is
    // overwritten, so a cache that rebuilt a plan on every call would
    // still hand back the same address every time.
    public size_t preparations() const {
        import core.atomic: atomicLoad;

        return atomicLoad(_preparations);
    }

    private void countPreparation() {
        import core.atomic: atomicOp;

        atomicOp!"+="(_preparations, 1);
    }

    // `function_`'s plan, prepared on its first call and reused after.
    //
    // Returned by pointer, the same kind `variadicOf`/`rawPlanOf` return:
    // the plan stays in the cache, and a caller only ever calls through
    // it.
    public const(CallPlan)* of(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        if (auto cached = function_ in _plans)
            return *cached;

        import snakebite.frontend.compiler: withCompilerLock;

        CallPlan* plan;
        withCompilerLock({
            if (auto cached = function_ in _plans) {
                plan = *cached;
                return;
            }
            countPreparation;
            plan = new CallPlan;
            *plan = prepare(function_, _resolver);
            plan._callbacks = _callbacks;
            plan = *_plans.insert(function_, plan);
        });
        return plan;
    }

    // As `.of`, but for one call site of an `extern(C)` C-style or
    // `extern(D)` untyped variadic callee (`prepareVariadic`'s own doc):
    // the plan depends on that call's own extra argument types, not on
    // `function_` alone, so this
    // never caches by declaration the way `_plans` does - it prepares a
    // fresh plan on every call. A caller keeps the returned plan itself,
    // alongside the call site it belongs to, to avoid paying that cost
    // more than once per site: the interpreter keeps it next to the
    // `CallExp` (`Evaluator.CallSitePlan`), and the bytecode compiler
    // calls this only once, while compiling the one `CallSite` a guest
    // `CallExp` ever produces.
    public const(CallPlan)* variadicOf(
        imported!"dmd.func".FuncDeclaration function_,
        scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    ) {
        import snakebite.frontend.compiler: withCompilerLock;

        // Never cached (this method's own doc), so every call - not only
        // a cache miss - touches dmd (finding 1.2) and must take the
        // lock. This is still a compile-time-triggered path: a caller
        // reaches it once per call site, not once per guest call.
        auto plan = new CallPlan;
        withCompilerLock({
            countPreparation;
            *plan = prepareVariadic(function_, _resolver, extraArgumentTypes);
            plan._callbacks = _callbacks;
        });
        return plan;
    }

    // As `.of`, but for a raw address with no `FuncDeclaration` to key
    // on - see `CallPlan.ofRawAddress`. Keyed and cached by linker symbol
    // name instead, so a second bounds check anywhere in the guest
    // program reuses the first one's resolved address and plan. Returns
    // `null` when the symbol is not in this process, the same convention
    // `resolve` itself uses.
    public const(CallPlan)* rawPlanOf(
        string name,
        scope const(imported!"snakebite.ffi.abi".Register)[]
            parameterRegisters,
        imported!"snakebite.ffi.abi".Register returnRegister =
            imported!"snakebite.ffi.abi".Register(
                imported!"snakebite.ffi.abi".Register.Kind.none, 0),
    ) {
        if (auto cached = name in _rawPlans) {
            import std.conv: text;

            assert((*cached).hasShape(parameterRegisters, returnRegister),
                text("ffi: `", name, "` was already planned with a ",
                    "different register shape"));
            return *cached;
        }

        auto address = resolve(name);
        if (address is null)
            return null;

        import snakebite.frontend.compiler: withCompilerLock;

        CallPlan* plan;
        withCompilerLock({
            if (auto cached = name in _rawPlans) {
                plan = *cached;
                return;
            }
            countPreparation;
            plan = new CallPlan;
            *plan = CallPlan.ofRawAddress(
                address, parameterRegisters, returnRegister);
            plan = *_rawPlans.insert(name, plan);
        });
        return plan;
    }

}

// Works out how to call `function_`, once.
//
// The linkage decides only the symbol's name, which dmd's own mangler
// supplies, so nothing here is specific to C. A signature the implemented
// ABI does not cover throws, naming what it could not pass - here, when
// the plan is prepared, rather than on every call that would use it.
private CallPlan prepare(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
) {
    return prepareCommon(function_, resolver, null, false);
}

// As `prepare`, for one call site of an `extern(C)` C-style or
// `extern(D)` untyped variadic callee: `extraArgumentTypes` are that
// call's own extra arguments' types, in call order. For a C-style
// callee, the frontend has already applied C's default argument
// promotions (`float` widens to `double`, an integral narrower than
// `int` widens to `int`) - exactly the types the callee's own `va_arg`
// will read. An `extern(D)` untyped callee's own hidden `_arguments` is
// not one of these - it is a whole extra argument in its own right,
// added inside `prepareCommon` (`hasVArguments`'s own doc), since its
// value comes from the call site's `TypeidExp`, not from a caller-
// supplied type list. `PlanCache.variadicOf` is the one caller.
//
// The plan this builds is one call site's own shape, not `function_`'s
// alone (ADR-0010's C- and D-variadics paragraphs; issue #334 steps 5
// and 6): two call sites naming the same variadic function can pass
// different extra arguments, and need different plans. This is never
// cached by `function_` the way `PlanCache._plans` caches an ordinary
// plan - a backend's own call-site cache (`PlanCache.of`'s own doc,
// issue #96) is what makes a repeat call at the same site free instead.
package CallPlan prepareVariadic(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
) {
    return prepareCommon(function_, resolver, extraArgumentTypes, true);
}

private CallPlan prepareCommon(
    imported!"dmd.func".FuncDeclaration function_,
    ref Resolver resolver,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
) {
    import snakebite.druntime.constructoratomic: nativeTarget;
    import dmd.mangle: mangleExact;
    import std.conv: text;
    import std.string: fromStringz;

    auto target = nativeTarget(function_);

    // The symbol's calling convention comes from its declared linkage,
    // and `extern(D)` code built by the host's own compiler can read
    // its parameters out of the registers in reverse order - an ABI
    // fact about this process, not a routing decision about the
    // callee. `shapeOf`'s variadic checks need this fact too, to tell an
    // `extern(C)` variadic callee from an `extern(D)` one.
    const linkage = target.address is null
        ? function_.resolvedLinkage : target.linkage;

    auto plan = shapeOf(function_, linkage, extraArgumentTypes,
        isVariadicCall);

    auto name = mangleExact(function_);
    void* address = target.address;
    if (address is null)
        address = resolver.resolve(name.fromStringz);
    if (address is null)
        throw new Exception(
            text("ffi cannot resolve the symbol `", name.fromStringz,
                "` declared by `", function_.toString,
                "`: it is not in this process"),
        );

    plan._address = address;
    return plan;
}

// The plan a pool entry (ADR-0003) replays backwards when host code calls
// the guest function `function_`: the same classification a forward call
// to a function of this signature would get, from the function's own
// declared linkage, with no address to resolve - the guest function has
// none. `snakebite.ffi.callback` keeps one per slot. Reference results
// use the same pointer return convention as a forward call.
package CallPlan prepareCallback(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: VarArg;
    import std.conv: text;

    auto type = function_.type.isTypeFunction;
    if (type is null)
        throw new Exception(
            text("ffi cannot make a callback entry for `",
                function_.toString, "`: it is not a function"),
        );
    if (type.parameterList.varargs == VarArg.variadic)
        throw new Exception(
            text("ffi cannot make a callback entry for `",
                function_.toString, "`: it is variadic"),
        );
    auto plan = shapeOf(function_, function_.resolvedLinkage, null, false);
    plan.buildCallbackLayout;
    return plan;
}

// Everything `prepareCommon` and `prepareCallback` share: the plan's
// whole shape, from `function_`'s signature and `linkage` alone, with
// `_address` left unset.
private CallPlan shapeOf(
    imported!"dmd.func".FuncDeclaration function_,
    in imported!"dmd.astenums".LINK linkage,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
) {
    import snakebite.frontend.dmd.delegates: hasHiddenThis;
    return _shapeOf(function_.type.isTypeFunction,
        hasHiddenThis(function_), linkage, extraArgumentTypes,
        isVariadicCall);
}

private CallPlan _shapeOf(
    imported!"dmd.mtype".TypeFunction type, in bool hasContext,
    in imported!"dmd.astenums".LINK linkage,
    scope imported!"dmd.mtype".Type[] extraArgumentTypes,
    in bool isVariadicCall,
) {
    import snakebite.ffi.abi:
        ArgumentPlan, Register, contextPrecedesHiddenReturnPointer,
        dVariadicArgumentsIsSlice, needsHiddenReturnPointer,
        reversedDParameters, supported;
    import dmd.astenums: LINK, STC, Tdelegate, VarArg;
    import dmd.typesem: nextOf, toBasetype;
    import std.conv: text;

    static if (!supported)
        throw new Exception(
            "ffi is implemented for the System V AMD64 ABI only",
        );
    else {
        if (type is null)
            throw new Exception(
                "ffi cannot call a value without a function type",
            );

        // A variadic callee is handed its extra arguments differently -
        // on the System V AMD64 ABI the caller must also report how many
        // SSE registers it used (`%al`) - so a fixed-arity plan would be
        // the wrong call, not merely an incomplete one. Only `VarArg.
        // variadic` (an `extern(C)` C-style variadic callee, or an
        // `extern(D)` untyped one - issue #334 steps 5 and 6) needs a
        // call site's own extra argument types, and only through
        // `prepareVariadic`, one call site at a time (this function's own
        // doc). `VarArg.typesafe` (`T t...`) needs neither: the frontend
        // has already packed a typesafe call's trailing arguments into
        // one array-typed argument by the time this ever runs
        // (`snakebite.backends.calls.arityMismatches`'s own doc), so it
        // classifies like any other declared parameter below, through the
        // ordinary `prepare`/`.of` path.
        const isCVariadic = type.parameterList.varargs == VarArg.variadic
            && linkage == LINK.c;
        // dmd's own frontend semantic (`dmd.expressionsem.
        // functionParameters`) inserts `_arguments` - a `TypeInfo_Tuple`
        // reference describing the call's own extra argument types - as
        // an ordinary leading argument on every `extern(D)` untyped
        // variadic call site, ahead of the declared parameters; nothing
        // about that insertion is C-specific, so this ABI fact holds
        // whichever host compiler built this process (ADR-0010's D
        // variadic paragraph).
        const isDVariadic = type.parameterList.varargs == VarArg.variadic
            && linkage == LINK.d;
        if (isVariadicCall) {
            if (!isCVariadic && !isDVariadic)
                throw new Exception(
                    text("ffi cannot call `", type.toString,
                        "` as a variadic function: only an `extern(C)` ",
                        "C-style or `extern(D)` untyped variadic callee ",
                        "is supported"),
                );
        } else if (type.parameterList.varargs == VarArg.variadic)
            throw new Exception(
                text("ffi cannot call the variadic function `",
                    type.toString, "`: only an `extern(C)` C-style ",
                    "or `extern(D)` untyped variadic callee is supported, ",
                    "and only at its own call site"),
            );

        // An `extern(D)` untyped variadic callee's own hidden `_arguments`
        // (this function's own doc above) is one more argument, alongside
        // `hasContext`'s hidden `this` - `addArgument` below places it
        // right after `this` and before every declared parameter, at
        // index `firstExplicit` (`buildMoves`'s own doc), so it falls
        // inside the very same reversed-or-forward group as the declared
        // parameters and the extra arguments that follow it. Its own
        // shape depends on the host compiler (`abi.
        // dVariadicArgumentsIsSlice`'s own doc): one pointer register on
        // dmd, a two-register `TypeInfo[]` slice on ldc.
        const hasVArguments = isVariadicCall && isDVariadic;

        const count = type.parameterList.length;
        const argumentCount = count + hasContext + hasVArguments
            + extraArgumentTypes.length;

        CallPlan plan;
        plan._arguments.length = argumentCount;
        // A `ref` return hands back the *address* of the result in the
        // return register, not the result: that address is what travels,
        // whatever `type.nextOf` says, so the return is a pointer and
        // never needs the hidden pointer a large returned *value* would.
        // The caller gets the address and reads the value through it -
        // the call adapter in `ffi.call` applies this same convention to
        // interpreted and native callees.
        const returnsRef = type.isRef != 0;
        plan._hiddenReturnPointer =
            !returnsRef && needsHiddenReturnPointer(type.nextOf);
        plan._contextPrecedesHiddenReturnPointer =
            contextPrecedesHiddenReturnPointer;

        // An `extern(D)` untyped variadic callee never reverses its
        // argument registers, even when `reversedDParameters` reverses
        // every other `extern(D)` call this host compiler makes: the
        // callee's own `_argptr`/register-save-area machinery (dmd's
        // `semantic3.d`, this function's own `isDVariadic` doc) has to
        // walk every parameter - `_arguments`, the declared ones, and
        // the extra ones after it - in one consistent forward order to
        // find where the register save area and the stack overflow area
        // begin, so dmd's own codegen keeps ordinary declaration order
        // for any `VarArg.variadic` callee (verified: disassembling a
        // real `extern(D) int f(int a, int b, int c, ...)` call built by
        // this exact dmd shows `%rdi`=`_arguments`, `%rsi`=`a`, `%rdx`=
        // `b`, `%rcx`=`c`, `%r8`/`%r9`=the two extra arguments - plain
        // declaration order, not reversed).
        plan._reversedArguments = reversedDParameters
            && (linkage == LINK.d || linkage == LINK.default_)
            && !isDVariadic;

        size_t argumentIndex;

        // The shape of a bare pointer-sized argument - a hidden `this`,
        // a `ref`/`out` parameter's own address, and, on dmd, (issue #334
        // step 6) an `extern(D)` untyped variadic callee's hidden
        // `_arguments` - all travel this same one-eightbyte-pointer way.
        enum ArgumentPlan pointerArgument = ArgumentPlan(
            [Register(Register.Kind.pointer, 8), Register.init], 1, false,
        );

        // On ldc, `_arguments` is a two-register `TypeInfo[]` slice
        // instead (`abi.dVariadicArgumentsIsSlice`'s own doc) - the same
        // shape `abi.classify`'s own `Tarray` case gives any other
        // dynamic-array-typed argument, length then pointer, both
        // integer-class.
        enum ArgumentPlan sliceArgument = ArgumentPlan(
            [Register(Register.Kind.integer, 8),
                Register(Register.Kind.integer, 8)], 2, false,
        );

        // Places one argument's `ArgumentPlan` in `plan`, at the next
        // available index - shared by the declared-parameter loop below
        // and, for a variadic call site, the extra-argument loop after it,
        // since both place an argument exactly the same way. `_arguments`
        // and `_moves` are dynamic arrays with a heap fallback beyond the
        // frame's inline stack area (see `CallArguments` and `Frame`), so
        // no fixed word budget applies here any more.
        void addArgument(in ArgumentPlan argument) {
            plan._arguments[argumentIndex++] = argument;
        }

        if (hasContext) {
            plan._hiddenContext = true;
            addArgument(pointerArgument);
        }

        // An `extern(D)` untyped variadic callee's hidden `_arguments`
        // (`hasVArguments`'s own doc above) is placed here, right after
        // any hidden `this` and right before every declared parameter -
        // exactly where the frontend itself puts it in `arguments[]`, and
        // exactly `firstExplicit` in `buildMoves`, so it shares that
        // function's reversed-or-forward group with the declared
        // parameters and the extra arguments added after them.
        if (hasVArguments)
            addArgument(
                dVariadicArgumentsIsSlice ? sliceArgument : pointerArgument);

        foreach (i; 0 .. count) {
            // A `ref` parameter occupies a pointer slot in the caller's
            // frame - the address of the argument's own storage, not a
            // copy of its value (see `FrameLayout.of` in
            // `backends/layout.d`, which lays such a slot out the
            // same way). That address is the value that travels, so the
            // argument is one pointer register whatever
            // `parameterList[i].type` - the *pointee* type - would
            // classify as.
            const storageClass = type.parameterList[i].storageClass;
            const isRef = (storageClass & (STC.ref_ | STC.out_)) != 0;
            auto parameterType = type.parameterList[i].type.toBasetype;
            auto pointer = parameterType.isTypePointer;
            const isFunctionPointer =
                pointer !is null && pointer.nextOf.isTypeFunction !is null;
            const isDelegate = parameterType.ty == Tdelegate
                || (storageClass & STC.lazy_) != 0;
            if (isFunctionPointer || isDelegate)
                plan._callbackArguments ~= CallPlan.CallbackArgument(
                    argumentIndex, isRef, isDelegate);
            addArgument(isRef
                ? pointerArgument
                : storageClass & STC.lazy_
                    ? ArgumentPlan(
                        [
                            Register(Register.Kind.pointer, 8),
                            Register(Register.Kind.pointer, 8),
                        ],
                        2,
                        false,
                    )
                : ArgumentPlan.of(type.parameterList[i].type));
        }

        // A variadic call site's own extra arguments classify exactly
        // like a named parameter (ADR-0010's C-variadics paragraph):
        // registers first, then the stack, in the same declaration-order
        // pass `buildMoves` already gives every argument above -
        // `argumentIndex` keeps counting up from where the declared
        // parameters left off, so `buildMoves` never has to know where
        // one group ends and the other begins.
        //
        // A function pointer or delegate extra argument gets the same
        // pool-entry swap (`callWithCallbacks`) a declared parameter of
        // that shape gets: its type is known at this call site, which is
        // all the swap needs.
        foreach (extraType; extraArgumentTypes) {
            auto pointer = extraType.isTypePointer;
            const isFunctionPointer =
                pointer !is null && pointer.nextOf.isTypeFunction !is null;
            const isDelegate = extraType.ty == Tdelegate;
            if (isFunctionPointer || isDelegate)
                plan._callbackArguments ~= CallPlan.CallbackArgument(
                    argumentIndex, false, isDelegate);
            addArgument(ArgumentPlan.of(extraType));
        }

        plan._parameterCount = argumentCount;
        if (returnsRef) {
            plan._return = ArgumentPlan(
                [Register(Register.Kind.pointer, 8), Register.init], 1,
                false,
            );
        } else if (!plan._hiddenReturnPointer)
            plan._return = ArgumentPlan.of(type.nextOf);

        plan.buildMoves;

        return plan;
    }
}
