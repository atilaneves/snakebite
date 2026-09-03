module snakebite.ffi;


public import snakebite.ffi.limits: maxArguments;
public import snakebite.ffi.call: CallAdapter, CallResult;
public import snakebite.ffi.callback:
    BoolFunction, BoolFunctionEntry, BoolFunctionTarget,
    boolFunctionEntryCount;
public import snakebite.ffi.plan: CallPlan, PlanCache;
public import snakebite.ffi.symbol: Resolver;


private:
