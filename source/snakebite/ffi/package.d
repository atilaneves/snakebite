module snakebite.ffi;


public import snakebite.ffi.limits: maxArguments;
public import snakebite.ffi.call:
    CallResult, invokeCall, rejectHostReferenceReturn, returnFromCall,
    storeArgument;
public import snakebite.ffi.plan: CallPlan, PlanCache;
public import snakebite.ffi.symbol: Resolver;


private:
