<div align="center">
<img src="FaceUnlock/Assets.xcassets/AppIcon.appiconset/512.png" width="96" alt="FaceUnlock icon" /><br><br>
 
<h1>macOS FaceUnlock</h1>
 
<p><strong>Unlock your Mac with your face.</strong><br>
Free, open-source face-recognition unlock daemon for macOS. No additional hardware, no cloud, no subscription.</p>
 
 
![Download](https://img.shields.io/badge/Download-v1.0.0-555?style=flat-square&labelColor=555555&color=0075ca)
![macOS](https://img.shields.io/badge/macOS-13.0%2B-555?style=flat-square&labelColor=555555&color=0075ca)
![Camera](https://img.shields.io/badge/camera-FaceTime-555?style=flat-square&labelColor=555555&color=2ea44f)
![Processing](https://img.shields.io/badge/processing-local%20only-555?style=flat-square&labelColor=555555&color=2ea44f)
![Telemetry](https://img.shields.io/badge/telemetry-none-555?style=flat-square&labelColor=555555&color=2ea44f)
![License](https://img.shields.io/badge/license-MIT-555?style=flat-square&labelColor=555555&color=2ea44f)
![Stars](https://img.shields.io/github/stars/HasBrain/FaceUnlock?style=flat-square&labelColor=555555&color=0075ca)

  
</div>

---

## Table of Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Demo](#demo)
- [Install](#install)
- [Setup](#setup)
- [Daily use](#daily-use)
- [Security model](#security-model)
- [Tech stack](#tech-stack)
- [Migration from earlier versions](#migration-from-earlier-versions)
- [Acknowledgments](#acknowledgments)
- [License](#license)

---

## What it does

- Enrolls your face from 7 poses using **ArcFace** (InsightFace ResNet50, converted to Core ML, running on the Apple Neural Engine).
- On the lock screen, pressing Space/Return (or waking the display) triggers a scan that verifies identity + liveness, then types your Mac password for you.
- Runs as a menu bar agent.
- Your Mac password and face embeddings are AES-GCM encrypted with a session key stored in the Keychain and gated by Touch ID. One Touch ID unlock is needed per reboot to arm auto-unlock.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon strongly recommended (Intel works, but slower)
- A default camera (built-in, external, or Continuity Camera)
- Touch ID or a device password

## Demo

Full install + setup walkthrough on YouTube:

[![FaceUnlock walkthrough](https://img.youtube.com/vi/hPLT-sykfNc/maxresdefault.jpg)](https://youtu.be/TZHXuBUaZ_8)

## Install

### Via Homebrew

1. Add the tap:
   ```
   brew tap sh4dow-clone/tap
   ```
2. Install the cask:
   ```
   brew install --cask sh4dow-clone/tap/faceunlock
   ```

> 💡 **If macOS blocks the app on first launch remove the quarantine attribute:**
>
> ```
> xattr -dr com.apple.quarantine /Applications/FaceUnlock.app
> ```



### Direct download

Alternatively, download the app directly from the [Releases](../../releases) page.

## Setup

> Prefer video? The [demo above](#demo) walks through install and setup end-to-end.

1. Open **FaceUnlock.app** and allow **camera** access when prompted.
2. Grant **Accessibility** permission (Settings tab → "Request Permission…") - needed to type into the lock screen.
3. **Set Mac password**: Settings tab → "Set Password…", enter your login password twice.
4. **Enroll your face**: Face Recognition tab → "Capture" (requires Touch ID) and follow the 7-pose guide.
5. Turn on **"Auto-unlock when display wakes (while screen is locked)"**.

Use **"Add Captures"** later to enroll more embeddings under different lighting (up to 35 total, oldest evicted first) - this improves accuracy and lets you safely raise the match threshold.

### Optional settings

| Setting | Description |
|---|---|
| **Icon Placement** | Show/hide Dock and Menu Bar icons independently. |
| **Launch at Login** | Add FaceUnlock via System Settings → General → Login Items. |
| **Auto-scan when face is centered** | Triggers a scan automatically without a keypress. Off by default. |
| **Match threshold** | Default 0.70. Recommended after a few enrollment sessions: 0.75 (balanced), 0.80 (secure), 0.85 (high-security). |
| **Auto-unlock delay** | Default 4s between trigger and camera activation, so you can abort with `⌃⌘Q`. |

## Daily use

1. Lock your Mac.
2. Wake the display and press **Space** or **Return** on the lock screen.
3. Camera runs for up to 15s, checks face + liveness, and types your password in.
4. If it can't recognize you in time, the camera turns off and you type your password manually - same fallback as Face ID / Windows Hello.

Working distance: roughly 20–70cm from the camera.

## Security model

| Data | Storage | Encryption |
|---|---|---|
| Mac password | Keychain | AES-GCM + Keychain |
| Session key | Keychain | `SecAccessControl(.userPresence)` - Touch ID required |
| Face embeddings | `~/Library/Application Support/FaceUnlock/embeddings.enc` | AES-GCM, same session key |
| Settings | UserDefaults | Plaintext (not sensitive) |

The session key is the single unwrap point - without Touch ID, the password blob and embeddings file are both meaningless ciphertext.

**Built-in protections:**

- ArcFace face matching with proper alignment/normalization and cosine similarity against your enrolled set.
- Multi-frame averaging and a pose filter to reduce noise.
- Passive movement-based liveness check (defeats static photos).
- Only faces in a centered ROI are considered.
- Password exists as plaintext only briefly, zeroed immediately after use.
- Hardened Runtime, anti-debugger protection, minimal entitlements (camera + keychain only - no network, no other permissions).
- Fully local processing - no telemetry, no third-party SDKs.

**Things to keep in mind:**

- After Touch ID authorizes access, FaceUnlock briefly accesses your password only to complete the unlock. The app uses Hardened Runtime and minimal system permissions to help protect this process, while macOS security continues to provide the primary layer of protection.
- FaceUnlock uses movement-based liveness detection to distinguish a real person from a static photo. While it doesn't use dedicated depth hardware, it provides reliable verification for everyday use.
- If you have a very close lookalike (such as an identical twin), increasing the match threshold can provide additional confidence.

**Bottom line:** FaceUnlock adds a fast, convenient unlock experience while keeping your existing macOS password as the foundation of your security. Review the security model to choose the settings that best match your preferences.

## Tech stack

SwiftUI · AVFoundation · Vision · Core ML (ArcFace on ANE) · CryptoKit (AES-GCM) · LocalAuthentication · Keychain Services · CGEvent keystroke injection

## Migration from earlier versions

Older builds stored embeddings as plaintext JSON. This is auto-migrated to encrypted storage on your next enrollment - your existing enrollment keeps working in the meantime. To migrate immediately: Face Recognition tab → Reset → Capture.

## Acknowledgments

- **InsightFace** for the [w600k_r50](https://github.com/deepinsight/insightface/tree/master/model_zoo)

## License

Personal-use. If you redistribute, verify InsightFace's model license terms apply to your use case.

## Support

If it's saved you some time, consider supporting - I'm a student maintaining this in my spare time.

Right now I'm trying to raise **$99 for an Apple Developer Program membership**. That's what it costs to get the app properly signed and notarized - which would eliminate the security warning on install entirely. No more scary popups, no more running `xattr` and `codesign` in the terminal just to open the app.

If you've hit that warning yourself, that's exactly what your support would fix for everyone after you.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/sh4dow_clone)

A ⭐ star also helps - it makes the project easier to find for other macOS users who need this.
