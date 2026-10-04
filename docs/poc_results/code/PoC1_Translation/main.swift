// PoC 1: Translation API - Validacion con contexto SwiftUI minimo
// TranslateCall - Proof of Concept

import Foundation
import Translation
import SwiftUI
import AppKit
import Combine

// MARK: - Result Types

struct TestResult: Codable {
    let name: String
    let passed: Bool
    let latencyMs: Double
    let errorMessage: String?
    let translatedText: String?
}

struct PoC1Results: Codable {
    let testDate: String
    let macOSVersion: String
    let xcodeVersion: String
    let swiftVersion: String
    let tests: [TestResult]
    let conclusion: String
}

// MARK: - Swift Version

func swiftVersion() -> String {
    #if swift(>=6.0)
    return "6.0+"
    #elseif swift(>=5.10)
    return "5.10"
    #elseif swift(>=5.9)
    return "5.9"
    #else
    return "<5.9"
    #endif
}

// MARK: - Results Export

func exportResults(_ results: PoC1Results) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted

    do {
        let data = try encoder.encode(results)
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent("results_poc1.json")
        try data.write(to: fileURL)
        print("\n💾 Resultados guardados en: \(fileURL.path)")
    } catch {
        print("\n⚠️ No se pudieron guardar los resultados: \(error)")
    }
}

// MARK: - Test Runner (uses TranslationSession from .translationTask)

class TestRunner: ObservableObject {
    @Published var finished = false
    var allResults: [TestResult] = []

