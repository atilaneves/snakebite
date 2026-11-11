module snakebite.backends.statistics;


private:


// Cumulative work done by a backend's compiler. A backend without a
// compilation phase leaves `hasCompiler` false; this is distinct from a
// compiler whose measured duration is zero.
public struct CompilationStatistics {
    import core.time: Duration;

    bool hasCompiler;
    size_t cacheMisses;
    Duration duration;
}


// Wall time since `start`, less the time that `statistics` shows as compiled
// in it, so that an interval and the compilation it causes are reported once
// each. It reads `statistics` on each `peek`, so the statistics must outlive
// the clock.
public struct ExecutionClock {
    import core.time: Duration, MonoTime;

    private const(CompilationStatistics)* _statistics;
    private MonoTime _start;
    private Duration _compiledAtStart;

    public static ExecutionClock start(
        ref const CompilationStatistics statistics,
    ) {
        return ExecutionClock(
            &statistics,
            MonoTime.currTime,
            statistics.duration,
        );
    }

    public Duration peek() const {
        const compiled = _statistics.duration - _compiledAtStart;
        return MonoTime.currTime - _start - compiled;
    }
}
