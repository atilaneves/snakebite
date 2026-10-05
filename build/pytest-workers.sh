# Sourced by the build/test-*.sh scripts. SNAKEBITE_TEST_WORKERS sets the
# number of pytest-xdist workers. A later `-n` in PYTEST_ADDOPTS, for example
# `-n 0` to debug with `--pdb`, wins over it.
PYTEST_ADDOPTS="-n ${SNAKEBITE_TEST_WORKERS:-logical} --dist loadgroup ${PYTEST_ADDOPTS:-}"
export PYTEST_ADDOPTS
