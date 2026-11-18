module ut.backends.call.inlineadmission;


import ut;
import snakebite.backends.bytecode.admission:
    Budget, Candidate, Rejection, consider;


@("inlineAdmission.concentratedTargetKeepsMissesInTheDenominator")
unittest {
    auto budget = Budget(192, 192, 512, 1);
    auto candidate = Candidate(90, 100, 96, 0, true);

    const decision = consider(candidate, budget);

    decision.admitted.should == true;
    decision.rejection.should == Rejection.none;
    budget.remainingBodyBytes.should == 96;
    budget.remainingCallerBytes.should == 416;
}


@("inlineAdmission.mixedTargetsStayOnTheGenericPath")
unittest {
    auto budget = Budget(192, 192, 512, 1);
    auto candidate = Candidate(89, 100, 96, 0, true);

    const decision = consider(candidate, budget);

    decision.admitted.should == false;
    decision.rejection.should == Rejection.targetShare;
    budget.remainingBodyBytes.should == 192;
    budget.remainingCallerBytes.should == 512;
}


@("inlineAdmission.fullCacheFallbackCallsRemainInTheDenominator")
unittest {
    auto budget = Budget(192, 192, 512, 1);
    auto candidate = Candidate(255, 256, 160, 0, true);

    const decision = consider(candidate, budget);

    decision.admitted.should == true;
    budget.remainingBodyBytes.should == 32;
}


@("inlineAdmission.rejectsUnstableOrSaturatedCounts")
unittest {
    auto budget = Budget(192, 192, 512, 1);
    auto candidate = Candidate(255, 256, 96, 0, false);
    consider(candidate, budget).rejection.should == Rejection.unstableProfile;

    candidate.stable = true;
    candidate.totalCalls = uint.max;
    consider(candidate, budget).rejection.should == Rejection.unstableProfile;
}


@("inlineAdmission.spendsSharedBodyCallerAndDepthBudgets")
unittest {
    auto budget = Budget(192, 192, 32, 1);
    auto candidate = Candidate(100, 100, 193, 0, true);
    budget.maxBodyBytes.should == 192;
    candidate.bodyBytes.should == 193;
    consider(candidate, budget).rejection.should == Rejection.bodySize;

    candidate.bodyBytes = 64;
    consider(candidate, budget).rejection.should == Rejection.callerSize;
    budget.remainingCallerBytes = 128;
    candidate.depth = 1;
    consider(candidate, budget).rejection.should == Rejection.depth;
    budget.remainingCallerBytes = 128;
    candidate.depth = 0;
    consider(candidate, budget).admitted.should == true;
    budget.remainingBodyBytes.should == 128;
    budget.remainingCallerBytes.should == 64;
}
