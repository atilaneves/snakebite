// Test hosts need exact linker exports for native fixtures called through guest
// declarations and for explicit resolver tests. Most fixtures use executable
// lookup by name because of the existing test design, not a D language rule.
// The host compiler derives the mangled names for the test-host export maps;
// production exports only rt_options. Keeping other host template instances
// private prevents ELF symbol interposition on loaded D code.
module host_exports;

// Each entry names a fixture and a consumer that resolves it by linker name.
// No module scan: new declarations stay private until explicitly designated.
mixin template Export(alias owner, string member, string consumer) {
    static assert(consumer.length != 0);
    pragma(msg, "SB_EXPORT\t" ~ __traits(getMember, owner, member).mangleof
        ~ "\t" ~ owner.stringof ~ "." ~ consumer);
}

version (SnakebiteAcceptanceHostExports) {
    import dabi = at.ffi.dabi;
    import dvariadic = at.ffi.dvariadic;
    mixin Export!(dabi, "snakebite_at_nineWords", "externD.parameterOrder");
    mixin Export!(__traits(getMember, dabi, "Host"), "make", "at.ffi.dabi.externD.methodReturningLargeAggregate");
    mixin Export!(dvariadic, "snakebite_at_dvariadic_probe", "snippet");
    mixin Export!(dvariadic, "invokeDVariadicCallback", "callbackSnippet");
} else:

import plan = ut.ffi.plan;
import aggregates = ut.ffi.aggregates;
import concurrency = ut.ffi.concurrency;
import symbols = ut.ffi.symbol;
import ffi = ut.backends.call.ffi;
import pointers = ut.backends.call.pointers;
import mainTests = ut.backends.run.main;
import virtualVariadic = ut.backends.run.virtual_variadic;
import classes = ut.backends.run.classes;
import cost = ut.backends.interpreter.cost;

mixin Export!(symbols, "snakebite_symbol_dual_definition_test", "symbolAddress.loadedSharedObjectAnswersBeforeExecutable");
mixin Export!(symbols, "snakebite_symbol_executable_only_test", "symbolAddress.fallsBackToExecutableWhenNothingElseHasIt");
mixin Export!(concurrency, "snakebite_ut_concurrency_wide", "plan.concurrentFirstPlansOfAFreshStructTypeAgree");
mixin Export!(plan, "snakebite_ut_plan_executable_only_target", "hasIndependentNativeSymbol.excludesExecutableOnlyAnswer");
mixin Export!(plan, "snakebite_ut_bump", "called.refParameter");
mixin Export!(plan, "snakebite_ut_cell", "called.refReturn");
mixin Export!(plan, "snakebite_ut_three_words", "called.hiddenPointerReturn");
mixin Export!(plan, "snakebite_ut_fieldless_return", "called.fieldlessReturnWritesThroughHiddenPointer");
mixin Export!(plan, "snakebite_ut_memory_param", "called.memoryClassParameter");
mixin Export!(plan, "snakebite_ut_pair", "called.smallStruct");
mixin Export!(plan, "snakebite_ut_floating_pair", "called.smallFloatingStruct");
mixin Export!(plan, "snakebite_ut_real_pair_returned", "called.scalarReal.aggregateReturn");
mixin Export!(plan, "snakebite_ut_real_pair_param", "called.scalarReal.aggregateParameter");
mixin Export!(plan, "snakebite_ut_mixed_pair", "called.mixedSmallStruct");
mixin Export!(plan, "snakebite_ut_mixed_after_six", "called.mixedStructOnStack");
mixin Export!(plan, "snakebite_ut_mixed_after_eight", "called.mixedStructAfterSSE");
mixin Export!(plan, "snakebite_ut_mixed_after_six_free_sse", "called.mixedStructOnStackFreeSSENotConsumed");
mixin Export!(plan, "snakebite_ut_mixed_after_eight_free_integer", "called.mixedStructAfterSSEFreeIntegerNotConsumed");
mixin Export!(plan, "snakebite_ut_mixed_both_files_full", "called.mixedStructBothFilesFull");
mixin Export!(plan, "snakebite_ut_externDMixedScalarSpill", "called.externD.mixedStructWithScalarSpill");
mixin Export!(plan, "snakebite_ut_mixed_reversed_after_six", "called.mixedStructDoubleFirstSpills");
mixin Export!(plan, "snakebite_ut_mixed_reversed_after_eight_doubles", "called.mixedStructReversedAfterEightDoubles");
mixin Export!(plan, "snakebite_ut_scale", "called.double");
mixin Export!(plan, "snakebite_ut_real_identity", "called.scalarReal.roundTrip");
mixin Export!(plan, "snakebite_ut_real_argument", "called.scalarReal.argumentOnly");
mixin Export!(plan, "snakebite_ut_real_result", "called.scalarReal.resultOnly");
mixin Export!(plan, "snakebite_ut_real_after_odd_stack", "called.scalarReal.afterOddStackWord");
mixin Export!(plan, "snakebite_ut_real_mixed", "called.scalarReal.mixedIntDouble");
mixin Export!(plan, "snakebite_ut_real_d", "called.scalarReal.externD");
mixin Export!(plan, "snakebite_ut_seven", "called.stackArgument");
mixin Export!(plan, "snakebite_ut_split_after_five", "called.splitEightbyteSpillsWhole");
mixin Export!(plan, "snakebite_ut_scale_float", "called.scalarFloat");
mixin Export!(plan, "snakebite_ut_eightLongs", "called.externD.eightLongsTwoSpill");
mixin Export!(plan, "snakebite_ut_mixedSpill", "called.externD.mixedSpillsOneLongOneDouble");
mixin Export!(plan, "snakebite_ut_double_of_long", "called.doubleOfLong");
mixin Export!(plan, "snakebite_ut_memory_after_six", "called.memoryClassParameter.afterSixIntegersThenOneMore");
mixin Export!(plan, "snakebite_ut_packed_pair", "called.memoryClassParameter.unalignedField");
mixin Export!(plan, "snakebite_ut_memoryTwoSpill", "called.externD.memoryClassParameterTwoScalarSpills");
mixin Export!(plan, "snakebite_ut_memory_with_sse", "called.memoryClassParameter.withSSEArguments");
mixin Export!(plan, "snakebite_ut_twenty_bytes", "called.memoryClassParameter.partialLastEightbyte");
mixin Export!(plan, "snakebite_ut_aligned_memory", "called.memoryClassParameter.alignedArgument");
mixin Export!(plan, "snakebite_ut_aligned_memory_after_odd_stack_word", "called.memoryClassParameter.alignedArgumentAfterOddStackWord");
mixin Export!(plan, "snakebite_ut_over_aligned", "called.memoryClassParameter.overAligned");
mixin Export!(plan, "snakebite_ut_large_memory", "called.memoryClassParameter.largeArgument");
mixin Export!(plan, "snakebite_ut_three_words_transform", "called.memoryClassParameter.returnedAndPassed");
mixin Export!(plan, "snakebite_ut_twoMemoryParams", "called.memoryClassParameter.twoParameters");
mixin Export!(plan, "snakebite_ut_sixteen_bytes_aligned", "called.memoryClassParameter.sixteenBytesAlignedField");
mixin Export!(plan, "snakebite_ut_memory_and_mixed", "called.mixedStructAfterMemoryOnStack");
mixin Export!(plan, "snakebite_ut_variadic_sum_ints", "called.variadic.tenIntsFourSpillToTheStack");
mixin Export!(plan, "snakebite_ut_variadic_count_sum", "called.variadic.sameCalleeTwoCallSitesDifferentArgumentCounts");
mixin Export!(plan, "snakebite_ut_variadic_sum_doubles", "called.variadic.nineDoublesOneSpills");
mixin Export!(plan, "snakebite_ut_variadic_mixed_pair", "called.variadic.mixedIntegerSSEStructArgument");
mixin Export!(plan, "snakebite_ut_dvariadic_count_sum", "called.variadic.externD.sevenIntsSpillTheIntegerFile");
mixin Export!(plan, "snakebite_ut_dvariadic_typesafe_sum", "called.variadic.externD.typesafeSlice");
mixin Export!(plan, "snakebite_ut_dvariadic_struct_sum", "called.variadic.externD.structArgumentPlacement");
mixin Export!(__traits(getMember, plan, "ContextHiddenPointer"), "getThreeWords", "ut.ffi.plan.called.contextPrecedesHiddenReturnPointer");
mixin Export!(__traits(getMember, plan, "ContextThenMixedSpill"), "sumFiveLongsThenMixed", "ut.ffi.plan.called.mixedStructAfterHiddenContext");
mixin Export!(__traits(getMember, plan, "ContextMemoryParam"), "addOffset", "ut.ffi.plan.called.memoryClassParameter.methodParameter");

mixin Export!(aggregates, "snakebite_ut_aggregates_large_memory", "memoryClassParameter.largeArguments");
mixin Export!(aggregates, "snakebite_ut_aggregates_owned_roundtrip", "nonPod.spilledArgumentAndCallback");
mixin Export!(aggregates, "snakebite_ut_aggregates_five_bytes", "registerResult.fiveBytesFromNative");
mixin Export!(aggregates, "snakebite_ut_aggregates_five_bytes_callback", "registerResult.fiveBytesFromGuestCallback");
mixin Export!(aggregates, "snakebite_ut_aggregates_void_array_echo", "voidStaticArray.echoedByValue");
mixin Export!(aggregates, "snakebite_ut_aggregates_real_array_echo", "realStaticArray.echoedByValue");
mixin Export!(aggregates, "snakebite_ut_aggregates_zero_length_echo", "zeroLengthArrayField.echoedByValue");
mixin Export!(aggregates, "snakebite_ut_aggregates_noreturn_echo", "noreturnField.echoedByValue");
// The explicit small-result fixture matrix generates these two declarations
// per entry. Each has its own named lookup consumer in the same matrix.
static foreach (type; __traits(getMember, aggregates, "smallTypes")) {
    mixin Export!(aggregates, "snakebite_ut_small_make_" ~ type.name, "smallResult.fromNative." ~ type.name);
    mixin Export!(aggregates, "snakebite_ut_small_sum_" ~ type.name, "smallResult.fromGuestCallback." ~ type.name);
}

