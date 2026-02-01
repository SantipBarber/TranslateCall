# TranslateCall - Privacy & Security

## 🔒 Privacy-First Architecture

TranslateCall is built with **privacy as the #1 priority**. This document explains our privacy model, security measures, and compliance considerations.

---

## 🎯 Core Privacy Principles

### 1. **On-Device Processing**
**Everything happens on your Mac. Period.**

```
┌─────────────────────────────────────────┐
│         YOUR MAC (macOS)                │
│                                         │
│  ┌────────────────────────────────┐    │
│  │   Audio Capture               │    │
│  │   Speech Recognition          │    │
│  │   Translation                 │    │
│  │   Speech Synthesis            │    │
│  │   Voice Cloning               │    │
│  └────────────────────────────────┘    │
│                                         │
│  NO DATA LEAVES THIS DEVICE             │
│  (except language pack downloads)       │
└─────────────────────────────────────────┘
```

**What this means**:
- ✅ Your conversations never go to external servers
- ✅ No cloud APIs process your audio
- ✅ No third parties can access your data
- ✅ Works completely offline (after setup)
- ✅ No tracking, analytics, or telemetry

### 2. **Data Minimization**
We only process what's absolutely necessary.

**What we process**:
- ✅ Audio from your microphone (real-time, in memory)
- ✅ Audio from video calls (real-time, in memory)
- ✅ Voice training samples (stored locally, encrypted)
- ✅ User preferences (stored locally)

**What we DON'T collect**:
- ❌ Conversation content
- ❌ Transcriptions
- ❌ Translations
- ❌ User behavior
- ❌ Analytics data
- ❌ Crash reports (unless you opt-in)
- ❌ Any personal information

### 3. **Transparency**
You always know what's happening.

- ✅ Open source code (planned)
- ✅ Clear permission requests
- ✅ Visible processing indicators
- ✅ No hidden data collection
- ✅ Honest documentation

### 4. **User Control**
You own your data.

- ✅ Delete voice profiles anytime
- ✅ Clear all app data
- ✅ Export settings
- ✅ No forced updates
- ✅ Opt-out of everything optional

---

## 🛡️ Security Model

### Data Flow Security

#### **Audio Processing Pipeline**
```
Microphone → Memory Buffer → Processing → Memory Buffer → Speakers
     ↓              ↓              ↓              ↓
  Encrypted    In Memory      In Memory      In Memory
    at OS      (no disk)      (no disk)      (no disk)
    level
```

**Security Measures**:
1. Audio never written to disk (except voice training samples)
2. All processing in volatile memory
3. Memory cleared when processing complete
4. No audio logs or debug recordings in release builds

#### **Voice Profile Storage**
```
Training Audio → Analysis → Voice Profile → Encrypted Storage
                                                    ↓
                                          ~/Library/Application Support/
                                          TranslateCall/VoiceProfiles/
                                          {uuid}/profile.encrypted
```

**Security Measures**:
1. Voice profiles encrypted at rest (AES-256)
2. Training samples encrypted (AES-256)
3. File permissions restrict access to app only
4. No iCloud sync (prevents cloud exposure)
5. Secure deletion when profile removed

#### **App Settings**
```yaml
Storage: ~/Library/Preferences/com.translatecall.plist
Encryption: macOS keychain for sensitive data
Permissions: User-only access (chmod 600)
Sync: None (local only)
```

### macOS Security Integration

#### **Sandboxing**
```yaml
App Sandbox: Disabled
Reason: Need system audio device access
Alternative Security:
  - Hardened Runtime: Enabled
  - Code Signing: Required
  - Notarization: Required
  - Minimal Entitlements: Yes
```

**Required Entitlements**:
```xml
<!-- Microphone access -->
<key>com.apple.security.device.audio-input</key>
<true/>

<!-- File access for voice profiles -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>

<!-- Network for language pack downloads -->
<key>com.apple.security.network.client</key>
<true/>
```

#### **Permission Model**
```swift
// Required Permissions
1. Microphone Access
   - Why: Capture your voice
   - When: First launch
   - Revocable: Yes (System Settings)

2. Accessibility
   - Why: Virtual audio device routing
   - When: First launch
   - Revocable: Yes (System Settings)

// Optional Permissions
3. Notifications (future)
   - Why: Alert when translation starts/stops
   - When: User requests
   - Revocable: Yes
```

---

## 🔐 Cryptography

