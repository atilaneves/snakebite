#!/usr/bin/env bash
# Checks that each corpus project runs the same from a compile to RAM and from
# a load of its saved file, with and without the JIT. Arguments select
# projects (name@version, as in build/corpus-projects.txt).
# Environment: SB (bin/sb), CORE (cpu to pin to, default 0),
# PROJECT_TIMEOUT (seconds per command, default 1200), WORK (output directory).
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

sb=${SB:-bin/sb}
core=${CORE:-0}
limit=${PROJECT_TIMEOUT:-1200}
work=${WORK:-$(mktemp -d /tmp/saved-corpus.XXXXXX)}
mkdir -p "$work"

if (($#)); then
    projects=("$@")
else
    mapfile -t projects < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' \
        -e '/^$/d' build/corpus-projects.txt)
fi

# run NAME ARGS...: stdout to NAME.out without the timing report lines of
# bin/sb, stderr to NAME.err, exit status to NAME.status (124: timeout).
run() {
    local name=$1; shift
    timeout "$limit" taskset -c "$core" "$sb" "$@" \
        >"$name.raw" 2>"$name.err"
    echo $? >"$name.status"
    grep -Ev '^[A-Za-z ]+:[[:space:]]+[0-9.]+ ms$' "$name.raw" >"$name.out" \
        || true
}

project_dir() {
    local name=${1%%@*} version=${1#*@}
    local dir=$HOME/.dub/packages/$name/$version/$name
    # Like bin/bench: a package that is not on disk is fetched.
    [[ -d $dir ]] || dub fetch "$name@$version" >/dev/null 2>&1
    [[ -d $dir ]] && echo "$dir"
}

same() { # DIR_A DIR_B: status, stdout and stderr equal
    local a=$1 b=$2
    cmp -s "$a.status" "$b.status" && cmp -s "$a.out" "$b.out" \
        && cmp -s "$a.err" "$b.err"
}

failed=0
for project in "${projects[@]}"; do
    dir=$(project_dir "$project") || {
        printf '%-28s load failed: no project directory\n' "$project"
        failed=1; continue
    }
    p=$work/${project//[@\/]/_}
    mkdir -p "$p"
    common=(--backend=bytecode)
    run "$p/ram" "${common[@]}" "$dir"
    run "$p/ram2" "${common[@]}" "$dir"
    run "$p/save" "${common[@]}" "--save=$p/file.sbc" "$dir"
    result=same
    if [[ $(<"$p/ram.status") == 124 ]]; then
        result="timeout (compile to RAM)"
    elif ! same "$p/ram" "$p/ram2"; then
        result="not comparable: two runs from RAM differ"
    elif [[ $(<"$p/save.status") == 124 ]]; then
        result="timeout (save)"
    elif [[ $(<"$p/save.status") != "$(<"$p/ram.status")" || ! -s $p/file.sbc ]]; then
        result="save failed (see $p/save.err)"
    else
        for mode in jit no-jit; do
            flags=(); [[ $mode == no-jit ]] && flags=(--no-jit)
            run "$p/$mode" "${flags[@]}" "--load=$p/file.sbc"
            if [[ $(<"$p/$mode.status") == 124 ]]; then
                result="timeout ($mode load)"; break
            elif ! same "$p/ram" "$p/$mode"; then
                if [[ $(<"$p/$mode.status") != "$(<"$p/ram.status")" \
                    && $(<"$p/$mode.status") != 0 \
                    && ! -s $p/$mode.out && -s $p/$mode.err \
                    && -z $(<"$p/ram.out") ]]; then
                    result="load failed ($mode; see $p/$mode.err)"
                else
                    result="different ($mode; compare $p/ram.* with $p/$mode.*)"
                fi
                break
            fi
        done
    fi
    printf '%-28s %s\n' "$project" "$result"
    [[ $result == same ]] || failed=1
done
echo "outputs: $work"
exit "$failed"
