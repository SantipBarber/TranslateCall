/// Waits for a stream-collector task to finish on its own (it breaks on a terminal value) and
/// cancels it only after `timeout`. Replaces fixed 50 ms sleeps, which flaked when the full suite
/// kept the MainActor busy and the collector had not run yet.
func finish(_ task: Task<Void, Never>, within timeout: Duration = .seconds(5)) async {
    let timer = Task {
        try? await Task.sleep(for: timeout)
        task.cancel()
    }
    await task.value
    timer.cancel()
}

/// Polls `condition` until it holds or `timeout` elapses; returns the final value.
/// Use instead of fixed sleeps: it waits on the observable outcome, not on a guessed delay.
func waitUntil(
    timeout: Duration = .seconds(2),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
