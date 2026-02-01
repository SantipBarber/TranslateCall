# TranslateCall - Development Setup Guide

## ðŸš€ Quick Start

This guide will help you set up TranslateCall for development on your Mac.

**Estimated Setup Time**: 30 minutes

---

## âœ… Prerequisites

### System Requirements

```yaml
Operating System: macOS 14.0 (Sonoma) or later
Processor: Apple Silicon (M1/M2/M3) or Intel Core i5+
RAM: 8GB minimum, 16GB recommended
Disk Space: 10GB free (for Xcode, tools, and dependencies)
```

### Required Software

#### 1. **Xcode 15.0+**
```bash
# Install from App Store
open "macappstore://apps.apple.com/app/xcode/id497799835"

# Or download from Apple Developer
open "https://developer.apple.com/xcode/"

# Verify installation
xcodebuild -version
# Expected output: Xcode 15.0 or later
```

#### 2. **Command Line Tools**
```bash
xcode-select --install

# Verify
xcode-select -p
# Expected output: /Applications/Xcode.app/Contents/Developer
```

#### 3. **Git**
```bash
# Should be installed with Command Line Tools
git --version
# Expected output: git version 2.x.x

# Configure Git (if not already done)
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

#### 4. **HomeBrew** (optional but recommended)
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Verify
brew --version
```

---

## ðŸ“¥ Getting the Code

### Clone Repository

```bash
# Clone the repository
git clone https://github.com/[username]/TranslateCall.git
cd TranslateCall

# Or if using SSH
git clone git@github.com:[username]/TranslateCall.git
cd TranslateCall
```

### Project Structure

```
TranslateCall/
â”œâ”€â”€ README.md
â”œâ”€â”€ LICENSE
â”œâ”€â”€ .gitignore
â”œâ”€â”€ .github/
â”‚   â””â”€â”€ workflows/
â”‚       â””â”€â”€ build.yml
â”œâ”€â”€ docs/                          # Documentation
â”‚   â”œâ”€â”€ ARCHITECTURE.md
â”‚   â”œâ”€â”€ ROADMAP.md
â”‚   â”œâ”€â”€ TECH_STACK.md
â”‚   â”œâ”€â”€ PRIVACY_SECURITY.md
â”‚   â”œâ”€â”€ VOICE_CLONING.md
â”‚   â””â”€â”€ DEVELOPMENT_SETUP.md (this file)
â”œâ”€â”€ TranslateCall.xcodeproj        # Xcode project
â”œâ”€â”€ TranslateCall/                 # Source code
â”‚   â”œâ”€â”€ App/
â”‚   â”œâ”€â”€ Core/
â”‚   â”œâ”€â”€ Models/
â”‚   â”œâ”€â”€ Views/
â”‚   â”œâ”€â”€ ViewModels/
â”‚   â”œâ”€â”€ Utilities/
â”‚   â””â”€â”€ Resources/
â”œâ”€â”€ TranslateCallTests/            # Unit tests
â”œâ”€â”€ TranslateCallUITests/          # UI tests
â”œâ”€â”€ Installer/                     # Installation scripts
â””â”€â”€ Scripts/                       # Build/utility scripts
```

---

## ðŸ”§ Development Environment Setup

### Step 1: Open in Xcode

```bash
cd TranslateCall
open TranslateCall.xcodeproj
```

### Step 2: Configure Signing

```
In Xcode:
1. Select project in navigator
2. Select "TranslateCall" target
3. Go to "Signing & Capabilities"
4. Select your Team
5. Ensure "Automatically manage signing" is checked

If you don't have a team:
- For development: Use "Sign to Run Locally" (free)
- For distribution: Need Apple Developer Program ($99/year)
```

### Step 3: Set Deployment Target

```
In Xcode:
1. Select project
2. Select target
3. General tab
4. Set "Minimum Deployment" to macOS 14.0
```

### Step 4: Configure Build Settings

**Debug Configuration** (default for development):
```yaml
Optimization Level: None [-Onone]
Swift Compilation Mode: Incremental
Debug Information: DWARF with dSYM
Enable Testability: Yes
```

**Release Configuration** (for testing production builds):
```yaml
Optimization Level: Optimize for Speed [-O]
Swift Compilation Mode: Whole Module
Debug Information: DWARF with dSYM
Strip Debug Symbols: Yes
```

---

## ðŸŽ™ï¸ Audio Setup

### Install BlackHole

BlackHole is required for virtual audio devices.

```bash
# Download BlackHole 2ch
cd ~/Downloads
curl -L https://github.com/ExistentialAudio/BlackHole/releases/download/v2.0.0/BlackHole2ch.v2.0.0.pkg -o BlackHole2ch.pkg

# Install
sudo installer -pkg BlackHole2ch.pkg -target /

# Verify installation
ls /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver
```

