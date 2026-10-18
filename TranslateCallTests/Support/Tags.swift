import Testing

extension Tag {
    /// Tests that use real Apple frameworks, real models and audio fixtures (F8.5.0 REQ-W-20).
    @Tag static var integration: Self
    /// Benchmark harness tests: real pipeline, real time, minutes per run (M9). Bench tier only.
    @Tag static var bench: Self
}