mixin Export!(ffi, "snakebite_ut_null_value", "ffi.nullValueArgumentAndReturn");
mixin Export!(ffi, "snakebite_ut_dynamic_array", "dynamicArrayReturn.nativeFFI.Interpreter");
mixin Export!(ffi, "snakebite_ut_reset_non_copyable_aggregate_calls", "aggregateReturn.localDeclaration");
mixin Export!(ffi, "snakebite_ut_non_copyable_aggregate", "aggregateReturn.localDeclaration");
mixin Export!(ffi, "snakebite_ut_non_copyable_aggregate_call_count", "aggregateReturn.localDeclaration");
mixin Export!(ffi, "snakebite_ut_nineWords", "signatures.externD.nineWordsTwoStringsSpill");
mixin Export!(ffi, "snakebite_ut_remember", "signatures.arityAndDiscard");
mixin Export!(ffi, "snakebite_ut_recall", "signatures.arityAndDiscard");
mixin Export!(ffi, "snakebite_ut_add", "signatures.arityAndDiscard");
mixin Export!(ffi, "snakebite_ut_narrow", "signatures.narrowValues");
mixin Export!(ffi, "snakebite_ut_double_of_long", "signatures.doubleOfLong");
mixin Export!(ffi, "snakebite_ut_memory_triple", "memoryClassParameter.threeWords");
mixin Export!(ffi, "snakebite_ut_memory_after_six_backend", "memoryClassParameter.afterSixIntegersThenOneMore");
mixin Export!(ffi, "snakebite_ut_packed_pair_backend", "memoryClassParameter.unalignedField");
mixin Export!(ffi, "snakebite_ut_externDMemoryTwoSpill", "memoryClassParameter.externD.twoScalarSpills");
mixin Export!(ffi, "snakebite_ut_memory_with_sse_backend", "memoryClassParameter.withSSEArguments");
mixin Export!(ffi, "snakebite_ut_twenty_bytes_backend", "memoryClassParameter.partialLastEightbyte");
mixin Export!(ffi, "snakebite_ut_memoryTripleTransform_backend", "memoryClassParameter.returnedAndPassed");
mixin Export!(ffi, "snakebite_ut_twoMemoryParams_backend", "memoryClassParameter.twoParameters");
mixin Export!(ffi, "snakebite_ut_sixteen_bytes_aligned_backend", "memoryClassParameter.sixteenBytesAlignedField");
mixin Export!(ffi, "snakebite_ut_mixed_registers", "mixedStruct.registers");
mixin Export!(ffi, "snakebite_ut_mixed_after_six_then_scalar", "mixedStruct.onStackAfterSixIntegersThenScalar");
mixin Export!(ffi, "snakebite_ut_mixed_after_six_then_int_scalar", "mixedStruct.onStackAfterSixIntegersThenIntScalar");
mixin Export!(ffi, "snakebite_ut_mixed_after_eight_doubles", "mixedStruct.onStackAfterEightDoubles");
mixin Export!(ffi, "snakebite_ut_mixed_both_files_full_backend", "mixedStruct.bothFilesFull");
mixin Export!(ffi, "snakebite_ut_externDMixedStructScalarSpill", "mixedStruct.externD.scalarSpill");
mixin Export!(ffi, "snakebite_ut_mixed_reversed_after_six_backend", "mixedStruct.doubleFirstLayoutSpills");
mixin Export!(ffi, "snakebite_ut_mixed_reversed_after_eight_doubles", "mixedStruct.reversedAfterEightDoubles");
mixin Export!(ffi, "snakebite_ut_many_strings", "manyArguments.strings");
mixin Export!(ffi, "snakebite_ut_many_callback", "manyArguments.callback");
static foreach (linkage; ["C", "D"]) {
    static foreach (count; ["17", "257"]) {
        mixin Export!(ffi, "many" ~ linkage ~ count, "manyArguments." ~ linkage ~ count);
    }
}
mixin Export!(ffi, "snakebite_ut_call_c_variadic_callback", "callback.variadicC.nativeVaList");
mixin Export!(ffi, "snakebite_ut_call_mixed_c_variadic_callback", "callback.variadicC.mixedRegisterFiles");
mixin Export!(ffi, "snakebite_ut_call_spilled_c_variadic_callback", "callback.variadicC.overflowStack");
mixin Export!(ffi, "snakebite_ut_call_vector4_spilled_callback", "callback.vector4SpillsAfterEightSseArguments");
mixin Export!(ffi, "snakebite_ut_call_vector4_after_odd_stack_word", "ffi.callbackVectorSpillsAfterOddStackWord");
mixin Export!(ffi, "snakebite_ut_vector4_after_eight_doubles", "vector4SpillsAfterEightSseArguments");
mixin Export!(ffi, "snakebite_ut_call_d_variadic_callback", "callback.variadicD.argumentsAndCursor");
mixin Export!(ffi, "snakebite_ut_delegate_value", "delegateArgument.called.value");
mixin Export!(ffi, "snakebite_ut_delegate_ref", "delegateArgument.called.ref");
mixin Export!(ffi, "snakebite_ut_delegate_out", "delegateArgument.output.out");
mixin Export!(ffi, "snakebite_ut_delegate_lazy", "delegateArgument.called.lazy");
mixin Export!(ffi, "snakebite_ut_delegate_throwCaughtAsException", "callback.hostCatchesGuestException");
mixin Export!(ffi, "snakebite_ut_native_delegate", "delegateArgument.native");
mixin Export!(ffi, "snakebite_ut_invoke_delegate", "delegateArgument.native");
mixin Export!(ffi, "snakebite_ut_variadic_sum_ints_backend", "variadic.tenIntsFourSpillToTheStack");
mixin Export!(ffi, "snakebite_ut_variadic_count_sum_backend", "variadic.sameCalleeTwoCallSitesDifferentArgumentCounts");
mixin Export!(ffi, "snakebite_ut_variadic_sum_doubles_backend", "variadic.floatLiteralPromotedToDouble");
mixin Export!(ffi, "snakebite_ut_variadic_mixed_pair_backend", "variadic.mixedIntegerSSEStructArgument");
mixin Export!(ffi, "snakebite_ut_variadic_memory_then_int_backend", "variadic.memoryClassExtraThenInt");
mixin Export!(ffi, "snakebite_ut_variadic_six_ints_then_extras_backend", "variadic.sixIntsExhaustIntegerFileThenExtras");
mixin Export!(ffi, "snakebite_ut_variadic_zero_extras_int_backend", "variadic.zeroExtrasIntegerEntry");
mixin Export!(ffi, "snakebite_ut_variadic_zero_extras_double_backend", "variadic.zeroExtrasGeneralEntry");
mixin Export!(ffi, "snakebite_ut_dvariadic_mixed_sum_backend", "variadic.externD.twoCallSitesIntsAndDoublesSpill");
mixin Export!(ffi, "snakebite_ut_dvariadic_struct_backend", "variadic.externD.zeroSizeStructExtra");
mixin Export!(ffi, "snakebite_ut_dvariadic_string_backend", "variadic.externD.noAllocationOnRepeatedCall.Bytecode");
mixin Export!(ffi, "snakebite_ut_dvariadic_typesafe_backend", "variadic.externD.typesafeSlice");
mixin Export!(ffi, "snakebite_ut_dvariadic_length_type_sum_backend", "variadic.externD.lengthFirstTypeAndSums");
mixin Export!(ffi, "snakebite_ut_variadic_call_function_backend", "variadic.callbackExtraArgument.enumOfFunctionPointer");
mixin Export!(ffi, "snakebite_ut_variadic_call_delegate_backend", "variadic.callbackExtraArgument.enumOfDelegate");
mixin Export!(ffi, "snakebite_review_vector_union", "ffi.vectorUnionUsesIntegerRegistersForArguments");
mixin Export!(ffi, "snakebite_review_vector_union_return", "ffi.vectorUnionUsesIntegerRegistersForReturns");
mixin Export!(ffi, "snakebite_ut_vector4_after_odd_stack_word", "ffi.vectorSpillsAfterOddStackWord");
mixin Export!(ffi, "snakebite_review_complex_return", "complexRealReturn");
mixin Export!(ffi, "snakebite_ut_call_complex_real_callback", "complexRealCallbackReturn");
mixin Export!(ffi, "snakebite_ut_complex_real_argument", "complexRealArgument");