### Configure Audio MIDI Setup

```
1. Open "Audio MIDI Setup" (/Applications/Utilities/)
2. Verify "BlackHole 2ch" appears in device list
3. Create Multi-Output Device (optional for testing):
   - Click "+" â†’ "Create Multi-Output Device"
   - Check: Built-in Output + BlackHole 2ch
   - This lets you hear audio while routing to BlackHole
```

---

## ðŸ”‘ Permissions Setup

### Grant Development Permissions

The app needs these permissions. During development, you'll be prompted:

```yaml
Microphone Access:
  - Required for audio capture
  - Grant in System Settings â†’ Privacy & Security â†’ Microphone

Accessibility:
  - Required for virtual audio routing
  - Grant in System Settings â†’ Privacy & Security â†’ Accessibility

(Optional) Speech Recognition:
  - May be needed for development
  - Auto-granted for Apple's Speech Framework
```

---

## ðŸ“¦ Dependencies

TranslateCall has **minimal external dependencies** by design.

### Bundled Dependencies

**BlackHole** (virtual audio driver):
```
Location: Installer/BlackHole2ch.pkg
Purpose: Virtual audio devices
License: GPL-3.0
Install: Automated during app first launch
```

### System Frameworks (No Installation Needed)

All other dependencies are Apple frameworks:
- AVFoundation
- Speech
- Translation
- Accelerate
- SwiftUI
- Combine
- CoreML (future)

---

## ðŸ—ï¸ Building the Project

### Build for Development

```bash
# From terminal
cd TranslateCall
xcodebuild -project TranslateCall.xcodeproj \
           -scheme TranslateCall \
           -configuration Debug \
           build

# Or in Xcode: Cmd+B
```

### Run in Debug Mode

```bash
# From terminal
xcodebuild -project TranslateCall.xcodeproj \
           -scheme TranslateCall \
           -configuration Debug \
           run

# Or in Xcode: Cmd+R
```

### Build for Release

```bash
xcodebuild -project TranslateCall.xcodeproj \
           -scheme TranslateCall \
           -configuration Release \
           build
```

---

## ðŸ§ª Running Tests

### Unit Tests

```bash
# Run all tests
xcodebuild test -project TranslateCall.xcodeproj \
                -scheme TranslateCall

# Run specific test class
xcodebuild test -project TranslateCall.xcodeproj \
                -scheme TranslateCall \
                -only-testing:TranslateCallTests/AudioManagerTests

# Or in Xcode: Cmd+U
```

### UI Tests

```bash
xcodebuild test -project TranslateCall.xcodeproj \
                -scheme TranslateCall \
                -only-testing:TranslateCallUITests
```

### Test Coverage

```bash
# Enable code coverage in Xcode:
# Edit Scheme â†’ Test â†’ Options â†’ Code Coverage

# Generate coverage report
xcodebuild test -project TranslateCall.xcodeproj \
                -scheme TranslateCall \
                -enableCodeCoverage YES

# View coverage in Xcode:
# Report Navigator (Cmd+9) â†’ Coverage tab
```

---

## ðŸ” Debugging

### Debug Logging

```swift
// In development builds, enable verbose logging
#if DEBUG
Logger.shared.level = .verbose
#else
Logger.shared.level = .warning
#endif

// Use throughout code
Logger.shared.debug("Audio buffer received: \(buffer.frameLength) frames")
Logger.shared.info("Translation started: \(sourceLanguage) â†’ \(targetLanguage)")
Logger.shared.warning("High CPU usage detected: \(cpuPercent)%")
Logger.shared.error("Failed to process audio: \(error)")
```

### Xcode Debugging Tools

#### **Breakpoints**
```
Set breakpoints:
- Click line number gutter
- Or Cmd+\

Conditional breakpoints:
- Right-click breakpoint â†’ Edit Breakpoint
- Add condition, e.g.: buffer.frameLength > 1000
```

#### **LLDB Commands**
```lldb
# Print variable
(lldb) po variableName

# Print frame info
(lldb) frame variable

# Continue execution
(lldb) continue

# Step over
(lldb) next

# Step into
(lldb) step
```

#### **View Debugging**
```
Debug View Hierarchy:
- Run app
- Debug â†’ View Debugging â†’ Capture View Hierarchy
- Explore 3D view of UI
```

### Instruments

```bash
# Profile with Instruments
open -a Instruments

# Common profiles:
- Time Profiler: CPU usage
- Allocations: Memory usage  
- Leaks: Memory leaks
- Energy Log: Battery impact
- System Trace: Comprehensive analysis
```

---