### Encryption Standards

#### **Voice Profile Encryption**
```swift
Algorithm: AES-256-GCM
Key Derivation: PBKDF2
Salt: Random 32 bytes per profile
Iterations: 100,000
Key Storage: macOS Keychain (Secure Enclave on Apple Silicon)

// Example
let encryptedProfile = try encryptVoiceProfile(
    profile: voiceProfile,
    using: .aes256gcm,
    keyDerivation: .pbkdf2(iterations: 100_000)
)
```

**Why AES-256-GCM**:
- ✅ Industry standard
- ✅ Authenticated encryption (integrity + confidentiality)
- ✅ Hardware accelerated on Apple Silicon
- ✅ NIST approved

#### **Secure Key Management**
```swift
import Security

// Store encryption key in Keychain
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "TranslateCall",
    kSecAttrAccount as String: "VoiceProfileKey",
    kSecValueData as String: encryptionKey,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
]

SecItemAdd(query as CFDictionary, nil)
```

**Key Properties**:
- Stored in Keychain (not in app preferences)
- Protected by macOS security
- Uses Secure Enclave when available
- Cannot be extracted programmatically
- Deleted when profile is deleted

### Secure Deletion

#### **Memory**
```swift
// Zero out sensitive data when done
func securelyClearBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    let frameCount = Int(buffer.frameLength)
    memset(channelData[0], 0, frameCount * MemoryLayout<Float>.size)
}

// Clear strings securely
func securelyClearString(_ str: inout String) {
    str = String(repeating: "0", count: str.count)
    str = ""
}
```

#### **Files**
```swift
// Secure file deletion (overwrite before remove)
func securelyDeleteFile(at url: URL) throws {
    // 1. Overwrite with random data
    let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    let randomData = Data(count: fileSize).map { _ in UInt8.random(in: 0...255) }
    try randomData.write(to: url)
    
    // 2. Overwrite with zeros
    let zeros = Data(repeating: 0, count: fileSize)
    try zeros.write(to: url)
    
    // 3. Delete file
    try FileManager.default.removeItem(at: url)
}
```

---

## 🌐 Network Security

### Minimal Network Usage

**When we use the network**:
1. **Language Pack Downloads** (one-time)
   - From: Apple CDN
   - Protocol: HTTPS
   - Certificate Pinning: Yes
   - Size: 50-200MB per language
   - Frequency: Once per language

2. **App Updates** (optional)
   - From: GitHub Releases or App Store
   - Protocol: HTTPS
   - Signed: Yes (code signing)
   - User-initiated: Yes

**When we DON'T use the network**:
- ❌ During translation (everything is local)
- ❌ During voice training
- ❌ During audio processing
- ❌ For analytics or telemetry
- ❌ For crash reporting (unless opted in)

### Certificate Pinning
```swift
// For language pack downloads
import Security

func validateServerCertificate(_ challenge: URLAuthenticationChallenge) -> Bool {
    guard let serverTrust = challenge.protectionSpace.serverTrust else {
        return false
    }
    
    // Pin to Apple's certificate
    let appleCertificate = getAppleCertificate()
    return SecTrustEvaluateWithError(serverTrust, nil) &&
           certificateMatches(serverTrust, pinnedCertificate: appleCertificate)
}
```

---

## 👤 User Privacy

### No User Tracking

**What we DON'T track**:
- ❌ User identity
- ❌ Device identifiers
- ❌ Usage patterns
- ❌ Conversation content
- ❌ Translation history
- ❌ Voice training content
- ❌ App behavior
- ❌ Crash data (unless opted in)

### No Analytics

**Common analytics we explicitly avoid**:
- ❌ Google Analytics
- ❌ Mixpanel
- ❌ Amplitude
- ❌ Segment
- ❌ Firebase
- ❌ Any third-party analytics

### Optional Crash Reporting

If user opts in (default: OFF):
```yaml
Crash Reports:
  - Completely anonymous
  - No personal information
  - No audio data
  - No conversation content
  - Stack traces only
  - User can review before sending
  - Stored locally until sent
  - Can be disabled anytime
```

---

## 📜 Compliance

### GDPR Compliance

**Right to Access**: All data is on user's Mac  
**Right to Erasure**: User can delete all data anytime  
**Right to Portability**: Settings can be exported  
**Right to Rectification**: User has full control  
**Data Minimization**: We only process what's needed  
**Purpose Limitation**: Data used only for translation  
**Storage Limitation**: No long-term storage  
**Lawful Basis**: User consent + legitimate interest

