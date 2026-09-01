import reggae;

alias ut = dubBuild!(Configuration("unittest"));
alias sb = dubBuild!(Configuration("sb"));

mixin build!(ut, sb);