## ðŸŽ¨ SwiftUI Previews

### Enable Live Previews

```swift
// In any View file
#Preview {
    ContentView()
        .environmentObject(AppSettings())
}

// With sample data
#Preview {
    ControlPanelView(
        config: TranslationConfig(
            sourceLanguage: .spanish,
            targetLanguage: .english
        )
    )
}
```

### Preview Tips

```swift
// Multiple previews
#Preview("English") {
    ContentView()
        .environment(\.locale, .init(identifier: "en"))
}

#Preview("Spanish") {
    ContentView()
        .environment(\.locale, .init(identifier: "es"))
}

// Dark mode
#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
```

---

## ðŸ”§ Development Tools

### Recommended Xcode Extensions

```yaml
SwiftLint:
  Purpose: Code style enforcement
  Install: brew install swiftlint
  Config: .swiftlint.yml in project root

SwiftFormat:
  Purpose: Code formatting
  Install: brew install swiftformat
  Config: .swiftformat in project root
```

### SwiftLint Setup

```bash
# Install
brew install swiftlint

# Create config
cat > .swiftlint.yml << EOF
disabled_rules:
  - trailing_whitespace
  - line_length

opt_in_rules:
  - empty_count
  - explicit_init

included:
  - TranslateCall

excluded:
  - Pods
  - TranslateCallTests

line_length: 120
EOF

# Run manually
swiftlint

# Auto-fix
swiftlint --fix
```

### Run Script Phase (Auto-lint on Build)

```bash
# In Xcode:
# Target â†’ Build Phases â†’ + â†’ New Run Script Phase
# Add:

if which swiftlint >/dev/null; then
  swiftlint
else
  echo "warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint"
fi
```

---

## ðŸ› Common Issues & Solutions

### Issue 1: "No such module 'Speech'"

**Problem**: Framework not found

**Solution**:
```
1. Select target in Xcode
2. General â†’ Frameworks, Libraries, and Embedded Content
3. Click "+" and add Speech.framework
4. Clean build folder (Shift+Cmd+K)
5. Rebuild (Cmd+B)
```

### Issue 2: Microphone Permission Denied

**Problem**: App can't access microphone

**Solution**:
```bash
# Reset permissions
tccutil reset Microphone

# Run app again to re-request permission
```

### Issue 3: BlackHole Not Showing Up

**Problem**: Virtual audio device not available

**Solution**:
```bash
# Restart CoreAudio
sudo killall coreaudiod

# Verify installation
ls -la /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver

# Reinstall if needed
sudo installer -pkg BlackHole2ch.pkg -target /
```

### Issue 4: Build Fails with "Swift Compiler Error"

**Problem**: Syntax error or API mismatch

**Solution**:
```
1. Check Swift version: 6.0 required
2. Clean build folder: Shift+Cmd+K
3. Delete derived data:
   rm -rf ~/Library/Developer/Xcode/DerivedData
4. Restart Xcode
5. Rebuild
```

### Issue 5: High CPU Usage During Development

**Problem**: Debug builds are slow

**Solution**:
```
1. Disable Metal API Validation (Debug GPU usage)
   Edit Scheme â†’ Run â†’ Options â†’ Uncheck "Metal API Validation"

2. Reduce optimization for debug:
   Build Settings â†’ Optimization Level â†’ None [-Onone]

3. Disable expensive features during debugging
   #if DEBUG
   // Skip voice cloning in debug
   #endif
```

---

## ðŸ“ Coding Guidelines

### Swift Style Guide

Follow Apple's Swift style guide with these conventions:

#### **Naming**
```swift
// Classes, Structs, Enums: PascalCase
class AudioManager { }
struct VoiceProfile { }
enum Language { }

// Functions, Variables: camelCase
func processAudioBuffer() { }
var translationService: TranslationService

// Constants: camelCase
let defaultSampleRate = 48000.0

// Private properties: leading underscore optional
private var _internalBuffer: AVAudioPCMBuffer?
```

#### **Code Organization**
```swift
// MARK: - for major sections
class AudioManager {
    
    // MARK: - Properties
    private let engine: AVAudioEngine
    
    // MARK: - Initialization
    init() { }
    
    // MARK: - Public Methods
    func startCapture() { }
    
    // MARK: - Private Methods
    private func configureEngine() { }
}
```

#### **Comments**
```swift
// Use documentation comments for public APIs
/// Processes an audio buffer for translation
/// - Parameter buffer: The audio buffer to process
/// - Returns: Processed audio buffer
/// - Throws: AudioError if processing fails
func processBuffer(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer

// Regular comments for implementation details
// Calculate RMS energy for voice activity detection
let rms = calculateRMS(buffer)
```

### Git Workflow

