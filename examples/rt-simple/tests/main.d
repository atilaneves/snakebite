import core.runtime: runModuleUnitTests;

int main() {
    const result = runModuleUnitTests();
    return result.passed == result.executed ? 0 : 1;
}