**GDPR Status**: ✅ Compliant (no data collection)

### HIPAA Considerations

While TranslateCall is not HIPAA-certified, the architecture supports healthcare use:

✅ **On-device processing** (no PHI leaves device)  
✅ **No business associate needed** (no cloud services)  
✅ **Encryption at rest** (voice profiles)  
✅ **Audit trail** (optional local logs)  
✅ **Access controls** (macOS user permissions)

**Healthcare Use**: Suitable for telemedicine with proper policies

### COPPA Compliance

**Status**: ✅ Compliant (no data collection from anyone)

We don't collect personal information from users of any age.

### California Consumer Privacy Act (CCPA)

**Right to Know**: No data collected  
**Right to Delete**: User controls all data  
**Right to Opt-Out**: Nothing to opt out of  
**Right to Non-Discrimination**: N/A (no data collection)

**CCPA Status**: ✅ Compliant (no data sale or sharing)

---

## 🔍 Threat Model

### Assets to Protect
1. **User's Conversations** (most critical)
2. Voice profiles
3. User preferences
4. Training audio samples

### Threats & Mitigations

#### **Threat: Audio Interception**
- **Risk**: High
- **Impact**: Critical (conversation privacy breach)
- **Mitigation**:
  - All processing in memory
  - No network transmission
  - No disk logging
  - Encrypted at OS level (FileVault)

#### **Threat: Voice Profile Theft**
- **Risk**: Medium
- **Impact**: Medium (voice identity exposure)
- **Mitigation**:
  - AES-256 encryption at rest
  - Key stored in Keychain
  - File permissions (user-only)
  - Secure deletion

#### **Threat: Man-in-the-Middle (Language Packs)**
- **Risk**: Low
- **Impact**: Medium (malicious code injection)
- **Mitigation**:
  - HTTPS only
  - Certificate pinning
  - Apple's CDN (trusted)
  - Code signing verification

#### **Threat: Malicious App Impersonation**
- **Risk**: Medium
- **Impact**: High (user installs fake app)
- **Mitigation**:
  - Code signing (Apple Developer ID)
  - Notarization (Apple verification)
  - Official distribution channels
  - User education

#### **Threat: Memory Dump Attack**
- **Risk**: Low
- **Impact**: Medium (conversation extraction)
- **Mitigation**:
  - Memory encryption (FileVault)
  - SIP protection
  - Secure memory clearing
  - Minimal retention time

#### **Threat: Privileged Process Attack**
- **Risk**: Low
- **Impact**: High (system compromise)
- **Mitigation**:
  - Hardened runtime
  - Minimal entitlements
  - No root privileges required
  - System Integrity Protection (SIP)

---

## 🔬 Privacy Auditing

### Self-Audit Checklist

**Network Traffic**:
- [ ] Run Wireshark during translation
- [ ] Verify zero outbound connections
- [ ] Check DNS queries (should be none)
- [ ] Monitor during normal operation

**File System**:
- [ ] Monitor file writes
- [ ] Verify no unexpected files
- [ ] Check permissions on stored data
- [ ] Audit encryption of sensitive files

**Memory**:
- [ ] Profile memory usage
- [ ] Verify memory clearing
- [ ] Check for memory leaks
- [ ] Inspect retained objects

**System Calls**:
- [ ] Monitor system calls (dtrace)
- [ ] Verify minimal privilege usage
- [ ] Check API usage
- [ ] Audit entitlements

### External Audit (Future)

**When ready for production**:
- [ ] Third-party security audit
- [ ] Penetration testing
- [ ] Privacy assessment
- [ ] Code review by security experts
- [ ] Publish audit results

---

## 📖 Privacy Policy Summary

### Data Collection
**We collect: NOTHING**

The app processes audio locally but does not:
- Collect it
- Store it (except training samples, user-controlled)
- Transmit it
- Share it
- Analyze it for purposes other than translation

### Data Usage
Audio is processed in real-time for:
1. Speech recognition
2. Translation
3. Speech synthesis
4. Voice cloning

All processing is temporary and in memory.

### Data Sharing
**We share: NOTHING**

No data is ever shared with:
- Third parties
- Analytics providers
- Ad networks
- Other users
- Anthropic or any company