    func runAllTests(session: TranslationSession) async {
        print("\n🧪 Test 1: Traduccion via .translationTask (ES → EN)")
        print("-----------------------------------------------------")
        let test1 = await testTranslationViaTask(session: session)
        allResults.append(test1)

        print("\n🧪 Test 2: Traduccion Batch via .translationTask")
        print("-------------------------------------------------")
        let test2 = await testBatchTranslation(session: session)
        allResults.append(test2)

        print("\n🧪 Test 3: Latencia de traduccion (5 iteraciones)")
        print("--------------------------------------------------")
        let test3 = await testTranslationLatency(session: session)
        allResults.append(test3)

        print("\n🧪 Test 4: Language Availability Check")
        print("--------------------------------------")
        let test4 = await testLanguageAvailability()
        allResults.append(test4)

        let passedTests = allResults.filter { $0.passed }.count

        var conclusion = ""
        if test1.passed && test2.passed {
            conclusion = "✅ Translation API funciona con .translationTask() en contexto minimo SwiftUI. Arquitectura valida para TranslateCall."
        } else if test4.passed && !test1.passed {
            conclusion = "⚠️ Translation API disponible pero la sesion no pudo traducir. Verificar idiomas descargados."
        } else {
            conclusion = "❌ Translation API no disponible. Verificar configuracion del sistema."
        }

        print("\n" + String(repeating: "=", count: 64))
        print("📊 RESUMEN DE RESULTADOS")
        print(String(repeating: "=", count: 64))

        for test in allResults {
            let status = test.passed ? "✅ PASS" : "❌ FAIL"
            print("   \(status): \(test.name)")
        }

        print("\n📈 Total: \(passedTests)/\(allResults.count) tests pasados")
        print("\n📝 Conclusion:")
        print("   \(conclusion)")

        let processInfo = ProcessInfo.processInfo
        let results = PoC1Results(
            testDate: ISO8601DateFormatter().string(from: Date()),
            macOSVersion: processInfo.operatingSystemVersionString,
            xcodeVersion: "Unknown",
            swiftVersion: swiftVersion(),
            tests: allResults,
            conclusion: conclusion
        )

        exportResults(results)
        print("\n✨ PoC 1 completado")

        await MainActor.run {
            self.finished = true
        }

        // Salir de la app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // Test 1: Traduccion simple
    func testTranslationViaTask(session: TranslationSession) async -> TestResult {
        let startTime = Date()
        let text = "Hola, ¿como estas?"

        do {
            let response = try await session.translate(text)
            let latency = Date().timeIntervalSince(startTime) * 1000

            print("   Original:  \"\(text)\"")
            print("   Traducido: \"\(response.targetText)\"")
            print("   Latencia:  \(String(format: "%.0f", latency)) ms")
            print("   ✅ Traduccion exitosa")

            return TestResult(
                name: "TranslationViaTask",
                passed: true,
                latencyMs: latency,
                errorMessage: nil,
                translatedText: response.targetText
            )
        } catch {
            let latency = Date().timeIntervalSince(startTime) * 1000
            print("   ❌ Error: \(error)")

            return TestResult(
                name: "TranslationViaTask",
                passed: false,
                latencyMs: latency,
                errorMessage: "\(error)",
                translatedText: nil
            )
        }
    }

    // Test 2: Traduccion batch
    func testBatchTranslation(session: TranslationSession) async -> TestResult {
        let startTime = Date()

        let texts = [
            "Buenos dias",
            "Gracias por tu ayuda",
            "¿Donde esta la biblioteca?",
            "Me gustan los gatos",
        ]

        let requests = texts.enumerated().map { (index, text) in
            TranslationSession.Request(sourceText: text, clientIdentifier: "\(index)")
        }

        do {
            var translations: [String] = Array(repeating: "", count: texts.count)
            for try await response in session.translate(batch: requests) {
                guard let idStr = response.clientIdentifier, let idx = Int(idStr) else { continue }
                translations[idx] = response.targetText
            }

            let latency = Date().timeIntervalSince(startTime) * 1000
            let allTranslated = translations.allSatisfy { !$0.isEmpty }

            for (i, text) in texts.enumerated() {
                print("   \(text) → \(translations[i])")
            }
            print("   Latencia total: \(String(format: "%.0f", latency)) ms")
            print("   \(allTranslated ? "✅" : "❌") Batch \(allTranslated ? "completo" : "incompleto")")

            return TestResult(
                name: "BatchTranslation",
                passed: allTranslated,
                latencyMs: latency,
                errorMessage: nil,
                translatedText: translations.joined(separator: "; ")
            )
        } catch {
            let latency = Date().timeIntervalSince(startTime) * 1000
            print("   ❌ Error: \(error)")

            return TestResult(
                name: "BatchTranslation",
                passed: false,
                latencyMs: latency,
                errorMessage: "\(error)",
                translatedText: nil
            )
        }
    }

    // Test 3: Latencia
    func testTranslationLatency(session: TranslationSession) async -> TestResult {
        var latencies: [Double] = []
        let testText = "Hola mundo"
        let iterations = 5

        for i in 1...iterations {
            let start = Date()
            do {
                let response = try await session.translate(testText)
                let latency = Date().timeIntervalSince(start) * 1000
                latencies.append(latency)
                print("   Iteracion \(i): \(String(format: "%.1f", latency))ms → \"\(response.targetText)\"")
            } catch {
                print("   Iteracion \(i): ❌ Error: \(error)")
            }
        }

        guard !latencies.isEmpty else {
            return TestResult(
                name: "TranslationLatency",
                passed: false,
                latencyMs: 0,
                errorMessage: "Ninguna traduccion exitosa",
                translatedText: nil
            )
        }

        let avg = latencies.reduce(0, +) / Double(latencies.count)
        let minL = latencies.min() ?? 0
        let maxL = latencies.max() ?? 0

        print("\n   Estadisticas:")
        print("     Promedio: \(String(format: "%.1f", avg))ms")
        print("     Minimo:   \(String(format: "%.1f", minL))ms")
        print("     Maximo:   \(String(format: "%.1f", maxL))ms")

        let passed = avg < 500
        print("   \(passed ? "✅" : "⚠️") Latencia promedio \(passed ? "aceptable" : "alta") (<500ms)")

        return TestResult(
            name: "TranslationLatency",
            passed: passed,
            latencyMs: avg,
            errorMessage: nil,
            translatedText: "avg=\(String(format: "%.1f", avg))ms, min=\(String(format: "%.1f", minL))ms, max=\(String(format: "%.1f", maxL))ms"
        )
    }

    // Test 4: Disponibilidad de idiomas
    func testLanguageAvailability() async -> TestResult {
        let startTime = Date()
        let availability = LanguageAvailability()

        let testPairs: [(String, String)] = [
            ("es", "en"), ("en", "es"), ("fr", "en"), ("de", "en"),
            ("ja", "en"), ("zh", "en"), ("pt", "en"), ("it", "en"),
            ("ko", "en"), ("ru", "en")
        ]

        var installedCount = 0
        var supportedCount = 0

        for (src, tgt) in testPairs {
            let status = await availability.status(
                from: Locale.Language(identifier: src),
                to: Locale.Language(identifier: tgt)
            )
            switch status {
            case .installed:
                installedCount += 1
                supportedCount += 1
                print("   \(src) → \(tgt): ✅ instalado")
            case .supported:
                supportedCount += 1
                print("   \(src) → \(tgt): 🔶 disponible")
            case .unsupported:
                print("   \(src) → \(tgt): ❌ no soportado")
            @unknown default:
                print("   \(src) → \(tgt): ❓ desconocido")
            }
        }

        let latency = Date().timeIntervalSince(startTime) * 1000

        print("\n   📊 Resumen: \(installedCount) instalados, \(supportedCount) soportados de \(testPairs.count) pares")

        let passed = supportedCount > 0

        return TestResult(
            name: "LanguageAvailability",
            passed: passed,
            latencyMs: latency,
            errorMessage: nil,
            translatedText: "Instalados: \(installedCount)/\(testPairs.count), Soportados: \(supportedCount)/\(testPairs.count)"
        )
    }
}

// MARK: - SwiftUI View (ventana oculta que ejecuta los tests)

struct TranslationTestView: View {
    @StateObject var runner = TestRunner()
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        VStack {
            if runner.finished {
                Text("Tests completados")
            } else {
                Text("Ejecutando tests de traduccion...")
            }
        }
        .frame(width: 400, height: 100)
        .translationTask(configuration) { session in
            await runner.runAllTests(session: session)
        }
        .onAppear {
            // Configurar la sesion ES → EN
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "es"),
                target: Locale.Language(identifier: "en")
            )
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Forzar flush de stdout
        setbuf(stdout, nil)
        fputs("App launched\n", stderr)
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  PoC 1: Translation API con contexto SwiftUI minimo        ║")
        print("║  TranslateCall - Proof of Concept                          ║")
        print("╚══════════════════════════════════════════════════════════════╝")

        let processInfo = ProcessInfo.processInfo
        print("\n📱 Informacion del Sistema:")
        print("   macOS: \(processInfo.operatingSystemVersionString)")
        print("   Swift: \(swiftVersion())")
        print("\n💡 Usando .translationTask() con ventana SwiftUI oculta")
        print("   para acceder a los modelos de traduccion del sistema.\n")

        let contentView = TranslationTestView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: contentView)
        window.title = "PoC1 - Translation Test"
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.finishLaunching()
app.run()
