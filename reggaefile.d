import reggae;

alias ut = dubBuild!(Configuration("unittest"));
alias sb = dubBuild!(Configuration("sb"));
// Named "at" to match the acceptance-test dub config's targetName, so
// `ninja -C bin/acceptance at` (see build/acceptance.sh) resolves it.
alias at = dubBuild!(Configuration("acceptance-test"));
// Named "bench" to match the bench dub config's targetName, so
// `ninja -C bin bench` (see build/bench.sh) resolves it.
alias bench = dubBuild!(Configuration("bench"));

mixin build!(ut, sb, at, bench);
