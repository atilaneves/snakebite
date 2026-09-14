module snakebite.ffi.plan;


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
    private struct DelegateArgument {
        size_t index;
        bool indirect;
    }
    private DelegateArgument[] _delegateArguments;
    private GuestDelegates* _guestDelegates;
    private string _hostName;

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
        if (_delegateArguments.length)
            checkDelegates(arguments);

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

    private void checkDelegates(scope const(void*)[] arguments) const {
        import snakebite.nativelayout: delegateFunctionOffset;
        import snakebite.exception: SnakebiteException;
        import std.conv: text;

        foreach (argument; _delegateArguments) {
            // auto would retain the slot's top-level const qualifier.
            const(void)* place = arguments[argument.index];
            if (argument.indirect)
                place = *cast(const(void*)*) place;
            if (place is null)
                continue;
            const address = *cast(const(void*)*)
                (cast(const(ubyte)*) place + delegateFunctionOffset);
            if (address in _guestDelegates.addresses)
                throw new SnakebiteException(text("ffi cannot call `",
                    _hostName, "`: guest delegate callbacks are not supported"));
        }
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

// The plans already prepared, one per function. A backend owns one of
// these and keeps it for its whole life, so the second call to a function
// and every call after it reuses the first call's answers.
//
// Keyed by declaration rather than by call site: two call sites naming the
// same function need the very same plan, and the declaration is what both
// resolve to. A call site is the finer key, and would let a plan be found
// without hashing at all, but it needs somewhere on the call site to keep
// it, which is the caller's business and not this package's.
private struct GuestDelegates {
    bool[const(void)*] addresses;
}


public struct PlanCache {
    private GuestDelegates* _guestDelegates;

    // Only addresses emitted by a backend are registered. Host code
    // addresses must never be inspected as frontend or bytecode objects.
    public void registerGuestDelegate(const(void)* address) {
        guestDelegates.addresses[address] = true;
    }

    private GuestDelegates* guestDelegates() {
        if (_guestDelegates is null)
            _guestDelegates = new GuestDelegates;
        return _guestDelegates;
    }

    private CallPlan*[imported!"dmd.func".FuncDeclaration] _plans;
    private CallPlan*[string] _rawPlans;
    private bool[imported!"dmd.func".FuncDeclaration] _nativeSymbols;
    private Resolver _resolver;
    private size_t _preparations;
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

        version(unittest) ++_nativeSymbolLookups;
        auto target = nativeTarget(function_);
        const found = target.address !is null || resolve(
            mangleExact(function_).fromStringz,
        ) !is null;
        _nativeSymbols[function_] = found;
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
        return _preparations;
    }

    // `function_`'s plan, prepared on its first call and reused after.
    //
    // Returned by reference: the plan stays in the cache, and a caller
    // only ever calls through it.
    public ref const(CallPlan) of(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        if (auto cached = function_ in _plans)
            return **cached;

        ++_preparations;
        auto plan = new CallPlan;
        *plan = prepare(function_, _resolver);
        plan._guestDelegates = guestDelegates;
        _plans[function_] = plan;
        return *plan;
    }

    // As `.of`, but for one call site of an `extern(C)` C-style variadic
    // callee (`prepareVariadic`'s own doc): the plan depends on that
    // call's own extra argument types, not on `function_` alone, so this
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
        ++_preparations;
        auto plan = new CallPlan;
        *plan = prepareVariadic(function_, _resolver, extraArgumentTypes);
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

        ++_preparations;
        auto plan = new CallPlan;
        *plan = CallPlan.ofRawAddress(
            address, parameterRegisters, returnRegister);
        _rawPlans[name] = plan;
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

// As `prepare`, for one call site of an `extern(C)` C-style variadic
// callee: `extraArgumentTypes` are that call's own extra arguments'
// types, in call order, after the frontend has already applied C's
// default argument promotions (`float` widens to `double`, an integral
// narrower than `int` widens to `int`) - exactly the types the callee's
// own `va_arg` will read. `PlanCache.variadicOf` is the one caller.
//
// The plan this builds is one call site's own shape, not `function_`'s
// alone (ADR-0010's C-variadics paragraph; issue #334 step 5): two call
// sites naming the same variadic function can pass different extra
// arguments, and need different plans. This is never cached by
// `function_` the way `PlanCache._plans` caches an ordinary plan - a
// backend's own call-site cache (`PlanCache.of`'s own doc, issue #96) is
// what makes a repeat call at the same site free instead.
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
    import snakebite.frontend.dmd.delegates: hasHiddenThis;
    import snakebite.druntime.constructoratomic: nativeTarget;
    import snakebite.ffi.abi:
        ArgumentPlan, Register, contextPrecedesHiddenReturnPointer,
        needsHiddenReturnPointer, reversedDParameters,
        supported;
    import dmd.astenums: LINK, STC, Tdelegate, VarArg;
    import dmd.mangle: mangleExact;
    import dmd.typesem: nextOf, toBasetype;
    import std.conv: text;
    import std.string: fromStringz;

    static if (!supported)
        throw new Exception(
            "ffi is implemented for the System V AMD64 ABI only",
        );
    else {
        auto type = function_.type.isTypeFunction;
        if (type is null)
            throw new Exception(
                text("ffi cannot call `", function_.toString,
                    "`: it is not a function"),
            );

        auto target = nativeTarget(function_);

        // The symbol's calling convention comes from its declared linkage,
        // and `extern(D)` code built by the host's own compiler can read
        // its parameters out of the registers in reverse order - an ABI
        // fact about this process, not a routing decision about the
        // callee. `isVariadicCall` below needs this fact too, to tell an
        // `extern(C)` variadic callee from an `extern(D)` one, so this
        // moves ahead of that check instead of running only for
        // `_reversedArguments` further down.
        const linkage = target.address is null
            ? function_.resolvedLinkage : target.linkage;

        // A variadic callee is handed its extra arguments differently -
        // on the System V AMD64 ABI the caller must also report how many
        // SSE registers it used (`%al`) - so a fixed-arity plan would be
        // the wrong call, not merely an incomplete one. Only an
        // `extern(C)` callee (`VarArg.variadic` with C linkage) is
        // supported, and only through `prepareVariadic`, one call site at
        // a time (this function's own doc). Every other variadic kind -
        // D's untyped `_arguments` (issue #334 step 6) and typesafe
        // `T t...`, both always `extern(D)` - stays refused here, even
        // when `isVariadicCall` is set: only a genuine C-style variadic
        // callee can ever satisfy that call.
        const isCVariadic = type.parameterList.varargs == VarArg.variadic
            && linkage == LINK.c;
        if (isVariadicCall) {
            if (!isCVariadic)
                throw new Exception(
                    text("ffi cannot call `", function_.toString,
                        "` as a variadic function: only an `extern(C)` ",
                        "C-style variadic callee is supported"),
                );
        } else if (type.parameterList.varargs != VarArg.none)
            throw new Exception(
                text("ffi cannot call the variadic function `",
                    function_.toString, "`: only an `extern(C)` C-style ",
                    "variadic callee is supported, and only at its own ",
                    "call site"),
            );

        const count = type.parameterList.length;
        const hasContext = hasHiddenThis(function_);
        const argumentCount =
            count + hasContext + extraArgumentTypes.length;
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

        plan._reversedArguments = reversedDParameters
            && (linkage == LINK.d || linkage == LINK.default_);

        size_t argumentIndex;

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
            addArgument(ArgumentPlan(
                [Register(Register.Kind.pointer, 8), Register.init], 1,
                false,
            ));
        }

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
            // An out parameter is initialized by the callee before use.
            if ((storageClass & STC.out_) == 0
                    && (type.parameterList[i].type.toBasetype.ty == Tdelegate
                        || (storageClass & STC.lazy_) != 0)) {
                plan._delegateArguments ~= CallPlan.DelegateArgument(
                    argumentIndex, isRef);
                plan._hostName = function_.toString.idup;
            }
            addArgument(isRef
                ? ArgumentPlan(
                    [Register(Register.Kind.pointer, 8), Register.init], 1,
                    false,
                )
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
        // A function pointer or delegate extra argument is refused
        // instead: a *parameter* of that shape crosses through the
        // callback pool's per-function slot (ADR-0003), which a named
        // parameter's type gives a way to install ahead of the call, but
        // a variadic extra argument has no parameter for that slot to
        // attach to. Passing one through here would hand the callee the
        // guest's own function value's bytes, not a callable address
        // (issue #9).
        foreach (extraType; extraArgumentTypes) {
            auto pointer = extraType.isTypePointer;
            const isFunctionPointer =
                pointer !is null && pointer.nextOf.isTypeFunction !is null;
            if (isFunctionPointer || extraType.ty == Tdelegate)
                throw new Exception(
                    text("ffi cannot pass `", extraType.toString, "` as a ",
                        "variadic argument to `", function_.toString,
                        "`: a function pointer or delegate extra argument ",
                        "has no callback pool entry (ADR-0003)"),
                );
            addArgument(ArgumentPlan.of(extraType));
        }

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
