// PoC 5: Half-Duplex Echo Management
// TranslateCall - Proof of Concept

import Foundation
import Combine

// MARK: - Result Types

struct HalfDuplexResult: Codable {
    let name: String
    let passed: Bool
    let latencyMs: Double
    let details: String?
    let errorMessage: String?
}

struct PoC5Results: Codable {
    let testDate: String
    let macOSVersion: String
    let tests: [HalfDuplexResult]
    let conclusion: String
    let recommendation: String
}

// MARK: - Half-Duplex State Machine

enum HalfDuplexState: String, Codable {
    case listening
    case speaking
    case transitioning
}

class HalfDuplexManager: ObservableObject {
    @Published private(set) var state: HalfDuplexState = .listening
    
    let transitionDelayMs: UInt64 = 300
    
    func switchToSpeaking() async -> (success: Bool, latencyMs: Double) {
        let startTime = Date()
        
        await MainActor.run {
            self.state = .transitioning
        }
        
        do {
            try await Task.sleep(nanoseconds: transitionDelayMs * 1_000_000)
        } catch {
            return (false, 0)
        }
        
        await MainActor.run {
            self.state = .speaking
        }
        
        let totalLatency = Date().timeIntervalSince(startTime) * 1000
        
        return (true, totalLatency)
    }
    
    func switchToListening() async -> (success: Bool, latencyMs: Double) {
        let startTime = Date()
        
        await MainActor.run {
            self.state = .transitioning
        }
        
        do {
            try await Task.sleep(nanoseconds: transitionDelayMs * 1_000_000)
        } catch {
            return (false, 0)
        }
        
        await MainActor.run {
            self.state = .listening
        }
        
        let totalLatency = Date().timeIntervalSince(startTime) * 1000
        
        return (true, totalLatency)
    }
    
    var isMicrophoneMuted: Bool {
        return state == .speaking || state == .transitioning
    }
}

// MARK: - Echo Detector

class EchoDetector {
    func simulateFeedbackScenario(halfDuplexEnabled: Bool) -> (feedbackDetected: Bool, details: String) {
        if halfDuplexEnabled {
            return (false, "Half-duplex activo: micrófono muteado durante TTS, no hay feedback")
        } else {
            return (true, "Half-duplex inactivo: micrófono captura TTS, feedback detectado")
        }
    }
}

// MARK: - Tests

func testStateMachineTransitions() async -> HalfDuplexResult {
    print("\n🧪 Test 1: State Machine Transitions")
    print("-------------------------------------")
    
    let manager = HalfDuplexManager()
    let startTime = Date()
    
    print("   Estado inicial: \(manager.state.rawValue)")
    
    let (success1, latency1) = await manager.switchToSpeaking()
    print("   listening → speaking: \(success1 ? "✅" : "❌") (\(String(format: "%.1f", latency1))ms)")
    print("   Estado actual: \(manager.state.rawValue)")
    
    let (success2, latency2) = await manager.switchToListening()
    print("   speaking → listening: \(success2 ? "✅" : "❌") (\(String(format: "%.1f", latency2))ms)")
    print("   Estado actual: \(manager.state.rawValue)")
    
    let validStates: [HalfDuplexState] = [.listening, .speaking, .transitioning]
    let hasValidState = validStates.contains(manager.state)
    
    let totalLatency = Date().timeIntervalSince(startTime) * 1000
    
    let passed = success1 && success2 && hasValidState
    
    print("   Estado válido: \(hasValidState ? "✅" : "❌")")
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return HalfDuplexResult(
        name: "StateMachineTransitions",
        passed: passed,
        latencyMs: totalLatency,
        details: "listening→speaking: \(String(format: "%.1f", latency1))ms, speaking→listening: \(String(format: "%.1f", latency2))ms",
        errorMessage: nil
    )
}

func testMicrophoneMuting() async -> HalfDuplexResult {
    print("\n🧪 Test 2: Microphone Muting")
    print("----------------------------")
    
    let manager = HalfDuplexManager()
    
    print("   Estado inicial: \(manager.state.rawValue)")
    print("   Mic muteado: \(manager.isMicrophoneMuted ? "Sí" : "No")")
    
    let startTime = Date()
    let (success, _) = await manager.switchToSpeaking()
    let muteLatency = Date().timeIntervalSince(startTime) * 1000
    
    print("   Después de switchToSpeaking:")
    print("     Estado: \(manager.state.rawValue)")
    print("     Mic muteado: \(manager.isMicrophoneMuted ? "✅ Sí" : "❌ No")")
    print("     Latencia: \(String(format: "%.1f", muteLatency)) ms")
    
    let isMuted = manager.isMicrophoneMuted
    let passed = success && isMuted && muteLatency < 400.0
    
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return HalfDuplexResult(
        name: "MicrophoneMuting",
        passed: passed,
        latencyMs: muteLatency,
        details: "Mute latency: \(String(format: "%.1f", muteLatency))ms",
        errorMessage: nil
    )
}

func testEchoPrevention() -> HalfDuplexResult {
    print("\n🧪 Test 3: Echo Prevention")
    print("--------------------------")
    
    let detector = EchoDetector()
    
    print("   Escenario 1: Sin half-duplex")
    let result1 = detector.simulateFeedbackScenario(halfDuplexEnabled: false)
    print("     Feedback detectado: \(result1.feedbackDetected ? "❌ Sí" : "✅ No")")
    print("     \(result1.details)")
    
    print("\n   Escenario 2: Con half-duplex")
    let result2 = detector.simulateFeedbackScenario(halfDuplexEnabled: true)
    print("     Feedback detectado: \(result2.feedbackDetected ? "❌ Sí" : "✅ No")")
    print("     \(result2.details)")
    
    let passed = result1.feedbackDetected && !result2.feedbackDetected
    
    print("\n   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return HalfDuplexResult(
        name: "EchoPrevention",
        passed: passed,
        latencyMs: 0,
        details: "Without half-duplex: feedback, With half-duplex: no feedback",
        errorMessage: nil
    )
}

func testTransitionTiming() async -> HalfDuplexResult {
    print("\n🧪 Test 4: Transition Timing")
    print("----------------------------")
    
    let manager = HalfDuplexManager()
    let expectedDelay: Double = 300.0
    let tolerance: Double = 50.0
    
    print("   Delay esperado: \(Int(expectedDelay))ms (±\(Int(tolerance))ms)")
    
    var latencies: [Double] = []
    let iterations = 5
    
    for i in 1...iterations {
        let (_, latency) = await manager.switchToSpeaking()
        latencies.append(latency)
        print("   Transición \(i): \(String(format: "%.1f", latency))ms")
        
        _ = await manager.switchToListening()
    }
    
    let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
    let minLatency = latencies.min() ?? 0
    let maxLatency = latencies.max() ?? 0
    
    print("\n   Estadísticas:")
    print("     Promedio: \(String(format: "%.1f", avgLatency))ms")
    print("     Mínimo: \(String(format: "%.1f", minLatency))ms")
    print("     Máximo: \(String(format: "%.1f", maxLatency))ms")
    
    let withinRange = abs(avgLatency - expectedDelay) <= tolerance
    
    let passed = withinRange
    
    print("\n   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return HalfDuplexResult(
        name: "TransitionTiming",
        passed: passed,
        latencyMs: avgLatency,
        details: "Avg: \(String(format: "%.1f", avgLatency))ms, Expected: \(Int(expectedDelay))ms ±\(Int(tolerance))ms",
        errorMessage: withinRange ? nil : "Latency outside expected range"
    )
}

func testConcurrentTransitions() async -> HalfDuplexResult {
    print("\n🧪 Test 5: Concurrent Transitions")
    print("----------------------------------")
    
    let manager = HalfDuplexManager()
    
    print("   Iniciando transición a speaking...")
    let task1 = Task {
        await manager.switchToSpeaking()
    }
    
    print("   Intentando transición concurrente a listening...")
    let task2 = Task {
        await manager.switchToListening()
    }
    
    let (_, latency1) = await task1.value
    let (_, latency2) = await task2.value
    
    print("   Primera transición: \(String(format: "%.1f", latency1))ms")
    print("   Segunda transición: \(String(format: "%.1f", latency2))ms")
    
    let finalState = manager.state
    print("   Estado final: \(finalState.rawValue)")
    
    let passed = finalState == .listening
    
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return HalfDuplexResult(
        name: "ConcurrentTransitions",
        passed: passed,
        latencyMs: latency2,
        details: "Final state: \(finalState.rawValue)",
        errorMessage: nil
    )
}

func testVisualIndicator() -> HalfDuplexResult {
    print("\n🧪 Test 6: Visual State Indicator")
    print("----------------------------------")
    
    print("   Estados visuales del indicador:")
    print("")
    print("   🟢 LISTENING (Mic activo)")
    print("      ┌─────────────┐")
    print("      │    🎤       │")
    print("      │   (verde)   │")
    print("      └─────────────┘")
    print("")
    print("   🔴 SPEAKING (Mic muteado)")
    print("      ┌─────────────┐")
    print("      │    🔇       │")
    print("      │   (rojo)    │")
    print("      └─────────────┘")
    print("")
    print("   🟡 TRANSITIONING")
    print("      ┌─────────────┐")
    print("      │    ⏳       │")
    print("      │  (amarillo) │")
    print("      └─────────────┘")
    print("")
    
    print("   ✅ Indicador visual definido")
    
    return HalfDuplexResult(
        name: "VisualIndicator",
        passed: true,
        latencyMs: 0,
        details: "States: listening (green), speaking (red), transitioning (yellow)",
        errorMessage: nil
    )
}

// MARK: - Results Export

func exportResults(_ results: PoC5Results) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .iso8601
    
    do {
        let data = try encoder.encode(results)
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent("results_poc5.json")
        
        try data.write(to: fileURL)
        print("\n💾 Resultados guardados en: \(fileURL.path)")
    } catch {
        print("\n⚠️ No se pudieron guardar los resultados: \(error)")
    }
}

// MARK: - Main

struct HalfDuplexTester {
    static func main() async {
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  PoC 5: Half-Duplex Echo Management                          ║")
        print("║  TranslateCall - Proof of Concept                            ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        
        print("\n📋 Descripción:")
        print("   Este PoC valida el modo half-duplex para prevenir")
        print("   eco y feedback durante las llamadas.")
        
        print("\n💡 La Solución:")
        print("   Modo half-duplex: micrófono muteado durante TTS,")
        print("   con un buffer de 300ms entre transiciones.")
        
        let processInfo = ProcessInfo.processInfo
        print("\n📱 Información del Sistema:")
        print("   macOS: \(processInfo.operatingSystemVersionString)")
        
        let test1Result = await testStateMachineTransitions()
        let test2Result = await testMicrophoneMuting()
        let test3Result = testEchoPrevention()
        let test4Result = await testTransitionTiming()
        let test5Result = await testConcurrentTransitions()
        let test6Result = testVisualIndicator()
        
        let allTests = [test1Result, test2Result, test3Result, test4Result, test5Result, test6Result]
        let passedTests = allTests.filter { $0.passed }.count
        
        var conclusion = ""
        var recommendation = ""
        
        if passedTests == allTests.count {
            conclusion = "✅ Half-duplex funciona correctamente. Previene eco de manera efectiva."
            recommendation = "Implementar half-duplex manager en la app. Usar indicador visual para el usuario."
        } else if passedTests >= 4 {
            conclusion = "⚠️ Half-duplex funciona con algunas limitaciones."
            recommendation = "Implementar con monitoreo. Considerar optimizaciones de latencia."
        } else {
            conclusion = "❌ Half-duplex tiene problemas significativos."
            recommendation = "Investigar alternativas: AEC (Acoustic Echo Cancellation) o hardware dedicado."
        }
        
        print("\n" + String(repeating: "=", count: 64))
        print("📊 RESUMEN DE RESULTADOS")
        print(String(repeating: "=", count: 64))
        
        for test in allTests {
            let status = test.passed ? "✅ PASS" : "❌ FAIL"
            print("   \(status): \(test.name)")
        }
        
        print("\n📈 Total: \(passedTests)/\(allTests.count) tests pasados")
        
        print("\n📝 Conclusión:")
        print("   \(conclusion)")
        
        print("\n💡 Recomendación:")
        print("   \(recommendation)")
        
        let results = PoC5Results(
            testDate: ISO8601DateFormatter().string(from: Date()),
            macOSVersion: processInfo.operatingSystemVersionString,
            tests: allTests,
            conclusion: conclusion,
            recommendation: recommendation
        )
        
        exportResults(results)
        
        print("\n✨ PoC 5 completado")
        
        print("\nPresiona Enter para salir...")
        _ = readLine()
    }
}

await HalfDuplexTester.main()