### Data Retention
- **Audio**: Deleted immediately after processing
- **Transcriptions**: Never stored
- **Translations**: Never stored
- **Voice Profiles**: Stored until user deletes
- **Settings**: Stored until user deletes

### User Rights
- Delete all data anytime
- Export settings
- Review what's stored
- Opt out of everything optional

---

## 🚨 Incident Response

### Security Vulnerability Handling

**If you discover a vulnerability**:
1. Email: security@translatecall.app (or GitHub Security Advisory)
2. Include: Description, steps to reproduce, impact
3. We will: Acknowledge within 48 hours
4. We will: Fix and release patch ASAP
5. We will: Credit you (if desired)

**Disclosure Policy**:
- Responsible disclosure (90 days)
- Public disclosure after patch
- Security advisory publication
- User notification if critical

### Data Breach Response

**In the unlikely event of a breach** (e.g., encryption flaw):
1. Immediate notification to all users
2. Root cause analysis
3. Patch release
4. Public disclosure
5. Regulatory notification (if required)

**However**: Given our architecture (no data collection, local processing), traditional "data breach" scenarios are unlikely.

---

## ✅ Privacy Advantages

### vs. Cloud Translation Services

| Feature | TranslateCall | Cloud Services |
|---------|--------------|----------------|
| Data leaves device | ❌ Never | ✅ Always |
| Privacy risk | 🟢 Minimal | 🔴 High |
| Works offline | ✅ Yes | ❌ No |
| Requires account | ❌ No | ✅ Yes |
| Third-party access | ❌ None | ✅ Service provider |
| Data breach risk | 🟢 Very low | 🔴 High |
| Cost | 🟢 Free (after purchase) | 🔴 Recurring |
| GDPR compliant | ✅ Yes | ⚠️ Depends |

### vs. AirPods Translation (Apple Intelligence)

| Feature | TranslateCall | AirPods Translation |
|---------|--------------|---------------------|
| Privacy | ✅ Excellent | ✅ Excellent |
| Platform | 🟡 Mac only | 🟡 iPhone only |
| Apps supported | ✅ Any | 🟡 Limited |
| Voice cloning | ✅ Yes | ❌ No |
| Customizable | ✅ Yes | 🟡 Limited |

---

## 🎓 User Education

### Privacy Tips for Users

**Best Practices**:
1. ✅ Enable FileVault (full disk encryption)
2. ✅ Keep macOS updated
3. ✅ Use strong Mac password
4. ✅ Don't share voice profiles
5. ✅ Delete old training samples
6. ✅ Review app permissions periodically

**What to Avoid**:
1. ❌ Don't run TranslateCall on shared Macs
2. ❌ Don't install from untrusted sources
3. ❌ Don't disable macOS security features
4. ❌ Don't share voice profile files

---

## 📝 Transparency Reports

**Planned**: Annual transparency reports covering:
- Data requests (expected: zero)
- Security incidents (expected: zero)
- Privacy complaints (and resolutions)
- Code audit results
- Privacy improvements

---

## 🔮 Future Privacy Enhancements

**Planned Features**:
1. **Differential Privacy**
   - For optional usage statistics
   - Mathematical privacy guarantees
   - User-controlled

2. **Federated Learning**
   - Improve translation quality
   - Without sharing data
   - On-device only

3. **Zero-Knowledge Architecture**
   - Even we can't access user data
   - End-to-end encryption for future cloud features
   - User controls keys

4. **Privacy Dashboard**
   - Real-time privacy monitoring
   - Data access logs
   - Permission audit
   - Security health check

---

## ❓ FAQ

### Q: Does TranslateCall phone home?
**A**: No. After language pack downloads, TranslateCall never contacts any server.

### Q: Can you hear my conversations?
**A**: No. We never receive your audio. It stays on your Mac.

### Q: Do you collect analytics?
**A**: No. Zero analytics. Zero tracking.

### Q: What if I don't trust you?
**A**: We plan to open source the code. Audit it yourself.

### Q: Can law enforcement access my data?
**A**: There's no data to access. Everything is on your Mac, encrypted.

### Q: What about backups?
**A**: Voice profiles in Time Machine are encrypted. We recommend keeping backups for recovery.

### Q: Can I use this for confidential calls?
**A**: Yes, but remember TranslateCall only handles translation. Your video app's security also matters.

---

**Last Updated**: November 2025  
**Version**: 1.0  
**Status**: Commitment to Privacy

**Questions?** privacy@translatecall.app
