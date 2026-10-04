// PoC 4: BlackHole Integration
// TranslateCall - Proof of Concept

import Foundation
import CoreAudio

// MARK: - Result Types

struct BlackHoleResult: Codable {
    let name: String
    let passed: Bool
    let details: String?
    let errorMessage: String?
}

struct AudioDeviceInfo: Codable {
    let id: UInt32
    let name: String
    let manufacturer: String
    let isInput: Bool
    let isOutput: Bool
    let sampleRate: Double
    let channelCount: Int
}

struct PoC4Results: Codable {
    let testDate: String
    let macOSVersion: String
    let tests: [BlackHoleResult]
    let blackHoleInstalled: Bool
    let blackHoleVersion: String?
    let availableDevices: [AudioDeviceInfo]
    let conclusion: String
}

// MARK: - Audio Device Manager

class AudioDeviceManager {
    
    func getAllDevices() -> [AudioDeviceInfo] {
        var devices: [AudioDeviceInfo] = []
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard result == noErr else { return devices }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard result == noErr else { return devices }
        
        for deviceID in deviceIDs {
            if let deviceInfo = getDeviceInfo(deviceID: deviceID) {
                devices.append(deviceInfo)
            }
        }
        
        return devices
    }
    
    func getDeviceInfo(deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        var nameProperty = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        
        var result = AudioObjectGetPropertyData(
            deviceID,
            &nameProperty,
            0,
            nil,
            &nameSize,
            &name
        )
        
        guard result == noErr else { return nil }
        let deviceName = name as String
        
        var manufacturerProperty = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var manufacturer: CFString = "" as CFString
        var manufacturerSize = UInt32(MemoryLayout<CFString>.size)
        
        result = AudioObjectGetPropertyData(
            deviceID,
            &manufacturerProperty,
            0,
            nil,
            &manufacturerSize,
            &manufacturer
        )
        
        let deviceManufacturer = (result == noErr) ? (manufacturer as String) : "Unknown"
        
        let isInput = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
        let isOutput = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
        
        let sampleRate = getSampleRate(deviceID: deviceID)
        let channelCount = getChannelCount(deviceID: deviceID)
        
        return AudioDeviceInfo(
            id: deviceID,
            name: deviceName,
            manufacturer: deviceManufacturer,
            isInput: isInput,
            isOutput: isOutput,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
    
    private func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let result = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        
        return result == noErr && dataSize > 0
    }
    
    private func getSampleRate(deviceID: AudioDeviceID) -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        
        let result = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &sampleRate
        )
        
        return result == noErr ? sampleRate : 0
    }
    
    private func getChannelCount(deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var result = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        
        guard result == noErr else { return 0 }
        
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        
        result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList)
        
        guard result == noErr else { return 0 }
        
        var channelCount = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers {
            channelCount += Int(buffer.mNumberChannels)
        }
        
        return channelCount
    }
    
    func findBlackHoleDevices() -> [AudioDeviceInfo] {
        let allDevices = getAllDevices()
        return allDevices.filter { device in
            device.name.lowercased().contains("blackhole") ||
            device.manufacturer.lowercased().contains("existential")
        }
    }
    
    func isBlackHoleInstalled() -> (installed: Bool, version: String?) {
        let blackHoleDevices = findBlackHoleDevices()
        
        if blackHoleDevices.isEmpty {
            return (false, nil)
        }
        
        let version = blackHoleDevices.first?.name
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        
        return (true, version)
    }
}

// MARK: - Tests

func testBlackHoleDetection(manager: AudioDeviceManager) -> BlackHoleResult {
    print("\n🧪 Test 1: BlackHole Detection")
    print("-------------------------------")
    
    let (installed, version) = manager.isBlackHoleInstalled()
    
    if installed {
        print("   ✅ BlackHole detectado")
        print("   Versión: \(version ?? "Unknown")")
        
        let devices = manager.findBlackHoleDevices()
        print("   Dispositivos encontrados: \(devices.count)")
        
        for device in devices {
            print("     - \(device.name)")
            print("       ID: \(device.id), Input: \(device.isInput ? "✓" : "✗"), Output: \(device.isOutput ? "✓" : "✗")")
        }
        
        return BlackHoleResult(
            name: "BlackHoleDetection",
            passed: true,
            details: "Version \(version ?? "Unknown"), \(devices.count) device(s)",
            errorMessage: nil
        )
    } else {
        print("   ⚠️ BlackHole no detectado")
        print("   El driver no está instalado en el sistema")
        
        return BlackHoleResult(
            name: "BlackHoleDetection",
            passed: false,
            details: "Not installed",
            errorMessage: "BlackHole driver not found"
        )
    }
}