#### **Branch Naming**
```bash
feature/voice-training-ui
bugfix/audio-dropout-issue
refactor/translation-service
docs/api-documentation
```

#### **Commit Messages**
```bash
# Format: <type>: <subject>

feat: Add voice profile training UI
fix: Resolve audio dropout during translation
refactor: Simplify AudioManager initialization
docs: Update API documentation
test: Add unit tests for VoiceAnalyzer
chore: Update dependencies
```

#### **Pull Request Process**
```
1. Create feature branch from main
2. Make changes and commit
3. Push branch to GitHub
4. Create PR with description
5. Request review
6. Address feedback
7. Merge when approved
```

---

## ðŸš€ Running the App

### Development Run

```bash
# Build and run
xcodebuild -project TranslateCall.xcodeproj \
           -scheme TranslateCall \
           -configuration Debug \
           run

# Or in Xcode: Cmd+R
```

### Testing with Video Call Apps

1. **Setup**:
   ```
   - Build and run TranslateCall
   - Select microphone/speaker
   - Choose languages
   - Complete voice training (optional)
   - Click "Start"
   ```

2. **Configure Zoom/Teams**:
   ```
   - Audio Settings
   - Microphone: "BlackHole 2ch" (TranslateCall's virtual output)
   - Speaker: "BlackHole 2ch" (optional, or use real speakers)
   ```

3. **Test Call**:
   ```
   - Make test call
   - Speak in source language
   - Remote person should hear target language
   - Hear remote person in your language
   ```

---

## ðŸ“Š Performance Monitoring

### During Development

```swift
// Add performance logging
import os.signpost

let log = OSLog(subsystem: "com.translatecall", category: "Performance")

func processAudio() {
    os_signpost(.begin, log: log, name: "Audio Processing")
    
    // Your processing code
    
    os_signpost(.end, log: log, name: "Audio Processing")
}
```

### View in Instruments

```
1. Run app in Instruments (Cmd+I)
2. Choose "os_signpost" template
3. Run app and perform actions
4. View timeline of signposts
5. Identify bottlenecks
```

---

## ðŸ“š Learning Resources

### Apple Documentation
- [AVFoundation Guide](https://developer.apple.com/av-foundation/)
- [Speech Framework](https://developer.apple.com/documentation/speech)
- [Translation API](https://developer.apple.com/documentation/translation)
- [SwiftUI Tutorials](https://developer.apple.com/tutorials/swiftui)

### Books
- "Audio Programming in Swift" (Various authors)
- "SwiftUI by Tutorials" (raywenderlich.com)
- "Advanced Swift" (objc.io)

### Internal Documentation
- [Architecture](ARCHITECTURE.md) - System design
- [Tech Stack](TECH_STACK.md) - Technologies used
- [Voice Cloning](VOICE_CLONING.md) - Voice cloning details

---

## ðŸ¤ Contributing

### Before Contributing

1. Read [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md)
2. Review [CONTRIBUTING.md](../CONTRIBUTING.md)
3. Check [GitHub Issues](https://github.com/[username]/TranslateCall/issues)

### First Contribution Ideas

Good first issues:
- Documentation improvements
- UI refinements
- Test coverage
- Bug fixes
- Localization

---

## ðŸ’¬ Getting Help

### Resources

- **Documentation**: `docs/` folder
- **Issues**: [GitHub Issues](https://github.com/[username]/TranslateCall/issues)
- **Discussions**: [GitHub Discussions](https://github.com/[username]/TranslateCall/discussions)
- **Email**: dev@translatecall.app

### Asking Good Questions

```
Good question format:
1. What are you trying to do?
2. What have you tried?
3. What error do you see?
4. Environment (macOS version, Xcode version)
5. Relevant code snippet
```

---

## âœ… Setup Checklist

Before starting development, ensure:

- [ ] macOS 14.0+ installed
- [ ] Xcode 15.0+ installed
- [ ] Command Line Tools installed
- [ ] Repository cloned
- [ ] Project opens in Xcode
- [ ] Code signing configured
- [ ] BlackHole installed
- [ ] Permissions granted
- [ ] Project builds successfully (Cmd+B)
- [ ] Tests pass (Cmd+U)
- [ ] SwiftLint installed and configured
- [ ] Git configured
- [ ] Documentation read

---

## ðŸŽ‰ Ready to Develop!

You're all set! Start with:

1. Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand the system
2. Check [ROADMAP.md](ROADMAP.md) to see current priorities
3. Pick an issue or feature to work on
4. Write code and tests
5. Submit pull request

**Happy coding!** ðŸš€

---

**Last Updated**: November 2025  
**Version**: 1.0  
**Questions?** dev@translatecall.app
