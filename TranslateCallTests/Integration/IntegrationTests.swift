import Testing

/// Root of the integration tier. Every integration suite is declared as
/// `extension IntegrationTests { @Suite(...) struct X { ... } }` so the
/// Integration test plan can select it with a single identifier.
@Suite("Integration", .tags(.integration), .serialized,
       .enabled(if: TestTier.current == .integration, "Integration tier only — run `just test-integration`"))
struct IntegrationTests {
    /// Placeholder so the tier is non-empty until real suites land (F8.5.0 Task 7).
    @Test func tierIsIntegration() {
        #expect(TestTier.current == .integration)
    }
}
