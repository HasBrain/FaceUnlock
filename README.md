# FaceUnlock

A face-recognition unlock daemon for macOS. When you lock your Mac, FaceUnlock recognizes you through the camera and types your password into the lock screen for you. No additional hardware required — the FaceTime camera and Apple Neural Engine do the work.

**Everything is processed locally.** Nothing leaves your Mac. The full stack — camera capture, face detection, ML inference, encryption — runs on-device.

> ⚠️ Personal-use security tool. Read the **Security model** section before relying on it.

---

## What it does

- Enrolls your face from 7 poses (straight, turn left/right, roll left/right, closer, farther) using **ArcFace** — the InsightFace ResNet50 model trained on WebFace600K, converted to Core ML and executed on the Apple Neural Engine.
- On lock screen, when you press Space / Return or the display wakes from sleep, it silently scans your face, verifies identity + liveness, and types your Mac password into the password field.
- Runs as a menu bar agent. Dock icon is optional and toggled at runtime.
- Both the **Mac password** and the **enrolled face embeddings** are encrypted with AES-GCM using a session key that itself lives in the Keychain protected by Touch ID. First app launch after each reboot requires one Touch ID to unwrap the session key — same model as Face ID and Windows Hello.

## Requirements

- macOS **14 (Sonoma)** or later
- Apple Silicon strongly recommended (ANE inference is fastest there). Intel Macs work but slower.
- A camera the OS considers the default (built-in FaceTime, external webcam if that's the only camera, or Continuity Camera on macOS 13+).
- Touch ID **or** a device password.

## End-to-end flow

```mermaid
flowchart TD
    A[App Launch] --> B{Password stored?}
    B -->|no| Setup[Setup Flow<br/>Enroll face + Set password<br/>Both silently generate the<br/>same AES-GCM session key]
    B -->|yes| C[Touch ID prompt<br/>Unwrap AES-GCM session key]
    C --> D{User authenticated?}
    D -->|no| L[Session locked<br/>Auto-unlock disabled<br/>Menu bar shows retry]
    D -->|yes| R[Session key in memory<br/>Auto-unlock armed]

    R --> W[Menu bar agent<br/>waiting for triggers]

    W --> T{Trigger fires?}
    T -->|Display wakes<br/>while locked| U[Delay Ns]
    T -->|Space / Return<br/>on lock screen| U
    T -->|Face centered in circle<br/>window open, auto-scan on| U
    T -->|manual button| U

    U --> S[Camera on<br/>Start scan loop]

    S --> V[Detect face inside ROI<br/>via Apple Vision]
    V --> X{Exactly 1 face<br/>in ROI?}
    X -->|no| S
    X -->|yes| E[Crop face → ArcFace ANE inference<br/>512-d embedding]

    E --> DEC[Decrypt enrolled embeddings<br/>with session key]
    DEC --> M[Cosine similarity vs<br/>enrolled centroid + max]
    M --> Y{Both ≥ threshold?}
    Y -->|no| S

    Y -->|yes| K[Movement liveness<br/>0.4s yaw/roll variance ≥ 0.013 rad]
    K --> Z{Live?}
    Z -->|no| S
    Z -->|yes| P[Read encrypted password blob<br/>Decrypt with session key<br/>→ Data]

    P --> I[CGEvent keystroke injection<br/>UTF-8 → Unicode events]
    I --> ZERO[resetBytes: zero password buffer]
    ZERO --> UNL[Lock screen unlocks]

    S -.15s timeout.-> TO[Camera off<br/>User falls back to password]
```

## Setup

### One-time

1. Open FaceUnlock.app.
2. **Camera permission** → allow when prompted.
3. **Accessibility permission**: Settings tab → "Request Permission…" → toggle FaceUnlock on in System Settings → Privacy & Security → Accessibility. Required to inject keystrokes into the lock screen.
4. **Set Mac password**: Settings tab → "Set Password…" → enter your macOS login password twice. Generates a fresh AES-GCM 256-bit session key (or reuses the one from a prior enrollment), encrypts the password with it.
5. **Enroll your face**: Face Recognition tab → "Capture" (requires Touch ID). Follow the 7-pose guide (straight, turn left/right, roll left/right, closer, farther). The resulting embeddings are encrypted with the same session key before being written to disk.
6. Turn on **"Auto-unlock when display wakes (while screen is locked)"** in Settings tab.

### Optional

- **Icon Placement** (menu bar → Icon Placement): toggle Dock and/or Menu Bar visibility independently.
- **Launch at Login**: use macOS's built-in **System Settings → General → Login Items → Open at Login** to add FaceUnlock so it starts with your Mac.
- **Auto-scan when face is centered**: polls the camera and triggers automatically when your face is well-positioned in the circle. Off by default.
- **Match threshold**: default 0.70. Lower = easier match (faster, less strict). Higher = stricter. Persisted across launches.
- **Auto-unlock delay**: default 4s between trigger and camera turning on. Gives you time to abort with `⌃⌘Q` → password if you decide against face unlock.

## Daily use

1. Lock your Mac (`⌃⌘Q` or close the lid).
2. When you come back, wake the display and press **Space** or **Return** on the lock screen.
3. Camera turns on for ≤ 15s. Face + liveness check runs. Password auto-injected. Mac unlocks.
4. If the scan times out (couldn't recognize you within 15s) the camera turns off and you fall back to typing your password manually. Same behavior as Windows Hello and Face ID.

Working distance: recognizes faces from **~20cm out to ~70cm** from the camera. Sitting at a normal desk position works.

## Security model

### Everything sensitive is encrypted at rest

| Data | Storage | Encryption |
|---|---|---|
| **Mac password (ciphertext blob)** | Keychain (`encryptedPasswordBlob`) | AES-GCM (our layer) + macOS Keychain |
| **Session key (256-bit AES)** | Keychain (`sessionKey`) | Keychain + `SecAccessControl(.userPresence)` — decrypt requires Touch ID |
| **Face embeddings (ciphertext blob)** | `~/Library/Application Support/FaceUnlock/embeddings.enc` | AES-GCM with the same session key |
| User settings (thresholds, toggles) | UserDefaults | plaintext — not sensitive |
| ArcFace model | App bundle | plaintext — public model |

The session key is the single unwrap point. Without Touch ID, nothing decrypts:
- Session key ciphertext in the Keychain is meaningless.
- Encrypted password blob is meaningless.
- Encrypted embeddings file is meaningless.

### What's guaranteed

- ✅ **Face match**: ArcFace 512-d embeddings. Cosine similarity against your enrolled centroid AND max, both must clear the threshold.
- ✅ **Liveness**: passive movement detection — natural yaw/roll variance of ≥ 0.013 rad over ~0.4s of data. A flat photograph or a screenshot can't accumulate the variance.
- ✅ **ROI filtering**: only faces whose center falls inside the centered 50% × 60% ROI are considered — background people are ignored.
- ✅ **AES-GCM encryption** of both password and enrollment data using a session key held only in memory after unwrap.
- ✅ **Data-based password handling**: password flows through as `Data`, plaintext lifetime bounded by `.resetBytes(in:)` immediately after keystroke injection.
- ✅ **Touch ID gate** on enrollment, reset, and password clear.
- ✅ **Global keystroke monitor** only listens for `Space` / `Return` / `Numpad Enter`, and only while the screen is locked. Torn down on unlock.
- ✅ **Hardened Runtime** with no exceptions enabled. No JIT, no unsigned memory, no disabled library validation, no DYLD env variables, no debugger attach in release builds.
- ✅ **Anti-debugger**: `PT_DENY_ATTACH` in release builds. Blocks casual `lldb -p <pid>` attacks.
- ✅ **Clean entitlements**: only `keychain-access-groups` and `Camera` under Hardened Runtime. Zero network, zero AppleEvents, zero Contacts / Calendar / Photos.
- ✅ **All processing local**. No third-party SDKs, no network I/O, no telemetry.

### What's NOT guaranteed

- ⚠️ **In-process compromise reads plaintext once session is unlocked.** Once Touch ID has unwrapped the session key, any code running as our bundle can call `PasswordVault.readPassword()` or `decryptWithSessionKey(...)` to recover plaintext. Hardened Runtime with no library-validation exceptions raises the bar significantly — dylib injection is blocked, arbitrary in-process code execution requires a real exploit. But if such an exploit exists, encryption at rest doesn't help while the session is active.
- ⚠️ **Liveness is 2D movement-based, not depth-based.** A well-composed looping video of you on a phone screen could in principle sway enough to pass. A printed photo cannot.
- ⚠️ **Identical-twin / close-lookalike risk.** ArcFace is very discriminative but not perfect. If someone who looks a lot like you stands in front of the camera, they might match. Tune the threshold upward to reduce this.
- ⚠️ **Password is briefly present as a Swift `String` during keystroke injection.** `String` doesn't zero on release. We minimize this to a few milliseconds inside `KeystrokeInjector.typeAndReturn`, but it's a real window.

### Bottom line

FaceUnlock is a **convenience layer over your macOS login password**. The password remains the real secret. If you don't trust the threat model above, don't enable auto-unlock.

## Tech stack

- **SwiftUI + `@Observable`** (macOS 14+)
- **AVFoundation** — camera capture
- **Vision** — face detection with normalized ROI filtering
- **Core ML** — ArcFace inference on the Apple Neural Engine
- **CryptoKit** — AES-GCM 256-bit encryption of stored password AND enrolled embeddings
- **LocalAuthentication** — Touch ID gating (enrollment, session unwrap, reset)
- **Keychain Services** — session key (userPresence-gated) + encrypted password blob
- **CGEvent** — Unicode keystroke injection to the lock screen field
- **NSEvent.addGlobalMonitorForEvents** — Space / Return monitor while locked
- **DistributedNotificationCenter** — screen lock / unlock notifications
- **NSWorkspace** — display sleep / wake notifications

## Architecture

```
FaceUnlockApp                    @main App scene
 ├─ AppDelegate                  Keep alive when last window closes
 └─ @State AppController         (long-lived, @Observable, @MainActor)
     ├─ CameraManager            AVCaptureSession lifecycle
     ├─ FaceEnrollmentService    Vision + Core ML pipeline
     │                           Encrypted embedding persistence
     │   └─ FaceEmbedder         Core ML wrapper (ArcFace preferred)
     ├─ LockMonitor              Distributed + Workspace notifications
     │                           (lock / unlock / sleep / wake)
     ├─ PasswordVault            AES-GCM session key + Keychain wrapper
     │                           encrypt/decrypt API used by both
     │                           password and embedding storage
     ├─ KeystrokeInjector        CGEvent Unicode + Return
     └─ Triggers                 Wake, user-input, framing, manual
ContentView                      Settings window (3 tabs)
MenuBarContent                   Status bar dropdown
```

## Migration from earlier versions

If you had an enrollment from an older FaceUnlock build (which stored embeddings as plaintext JSON at `embeddings.json`), it will be **auto-migrated on next enrollment**. The old file will be deleted and replaced with the encrypted `embeddings.enc` version. In the meantime, the app can still read the plaintext file — your existing enrollment keeps working across the upgrade.

If you'd prefer to migrate immediately: Face Recognition tab → Reset → Capture. Fresh enrollment, immediately encrypted.

## Acknowledgments

- **InsightFace** for the [w600k_r50](https://github.com/deepinsight/insightface/tree/master/model_zoo) ArcFace model.
- **FaceGate-Mac** by [@dweep-desai](https://github.com/dweep-desai/FaceGate-Mac) — this project's core ML pipeline structure (Vision face detection → 20% padded crop → 112×112 RGB normalized to [-1, 1] → Core ML embedding → centroid cosine similarity) is modeled after theirs.

## License

Personal-use. If you redistribute, verify InsightFace's model license terms apply to your use case.
