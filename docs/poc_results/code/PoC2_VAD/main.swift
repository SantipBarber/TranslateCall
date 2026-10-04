// PoC 2: Voice Activity Detection
// TranslateCall - Proof of Concept

import Foundation
import AVFoundation
import Accelerate

// MARK: - Result Types

struct VADTestResult: Codable {
    let name: String
    let passed: Bool
    let latencyMs: Double
    let accuracy: Double
    let errorMessage: String?
    let details: String?
}

struct PoC2Results: Codable {
    let testDate: String
    let macOSVersion: String
    let tests: [VADTestResult]
    let conclusion: String
}

// MARK: - Simple Energy-Based VAD

class SimpleEnergyVAD {
    var energyThreshold: Float = -50.0 // dB
    var silenceDuration: TimeInterval = 0.5
    var minSpeechDuration: TimeInterval = 0.2
    
    func calculateEnergy(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else {
            return -100.0
        }
        
        let frameLength = vDSP_Length(buffer.frameLength)
        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, frameLength)
        
        return 20 * log10(rms + 1e-10)
    }
    
    func isSpeech(_ buffer: AVAudioPCMBuffer) -> Bool {
        return calculateEnergy(buffer) > energyThreshold
    }
}

// MARK: - Audio Test Generator

class AudioTestGenerator {
    let sampleRate: Double = 16000
    
    func generateSilence(duration: Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!,
            frameCapacity: frameCount
        ) else { return nil }
        
        memset(buffer.floatChannelData![0], 0, Int(frameCount) * MemoryLayout<Float>.size)
        buffer.frameLength = frameCount
        
        return buffer
    }
    
    func generateTone(frequency: Double, duration: Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!,
            frameCapacity: frameCount
        ) else { return nil }
        
        let data = buffer.floatChannelData![0]
        
        for i in 0..<Int(frameCount) {
            let time = Double(i) / sampleRate
            let envelope = exp(-time * 2) * (1 - exp(-time * 10))
            data[i] = Float(sin(2.0 * .pi * frequency * time) * envelope * 0.5)
        }
        
        buffer.frameLength = frameCount
        return buffer
    }
    
    func generateMixedSequence() -> AVAudioPCMBuffer? {
        let silence1 = generateSilence(duration: 1.0)
        let speech = generateTone(frequency: 200, duration: 2.0)
        let silence2 = generateSilence(duration: 1.0)
        
        guard let s1 = silence1, let sp = speech, let s2 = silence2 else {
            return nil
        }
        
        let totalFrames = s1.frameLength + sp.frameLength + s2.frameLength
        guard let combined = AVAudioPCMBuffer(
            pcmFormat: s1.format,
            frameCapacity: totalFrames
        ) else { return nil }
        
        let data = combined.floatChannelData![0]
        var offset = 0
        
        memcpy(data + offset, s1.floatChannelData![0], Int(s1.frameLength) * MemoryLayout<Float>.size)
        offset += Int(s1.frameLength)
        
        memcpy(data + offset, sp.floatChannelData![0], Int(sp.frameLength) * MemoryLayout<Float>.size)
        offset += Int(sp.frameLength)
        
        memcpy(data + offset, s2.floatChannelData![0], Int(s2.frameLength) * MemoryLayout<Float>.size)
        
        combined.frameLength = totalFrames
        return combined
    }
}

// MARK: - Tests

func testBasicEnergyDetection() -> VADTestResult {
    print("\n🧪 Test 1: Basic Energy Detection")
    print("----------------------------------")
    
    let startTime = Date()
    let generator = AudioTestGenerator()
    let vad = SimpleEnergyVAD()
    
    guard let speechBuffer = generator.generateTone(frequency: 200, duration: 2.0),
          let silenceBuffer = generator.generateSilence(duration: 2.0) else {
        return VADTestResult(
            name: "BasicEnergyDetection",
            passed: false,
            latencyMs: 0,
            accuracy: 0,
            errorMessage: "Failed to generate test audio",
            details: nil
        )
    }
    
    let speechEnergy = vad.calculateEnergy(speechBuffer)
    let silenceEnergy = vad.calculateEnergy(silenceBuffer)
    
    let endTime = Date()
    let latency = endTime.timeIntervalSince(startTime) * 1000
    
    print("   Energía de voz: \(String(format: "%.1f", speechEnergy)) dB")
    print("   Energía de silencio: \(String(format: "%.1f", silenceEnergy)) dB")
    print("   Diferencia: \(String(format: "%.1f", speechEnergy - silenceEnergy)) dB")
    
    let passed = speechEnergy > silenceEnergy + 10.0
    let details = "Speech: \(String(format: "%.1f", speechEnergy)) dB, Silence: \(String(format: "%.1f", silenceEnergy)) dB"
    
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return VADTestResult(
        name: "BasicEnergyDetection",
        passed: passed,
        latencyMs: latency,
        accuracy: passed ? 100.0 : 0.0,
        errorMessage: nil,
        details: details
    )
}

func testMixedSequenceDetection() -> VADTestResult {
    print("\n🧪 Test 2: Mixed Sequence Detection")
    print("------------------------------------")
    
    let startTime = Date()
    let generator = AudioTestGenerator()
    let vad = SimpleEnergyVAD()
    
    guard let mixedBuffer = generator.generateMixedSequence() else {
        return VADTestResult(
            name: "MixedSequenceDetection",
            passed: false,
            latencyMs: 0,
            accuracy: 0,
            errorMessage: "Failed to generate mixed sequence",
            details: nil
        )
    }
    
    print("   Secuencia generada: 1s silencio + 2s voz + 1s silencio")
    
    let chunkSize = AVAudioFrameCount(0.1 * 16000)
    let totalChunks = Int(mixedBuffer.frameLength) / Int(chunkSize)
    
    var speechDetected = false
    var detectionTime: Double = 0
    
    for i in 0..<totalChunks {
        let offset = i * Int(chunkSize)
        
        guard let chunkBuffer = AVAudioPCMBuffer(
            pcmFormat: mixedBuffer.format,
            frameCapacity: chunkSize
        ) else { continue }
        
        memcpy(chunkBuffer.floatChannelData![0],
               mixedBuffer.floatChannelData![0] + offset,
               Int(chunkSize) * MemoryLayout<Float>.size)
        chunkBuffer.frameLength = chunkSize
        
        let energy = vad.calculateEnergy(chunkBuffer)
        let time = Double(i) * 0.1
        
        if energy > vad.energyThreshold && !speechDetected {
            speechDetected = true
            detectionTime = time
            print("   🎤 Voz detectada en t=\(String(format: "%.1f", time))s")
        }
    }
    
    let endTime = Date()
    let latency = endTime.timeIntervalSince(startTime) * 1000
    
    let expectedTime = 1.0
    let timeError = abs(detectionTime - expectedTime)
    let passed = speechDetected && timeError < 0.3
    
    print("\n   Error de detección: \(String(format: "%.2f", timeError))s")
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return VADTestResult(
        name: "MixedSequenceDetection",
        passed: passed,
        latencyMs: latency,
        accuracy: max(0, 100 - timeError * 100),
        errorMessage: nil,
        details: "Detected at \(String(format: "%.2f", detectionTime))s, expected \(expectedTime)s"
    )
}

func testDetectionLatency() -> VADTestResult {
    print("\n🧪 Test 3: Detection Latency")
    print("-----------------------------")
    
    let generator = AudioTestGenerator()
    let vad = SimpleEnergyVAD()
    
    guard let speechBuffer = generator.generateTone(frequency: 200, duration: 1.0) else {
        return VADTestResult(
            name: "DetectionLatency",
            passed: false,
            latencyMs: 0,
            accuracy: 0,
            errorMessage: "Failed to generate test audio",
            details: nil
        )
    }
    
    var latencies: [Double] = []
    let iterations = 100
    
    for _ in 0..<iterations {
        let startTime = Date()
        _ = vad.calculateEnergy(speechBuffer)
        let endTime = Date()
        latencies.append(endTime.timeIntervalSince(startTime) * 1000)
    }
    
    let avgLatency = latencies.reduce(0, +) / Double(latencies.count)
    let minLatency = latencies.min() ?? 0
    let maxLatency = latencies.max() ?? 0
    
    print("   Iteraciones: \(iterations)")
    print("   Latencia promedio: \(String(format: "%.3f", avgLatency)) ms")
    print("   Latencia mínima: \(String(format: "%.3f", minLatency)) ms")
    print("   Latencia máxima: \(String(format: "%.3f", maxLatency)) ms")
    
    let passed = avgLatency < 1.0
    
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return VADTestResult(
        name: "DetectionLatency",
        passed: passed,
        latencyMs: avgLatency,
        accuracy: 100.0,
        errorMessage: nil,
        details: "Avg: \(String(format: "%.3f", avgLatency))ms, Min: \(String(format: "%.3f", minLatency))ms, Max: \(String(format: "%.3f", maxLatency))ms"
    )
}

func testFrequencyVariation() -> VADTestResult {
    print("\n🧪 Test 4: Frequency Variation")
    print("-------------------------------")
    
    let startTime = Date()
    let generator = AudioTestGenerator()
    let vad = SimpleEnergyVAD()
    
    let frequencies = [100.0, 150.0, 200.0, 250.0, 300.0]
    var results: [String] = []
    var allDetected = true
    
    for freq in frequencies {
        guard let buffer = generator.generateTone(frequency: freq, duration: 0.5) else {
            continue
        }
        
        let energy = vad.calculateEnergy(buffer)
        let detected = energy > vad.energyThreshold
        
        results.append("\(Int(freq))Hz: \(detected ? "✓" : "✗")")
        
        if !detected {
            allDetected = false
        }
    }
    
    let endTime = Date()
    let latency = endTime.timeIntervalSince(startTime) * 1000
    
    print("   Frecuencias probadas:")
    for result in results {
        print("     \(result)")
    }
    
    let passed = allDetected
    print("   \(passed ? "✅" : "❌") Test \(passed ? "pasado" : "fallado")")
    
    return VADTestResult(
        name: "FrequencyVariation",
        passed: passed,
        latencyMs: latency,
        accuracy: passed ? 100.0 : Double(frequencies.filter { $0 > 0 }.count) / Double(frequencies.count) * 100,
        errorMessage: nil,
        details: results.joined(separator: "; ")
    )
}

// MARK: - Results Export

func exportResults(_ results: PoC2Results) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .iso8601
    
    do {
        let data = try encoder.encode(results)
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent("results_poc2.json")
        
        try data.write(to: fileURL)
        print("\n💾 Resultados guardados en: \(fileURL.path)")
    } catch {
        print("\n⚠️ No se pudieron guardar los resultados: \(error)")
    }
}

// MARK: - Main

struct VADTester {
    static func main() async {
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  PoC 2: Voice Activity Detection                             ║")
        print("║  TranslateCall - Proof of Concept                            ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        
        let processInfo = ProcessInfo.processInfo
        print("\n📱 Información del Sistema:")
        print("   macOS: \(processInfo.operatingSystemVersionString)")
        
        let test1Result = testBasicEnergyDetection()
        let test2Result = testMixedSequenceDetection()
        let test3Result = testDetectionLatency()
        let test4Result = testFrequencyVariation()
        
        let allTests = [test1Result, test2Result, test3Result, test4Result]
        let passedTests = allTests.filter { $0.passed }.count
        
        var conclusion = ""
        if passedTests == allTests.count {
            conclusion = "✅ VAD funciona correctamente. Listo para integrar."
        } else if passedTests >= 2 {
            conclusion = "⚠️ VAD funciona parcialmente. Ajustar thresholds."
        } else {
            conclusion = "❌ VAD tiene problemas. Revisar implementación."
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
        
        let results = PoC2Results(
            testDate: ISO8601DateFormatter().string(from: Date()),
            macOSVersion: processInfo.operatingSystemVersionString,
            tests: allTests,
            conclusion: conclusion
        )
        
        exportResults(results)
        
        print("\n✨ PoC 2 completado")
        
        print("\nPresiona Enter para salir...")
        _ = readLine()
    }
}

await VADTester.main()
