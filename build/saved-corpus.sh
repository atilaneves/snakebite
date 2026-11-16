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
# bin/sb and without the one "Time taken" line of the unit-threaded runner
# (unit_threaded/runner/testsuite.d prints it with a Duration), stderr to
# NAME.err, exit status to NAME.status (124: timeout).
duration='[0-9]+ (weeks?|days?|hours?|minutes?|secs?|ms|μs|hnsecs?)'
taken="^Time taken: $duration((, | and |, and )$duration)*\$"
run() {
    local name=$1; shift
    timeout "$limit" taskset -c "$core" "$sb" "$@" \
        >"$name.raw" 2>"$name.err"
    echo $? >"$name.status"
    grep -Ev -e '^[A-Za-z ]+:[[:space:]]+[0-9.]+ ms$' -e "$taken" \
        "$name.raw" >"$name.out" || true
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

# firstdiff A B: the first differing line pair of the stdout, else of the
# stderr, of two runs.
firstdiff() {
    local a=$1 b=$2 ext n
    for ext in out err; do
        cmp -s "$a.$ext" "$b.$ext" && continue
        n=$(cmp "$a.$ext" "$b.$ext" 2>&1 | sed -n 's/.*line \([0-9]*\).*/\1/p')
        if [[ -n $n ]]; then
            printf '%s line %s:\n  < %s\n  > %s' "$ext" "$n" \
                "$(sed -n "${n}p" "$a.$ext" | cut -c1-200)" \
                "$(sed -n "${n}p" "$b.$ext" | cut -c1-200)"
        else # one file is a prefix of the other
            printf '%s: one is a prefix of the other' "$ext"
        fi
        return
    done
    printf 'exit status: %s vs %s' "$(<"$a.status")" "$(<"$b.status")"
}

# firsterror NAME: first line that looks like an error, else first stderr line.
firsterror() {
    local l
    l=$(cat "$1.err" "$1.out" | grep -av '^Warning' \
        | grep -aiE -m1 'error|failed|cannot be found' | cut -c1-200)
    [[ -n $l ]] || l=$(head -n1 "$1.err" | cut -c1-200)
    printf '%s' "$l"
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
        if [[ $(<"$p/ram.status") != 0 ]]; then
            result="fails from RAM: exit $(<"$p/ram.status"), $(firsterror "$p/ram")"
        else
            result="not comparable: two runs from RAM differ; $(firstdiff "$p/ram" "$p/ram2")"
        fi
    elif [[ $(<"$p/save.status") == 124 ]]; then
        result="timeout (save)"
    elif [[ $(<"$p/save.status") != "$(<"$p/ram.status")" || ! -s $p/file.sbc ]]; then
        if [[ $(<"$p/ram.status") != 0 ]]; then
            result="fails from RAM: exit $(<"$p/ram.status"), $(firsterror "$p/ram")"
        else
            result="save failed (see $p/save.err)"
        fi
    else
        parts=()
        for mode in jit no-jit; do
            flags=(); [[ $mode == no-jit ]] && flags=(--no-jit)
            run "$p/$mode" "${flags[@]}" "--load=$p/file.sbc"
            if [[ $(<"$p/$mode.status") == 124 ]]; then
                parts+=("timeout ($mode load)")
            elif ! same "$p/ram" "$p/$mode"; then
                if [[ $(<"$p/$mode.status") != "$(<"$p/ram.status")" \
                    && $(<"$p/$mode.status") != 0 \
                    && ! -s $p/$mode.out && -s $p/$mode.err \
                    && -z $(<"$p/ram.out") ]]; then
                    parts+=("load failed ($mode; see $p/$mode.err)")
                else
                    parts+=("different ($mode): $(firstdiff "$p/ram" "$p/$mode")")
                fi
            fi
        done
        if ((${#parts[@]})); then
            result=$(printf '%s\n' "${parts[@]}")
            ((${#parts[@]} == 1)) && result="${parts[0]} (the other load is same)"
        fi
    fi
    printf '%-28s %s\n' "$project" "$result"
    [[ $result == same ]] || failed=1
done
echo "outputs: $work"
exit "$failed"