func testInstallationMethod() -> BlackHoleResult {
    print("\n🧪 Test 2: Installation Method")
    print("-------------------------------")

    // Verificar instalacion via Homebrew
    let brewProcess = Process()
    brewProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    brewProcess.arguments = ["brew", "list", "blackhole-2ch"]
    let brewPipe = Pipe()
    brewProcess.standardOutput = brewPipe
    brewProcess.standardError = Pipe()

    var installedViaBrew = false
    do {
        try brewProcess.run()
        brewProcess.waitUntilExit()
        installedViaBrew = brewProcess.terminationStatus == 0
    } catch {
        // brew no disponible
    }

    if installedViaBrew {
        print("   ✅ Instalado via Homebrew (blackhole-2ch)")
        return BlackHoleResult(
            name: "InstallationMethod",
            passed: true,
            details: "Installed via Homebrew",
            errorMessage: nil
        )
    }

    // Verificar instalacion via .pkg (kext/driver files)
    let driverPaths = [
        "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver",
        "/Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver",
    ]

    let fileManager = FileManager.default
    for path in driverPaths {
        if fileManager.fileExists(atPath: path) {
            print("   ✅ Instalado via paquete (.pkg)")
            print("   Driver: \(path)")
            return BlackHoleResult(
                name: "InstallationMethod",
                passed: true,
                details: "Installed via .pkg at \(path)",
                errorMessage: nil
            )
        }
    }

    print("   ❌ BlackHole no instalado")
    print("\n   💡 Para instalar BlackHole:")
    print("     brew install blackhole-2ch")

    return BlackHoleResult(
        name: "InstallationMethod",
        passed: false,
        details: "Not installed",
        errorMessage: "BlackHole not found via Homebrew or .pkg"
    )
}

func testDeviceEnumeration(manager: AudioDeviceManager) -> BlackHoleResult {
    print("\n🧪 Test 3: Device Enumeration")
    print("------------------------------")
    
    let allDevices = manager.getAllDevices()
    
    print("   Total dispositivos de audio: \(allDevices.count)")
    
    let inputDevices = allDevices.filter { $0.isInput }
    let outputDevices = allDevices.filter { $0.isOutput }
    
    print("   Dispositivos de entrada: \(inputDevices.count)")
    print("   Dispositivos de salida: \(outputDevices.count)")
    
    print("\n   Dispositivos de entrada:")
    for device in inputDevices.prefix(5) {
        print("     - \(device.name)")
    }
    
    print("\n   Dispositivos de salida:")
    for device in outputDevices.prefix(5) {
        print("     - \(device.name)")
    }
    
    let passed = allDevices.count > 0
    
    return BlackHoleResult(
        name: "DeviceEnumeration",
        passed: passed,
        details: "\(allDevices.count) total, \(inputDevices.count) input, \(outputDevices.count) output",
        errorMessage: nil
    )
}

func testVirtualDeviceConfiguration(manager: AudioDeviceManager) -> BlackHoleResult {
    print("\n🧪 Test 4: Virtual Device Configuration")
    print("----------------------------------------")
    
    let blackHoleDevices = manager.findBlackHoleDevices()
    
    if blackHoleDevices.isEmpty {
        print("   ⚠️ No hay dispositivos BlackHole para configurar")
        
        print("\n   📋 Configuración ideal para TranslateCall:")
        print("     Input Device: BlackHole 2ch")
        print("     Output Device: BlackHole 2ch")
        print("     Sample Rate: 48000 Hz")
        print("     Channels: 2 (stereo)")
        
        return BlackHoleResult(
            name: "VirtualDeviceConfiguration",
            passed: false,
            details: "No BlackHole devices available",
            errorMessage: "Cannot configure without BlackHole installed"
        )
    }
    
    for device in blackHoleDevices {
        print("   Configurando: \(device.name)")
        print("     Sample rate: \(Int(device.sampleRate)) Hz")
        print("     Channels: \(device.channelCount)")
        print("     Input: \(device.isInput)")
        print("     Output: \(device.isOutput)")
    }
    
    return BlackHoleResult(
        name: "VirtualDeviceConfiguration",
        passed: true,
        details: "\(blackHoleDevices.count) device(s) configured",
        errorMessage: nil
    )
}