static foreach (member; [
    "snakebite_ut_call_bool_callback",
    "snakebite_ut_call_int_callback",
    "snakebite_ut_same_bool_callback",
    "snakebite_ut_collect_then_call_bool_callback",
    "snakebite_ut_call_bool_callback_on_thread",
    "snakebite_ut_sum_on_threads",
    "snakebite_ut_message_on_thread",
    "snakebite_ut_call_twice_on_same_thread_after_throw",
    "snakebite_ut_join_thread",
    "snakebite_ut_int_callback_on_thread",
    "snakebite_ut_int_callback_on_foreign_thread",
    "snakebite_ut_signal_foreign_attached",
    "snakebite_ut_collect_on_other_thread",
]) {
    mixin Export!(pointers, member, "hostCallbackDeclarations");
}
mixin Export!(pointers, "snakebite_ut_is_null_object", "pointers.null.classArgument");
mixin Export!(mainTests, "snakebite_ut_hostCallsGuestRef", "hostToGuestArguments.callback.refAndOutParameters");
mixin Export!(mainTests, "snakebite_ut_hostCallsGuestOut", "hostToGuestArguments.callback.refAndOutParameters");
mixin Export!(mainTests, "snakebite_ut_hostCallsGuestRefBig", "hostToGuestArguments.callback.refAndOutParameters");
mixin Export!(virtualVariadic, "snakebite_ut_virtual_variadic_host_interface", "virtualVariadic.hostInterfaceTarget");
mixin Export!(virtualVariadic, "snakebite_ut_virtual_variadic_host_class", "virtualVariadic.hostClassTarget");
mixin Export!(classes, "snakebite_ut_destructor_real_only_return", "destructorExecutedBranchWithRealAggregateNativeCall");
mixin Export!(classes, "hostDispatchObject", "hostCreatedObjectUsesVirtualGuestDispatch.Interpreter");
mixin Export!(__traits(getMember, classes, "LinkedScopeResource"), "__ctor", "ut.backends.run.classes.linkedScopeClassRunsDestructorAtScopeExit");
mixin Export!(__traits(getMember, classes, "LinkedScopeResource"), "__dtor", "ut.backends.run.classes.linkedScopeClassRunsDestructorAtScopeExit");
mixin Export!(cost, "fillFinalizerTestCache", "ordinaryCallbackGuest");
mixin Export!(cost, "callFinalizerTestCallback", "ordinaryCallbackGuest");
mixin Export!(cost, "callPreparedTestCallback", "ordinaryCallbackGuest");
