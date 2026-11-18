#!/usr/bin/env bash
# Checks that each corpus project runs the same from a compile to RAM and from
# a load of its saved file. The loads run with the JIT and with --no-jit.
# "Same" means equal exit status and stdout, and equal stderr: the stderr of
# the --save run followed by the stderr of the load equals the stderr of the
# run from RAM. Arguments select projects, each one an argument of bin/sb
# (name@version as in build/bench-corpus.sh, or a directory).
# Environment: SB (bin/sb), CORE (cpu to pin to, default 0),
# PROJECT_TIMEOUT (seconds per command, default 1200), WORK (output
# directory; the saved file of a project that is the same is removed).
# With --project as the first argument the script checks the project mode
# (bin/sb --build=project) instead: see project_check. The default projects
# are then the five short ones of the corpus.
set -uo pipefail
export LC_ALL=C
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

sb=${SB:-bin/sb}
core=${CORE:-0}
limit=${PROJECT_TIMEOUT:-1200}
work=${WORK:-$(mktemp -d /tmp/saved-corpus.XXXXXX)}
mkdir -p "$work"
work=$(realpath -- "$work")
[[ $sb == */* ]] && sb=$(realpath -- "$sb")

mode=ram
if [[ ${1:-} == --project ]]; then mode=project; shift; fi

if (($#)); then
    projects=("$@")
else
    source build/bench-corpus.sh # the list; sets -e
    set +e
    projects=()
    for b in "${benchmarks[@]}"; do
        if [[ $mode == project ]]; then
            case ${b%@*} in
                cerealed|automem|msgpack-d|sumtype|tardy) ;;
                *) continue ;;
            esac
        fi
        projects+=("$b")
    done
fi

# run NAME ARGS...: stdout to NAME.out without the timing report lines of
# bin/sb and without the one "Time taken" line of the unit-threaded runner
# (unit_threaded/runner/testsuite.d prints it with a Duration), stderr to
# NAME.err, exit status to NAME.status (124: timeout).
duration='[0-9]+ (weeks?|days?|hours?|minutes?|secs?|ms|μs|hnsecs?)'
taken="^Time taken: $duration((, | and |, and )$duration)*\$"
run() {
    local name=$1; shift
    (cd -- "${rundir:-.}" && timeout "$limit" taskset -c "$core" "$sb" "$@") \
        >"$name.raw" 2>"$name.err"
    echo $? >"$name.status"
    grep -aEv -e '^[A-Za-z ]+:[[:space:]]+[0-9.]+ ms$' -e "$taken" \
        "$name.raw" >"$name.out" || true
}

same() { # A B: status, stdout and stderr equal
    local a=$1 b=$2
    cmp -s "$a.status" "$b.status" && cmp -s "$a.out" "$b.out" \
        && cmp -s "$a.err" "$b.err"
}

# show: one line of text on stdin, made printable and cut.
show() { tr '\000-\010\013-\037' '?' | cut -c1-200; }

# firstdiff A B: the first difference of the stdout, else of the stderr, else
# of the exit status, of two runs, on one line.
firstdiff() {
    local a=$1 b=$2 ext n cmpout short long lines
    for ext in out err; do
        cmp -s "$a.$ext" "$b.$ext" && continue
        cmpout=$(cmp "$a.$ext" "$b.$ext" 2>&1)
        if [[ $cmpout == *"EOF on "* ]]; then # one is a prefix of the other
            short=$a long=$b
            (($(stat -c %s "$b.$ext") < $(stat -c %s "$a.$ext"))) \
                && short=$b long=$a
            lines=$(grep -ac '' "$short.$ext")
            n=$((lines + 1))
            # A last line without newline is part of the first extra line.
            [[ -n $(tail -c1 "$short.$ext" | tr -d '\000') ]] && n=$lines
            printf '%s: %s ends early; first extra line %s: %s' "$ext" \
                "$short" "$n" "$(sed -n "${n}p" "$long.$ext" | show)"
        else
            n=$(sed -n 's/.*line \([0-9]*\).*/\1/p' <<<"$cmpout")
            printf '%s line %s: < %s | > %s' "$ext" "$n" \
                "$(sed -n "${n}p" "$a.$ext" | show)" \
                "$(sed -n "${n}p" "$b.$ext" | show)"
        fi
        return
    done
    printf 'exit status: %s vs %s' "$(<"$a.status")" "$(<"$b.status")"
}

# lasterr NAME: the last lines of stderr, else of stdout, on one line.
lasterr() {
    local f=$1.err
    [[ -s $f ]] || f=$1.out
    tail -n3 "$f" | tr '\000-\010\013-\037' '?' | cut -c1-200 | paste -sd'|'
}

failed=0
report() { # PROJECT RESULT
    printf '%-28s %s\n' "$1" "$2"
    [[ $2 == same ]] || failed=1
}

# project_check PROJECT: three runs of bin/sb --build=project on a copy of the
# project, each the same as bin/sb on the copy: the first run, a run with no
# change (ninja has no work, so no compile runs) and a run after a touch of the
# first root source file in lexical order. The project state directory is
# under the directory that bin/sb starts in, so that is a directory of
# $work and the package cache of dub is not written by the build.
project_check() {
    local project=$1 p=$work/${1//[@\/]/_} src name version root
    rm -rf "$p"; mkdir -p "$p/start"
    if [[ -d $project ]]; then
        src=$project
    else
        name=${project%@*} version=${project#*@}
        src=$HOME/.dub/packages/$name/$version/$name
        [[ -d $src ]] || "$sb" "$project" >/dev/null 2>&1 # fetches it
    fi
    [[ -d $src ]] || { report "$project" "no project directory"; return; }
    cp -a -- "$src" "$p/copy"
    rundir=. run "$p/ref" --backend=bytecode "$p/copy"
    if [[ $(<"$p/ref.status") == 124 ]]; then
        report "$project" "timeout (bin/sb)"; return
    fi
    root=$(find "$p/copy/source" "$p/copy/src" -name '*.d' 2>/dev/null \
        | sort | head -n1)
    [[ -n $root ]] || { report "$project" "no root source file"; return; }
    local ninjafile results=() step
    for step in first nochange touched; do
        case $step in
            nochange) # ninja's own dry run: the build has no work
                ninjafile=$(ls "$p"/start/.snakebite/*/build/build.ninja)
                [[ $(ninja -n -f "$ninjafile" 2>&1) == *"no work to do"* ]] \
                    || results+=("compile planned (nochange)") ;;
            touched)
                touch -- "$root"
                [[ $(ninja -n -f "$ninjafile" 2>&1) == *"no work to do"* ]] \
                    && results+=("touch planned no compile (touched)") ;;
        esac
        rundir=$p/start run "$p/$step" --build=project "$p/copy"
        if [[ $(<"$p/$step.status") == 124 ]]; then
            results+=("timeout ($step)")
        elif ! same "$p/ref" "$p/$step"; then
            results+=("different ($step): $(firstdiff "$p/ref" "$p/$step")")
        fi
    done
    if ((${#results[@]} == 0)); then
        rm -rf "$p"
        report "$project" same
    else
        for r in "${results[@]}"; do report "$project" "$r"; done
    fi
}

if [[ $mode == project ]]; then
    for project in "${projects[@]}"; do project_check "$project"; done
    echo "outputs: $work"
    exit "$failed"
fi

for project in "${projects[@]}"; do
    p=$work/${project//[@\/]/_}
    mkdir -p "$p"
    rm -f "$p/file.sbc"
    common=(--backend=bytecode)
    run "$p/ram" "${common[@]}" "$project"
    ram=$(<"$p/ram.status")
    if [[ $ram == 124 ]]; then
        report "$project" "timeout (compile to RAM)"; continue
    elif [[ $ram != 0 ]]; then
        report "$project" "fails from RAM: exit $ram, $(lasterr "$p/ram")"
        continue
    fi
    run "$p/ram2" "${common[@]}" "$project"
    if ! same "$p/ram" "$p/ram2"; then
        report "$project" \
            "not comparable: two runs from RAM differ; $(firstdiff "$p/ram" "$p/ram2")"
        continue
    fi
    run "$p/save" "${common[@]}" "--save=$p/file.sbc" "$project"
    if [[ $(<"$p/save.status") == 124 ]]; then
        report "$project" "timeout (save)"; continue
    elif [[ $(<"$p/save.status") != "$ram" || ! -s $p/file.sbc ]]; then
        report "$project" "save failed (see $p/save.err)"; continue
    fi
    results=()
    for mode in jit no-jit; do
        flags=(); [[ $mode == no-jit ]] && flags=(--no-jit)
        run "$p/$mode" "${flags[@]}" "--load=$p/file.sbc"
        # The stderr of the save run and then of the load.
        mv "$p/$mode.err" "$p/$mode.load.err"
        cat "$p/save.err" "$p/$mode.load.err" >"$p/$mode.err"
        status=$(<"$p/$mode.status")
        if [[ $status == 124 ]]; then
            results+=("timeout ($mode load)")
        elif [[ $status != 0 && ! -s $p/$mode.out ]]; then
            results+=("load failed ($mode; see $p/$mode.load.err)")
        elif ! same "$p/ram" "$p/$mode"; then
            results+=("different ($mode): $(firstdiff "$p/ram" "$p/$mode")")
        fi
    done
    if ((${#results[@]} == 0)); then
        rm -f "$p/file.sbc"
        report "$project" same
    else
        for r in "${results[@]}"; do report "$project" "$r"; done
    fi
done
echo "outputs: $work"
exit "$failed"
