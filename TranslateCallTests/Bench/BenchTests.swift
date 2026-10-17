import Testing

/// Root of the bench tier (M9 REQ-BH-26). Every bench suite is declared as
/// `extension BenchTests { @Suite(...) struct X { ... } }` so the Bench test plan selects it with one
/// identifier and the unit/integration tiers never run it.
@Suite("Bench", .tags(.bench), .serialized,
       .enabled(if: TestTier.current == .bench, "Bench tier only — run `just bench`"))
struct BenchTests {}
