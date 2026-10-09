module snakebite.backends.returnstorage;


private:


package struct ReturnStoragePlan {
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;

    package bool hasPlace;
    private VarDeclaration _selected;

    package static ReturnStoragePlan of(FuncDeclaration function_) {
        import snakebite.frontend.compiler: returnsOnStack;

        ReturnStoragePlan plan;
        plan.hasPlace = returnsOnStack(function_);
        // semantic3 owns checkNRVO: captures, alignment, local ownership,
        // and agreement between all returns are already resolved here.
        plan._selected = function_.isNRVO ? function_.nrvo_var : null;
        return plan;
    }

    package bool aliases(VarDeclaration variable) const {
        // DMD e2ir also maps generated copy/move and out-result locals
        // marked nrvo to the hidden return pointer, independently of isNRVO.
        return hasPlace && (variable is _selected || variable.nrvo);
    }
}