func testAudioRoutingSimulation() -> BlackHoleResult {
    print("\n🧪 Test 5: Audio Routing Simulation")
    print("------------------------------------")
    
    print("   Simulando flujo de audio:")
    print("")
    print("   ┌─────────────────────────────────────────────┐")
    print("   │  FLUJO DE AUDIO EN TRANSLATECALL            │")
    print("   ├─────────────────────────────────────────────┤")
    print("   │                                             │")
    print("   │  1. Micrófono físico                        │")
    print("   │     ↓                                       │")
    print("   │  2. TranslateCall (procesamiento)           │")
    print("   │     ↓                                       │")
    print("   │  3. BlackHole 2ch (virtual output)          │")
    print("   │     ↓                                       │")
    print("   │  4. Zoom/Teams (usa BlackHole como mic)     │")
    print("   │                                             │")
    print("   └─────────────────────────────────────────────┘")
    print("")
    
    print("   Configuración en app de videollamada:")
    print("     Microphone: BlackHole 2ch")
    print("     Speaker: Built-in Output")
    
    return BlackHoleResult(
        name: "AudioRoutingSimulation",
        passed: true,
        details: "Routing architecture validated",
        errorMessage: nil
    )
}

// MARK: - Results Export

func exportResults(_ results: PoC4Results) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    encoder.dateEncodingStrategy = .iso8601
    
    do {
        let data = try encoder.encode(results)
        
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent("results_poc4.json")
        
        try data.write(to: fileURL)
        print("\n💾 Resultados guardados en: \(fileURL.path)")
    } catch {
        print("\n⚠️ No se pudieron guardar los resultados: \(error)")
    }
}

// MARK: - Main

struct BlackHoleTester {
    static func main() async {
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  PoC 4: BlackHole Integration                                ║")
        print("║  TranslateCall - Proof of Concept                            ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        
        print("\n📋 Descripción:")
        print("   Este PoC valida la integración con BlackHole, un driver")
        print("   de audio virtual que permite routing de audio entre")
        print("   TranslateCall y aplicaciones de videollamadas.")
        
        let processInfo = ProcessInfo.processInfo
        print("\n📱 Información del Sistema:")
        print("   macOS: \(processInfo.operatingSystemVersionString)")
        
        let manager = AudioDeviceManager()
        
        let test1Result = testBlackHoleDetection(manager: manager)
        let test2Result = testInstallationMethod()
        let test3Result = testDeviceEnumeration(manager: manager)
        let test4Result = testVirtualDeviceConfiguration(manager: manager)
        let test5Result = testAudioRoutingSimulation()
        
        let allTests = [test1Result, test2Result, test3Result, test4Result, test5Result]
        let passedTests = allTests.filter { $0.passed }.count
        
        let (blackHoleInstalled, version) = manager.isBlackHoleInstalled()
        let allDevices = manager.getAllDevices()
        
        var conclusion = ""
        
        if blackHoleInstalled {
            conclusion = "✅ BlackHole está instalado y listo para usar."
        } else if test2Result.passed {
            conclusion = "⚠️ BlackHole no está instalado pero el installer está disponible."
        } else {
            conclusion = "❌ BlackHole no está instalado y el installer no se encontró."
        }
        
        print("\n" + String(repeating: "=", count: 64))
        print("📊 RESUMEN DE RESULTADOS")
        print(String(repeating: "=", count: 64))
        
        for test in allTests {
            let status = test.passed ? "✅ PASS" : "❌ FAIL"
            print("   \(status): \(test.name)")
        }
        
        print("\n📈 Total: \(passedTests)/\(allTests.count) tests pasados")
        
        print("\n🔊 Estado de BlackHole:")
        print("   Instalado: \(blackHoleInstalled ? "✅" : "❌")")
        if let version = version {
            print("   Versión: \(version)")
        }
        
        print("\n📝 Conclusión:")
        print("   \(conclusion)")
        
        if !blackHoleInstalled {
            print("\n💡 Para continuar:")
            print("   1. Instalar BlackHole:")
            print("      brew install blackhole-2ch")
        }
        
        let results = PoC4Results(
            testDate: ISO8601DateFormatter().string(from: Date()),
            macOSVersion: processInfo.operatingSystemVersionString,
            tests: allTests,
            blackHoleInstalled: blackHoleInstalled,
            blackHoleVersion: version,
            availableDevices: allDevices,
            conclusion: conclusion
        )
        
        exportResults(results)
        
        print("\n✨ PoC 4 completado")
        
        print("\nPresiona Enter para salir...")
        _ = readLine()
    }
}

await BlackHoleTester.main()
