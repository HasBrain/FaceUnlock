//
//  ContentView.swift
//  FaceUnlock
//
//  Created by Harsh on 25/06/26.
//
//  Thin presentation layer — all long-lived state lives in AppController.
//

import SwiftUI
import CoreVideo
import LocalAuthentication
import Vision

struct ContentView: View {
    @Bindable var controller: AppController

    // View-local enrollment state — only meaningful while the window is open and
    // the user is actively enrolling. Doesn't need to outlive the view.
    @State private var currentEnrollmentPose: FacePose? = nil
    @State private var currentPoseIndex: Int = 0
    @State private var poseProgress: (collected: Int, target: Int) = (0, 0)
    @State private var totalCaptured: Int = 0
    @State private var enrollmentTask: Task<Void, Never>? = nil

    // Password / accessibility view-local UI state
    @State private var showingPasswordSetup = false
    @State private var passwordMessage: String? = nil
    @State private var injectionMessage: String? = nil
    @State private var injectionCountdown: Int = 0

    // Constants for enrollment
    private let framesPerPose = 1                // one frame per pose — 7 diverse poses cover the variance previously earned by 2× redundancy
    private let posesInEnrollment = 7
    private var targetTotalEmbeddings: Int { framesPerPose * posesInEnrollment }
    private let perPoseTimeoutSeconds: Double = 60
    private let enrollmentPollIntervalNS: UInt64 = 150_000_000

    var body: some View {
        TabView {
            faceRecognitionTab
                .tabItem { Label("Face Recognition", systemImage: "faceid") }

            settingsTab
                .tabItem { Label("Settings", systemImage: "gearshape") }

            activityTab
                .tabItem { Label("Activity", systemImage: "list.bullet.clipboard") }
        }
        .frame(minWidth: 530, idealWidth: 530, maxWidth: 530,
               minHeight: 560, idealHeight: 560, maxHeight: 560)
        .sheet(isPresented: $showingPasswordSetup) {
            PasswordSetupSheet { saved in
                controller.refreshSetupState()
                if saved {
                    passwordMessage = "Password saved to Keychain."
                }
            }
        }
        .task {
            switch controller.camera.authorizationStatus {
            case .authorized:
                await controller.camera.start()
            case .notDetermined:
                await controller.camera.requestAccessAndStart()
            case .denied:
                break
            }
            controller.refreshSetupState()
        }
        .onDisappear {
            enrollmentTask?.cancel()
            if !controller.isWorking {
                controller.camera.stop()
            }
        }
    }

    // MARK: - Tab: Face Recognition

    @ViewBuilder
    private var faceRecognitionTab: some View {
        VStack(spacing: 10) {
            if let modelError = controller.service.modelLoadErrorMessage {
                modelMissingBanner(message: modelError)
            }

            circularViewfinder

            presencePrompt

            autoFramingToggle

            overlayPrompt

            controls

            thresholdSlider

            statusLabel
                .frame(minHeight: 50)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Circular viewfinder + presence prompt

    @ViewBuilder
    private var circularViewfinder: some View {
        let position = controller.framingPresence.position
        let ringColor: Color = {
            if controller.isVerifying { return .blue }
            switch position {
            case .noFace: return Color.gray.opacity(0.5)
            case .offCenter, .tooSmall, .tooLarge: return .orange
            case .good: return .green
            }
        }()

        ZStack {
            previewContent
                .frame(width: 280, height: 280)
                .clipShape(Circle())

            Circle()
                .stroke(ringColor, lineWidth: 4)
                .frame(width: 288, height: 288)
                .animation(.easeInOut(duration: 0.2), value: position)
                .animation(.easeInOut(duration: 0.2), value: controller.isVerifying)
        }
        .frame(width: 300, height: 300)
    }

    @ViewBuilder
    private var presencePrompt: some View {
        let position = controller.framingPresence.position
        let (text, color): (String, Color) = {
            if controller.isVerifying {
                return ("Scanning…", .blue)
            }
            switch position {
            case .noFace:    return ("Position your face in the circle", .secondary)
            case .offCenter: return ("Center your face", .orange)
            case .tooSmall:  return ("Move closer to the camera", .orange)
            case .tooLarge:  return ("Move back from the camera", .orange)
            case .good:
                if controller.autoFramingEnabled {
                    return ("Hold still — auto-scanning…", .green)
                } else {
                    return ("Face positioned", .green)
                }
            }
        }()

        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .frame(minHeight: 22)
    }

    @ViewBuilder
    private var autoFramingToggle: some View {
        HStack(spacing: 8) {
            Toggle("Auto-scan when face is centered",
                   isOn: $controller.autoFramingEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
            Spacer()
        }
    }

    // MARK: - Tab: Settings

    @ViewBuilder
    private var settingsTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if controller.hasStoredPassword && !controller.isSessionUnlocked {
                    GroupBox {
                        sessionLockContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Session Locked", systemImage: "lock.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                }

                GroupBox {
                    passwordContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Mac Password", systemImage: "key.fill")
                        .font(.headline)
                }

                GroupBox {
                    accessibilityContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Accessibility", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                }

                GroupBox {
                    autoUnlockContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Auto-Unlock", systemImage: "lock.rotation")
                        .font(.headline)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Tab: Activity

    @ViewBuilder
    private var activityTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                GroupBox {
                    screenStatusContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Screen Status", systemImage: "display")
                        .font(.headline)
                }

                GroupBox {
                    recentEventsContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Recent Events", systemImage: "list.bullet.clipboard")
                        .font(.headline)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Camera preview / banner

    @ViewBuilder
    private func modelMissingBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Face model not loaded").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                Text("Add ArcFace.mlpackage (or FaceEmbedding.mlpackage) to the FaceUnlock target and rebuild.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var previewContent: some View {
        switch controller.camera.authorizationStatus {
        case .authorized:
            CameraPreviewView(session: controller.camera.session)
        case .notDetermined:
            ProgressView("Requesting camera access…").foregroundStyle(.white)
        case .denied:
            VStack(spacing: 8) {
                Image(systemName: "video.slash").font(.system(size: 36))
                Text("Camera access denied")
                Text("Enable it in System Settings → Privacy & Security → Camera")
                    .font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white).padding()
        }
    }

    // MARK: - Overlay during enrollment / verify

    @ViewBuilder
    private var overlayPrompt: some View {
        if let pose = currentEnrollmentPose {
            enrollmentProgressView(pose: pose)
        } else if controller.isVerifying {
            verifyScanningView
        }
    }

    @ViewBuilder
    private func enrollmentProgressView(pose: FacePose) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle")
                Text(pose.prompt).font(.headline)
            }
            .foregroundStyle(.blue)

            HStack(spacing: 6) {
                ForEach(0..<poseProgress.target, id: \.self) { i in
                    Circle()
                        .fill(i < poseProgress.collected ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 10, height: 10)
                }
                Text("Pose \(currentPoseIndex + 1) of \(posesInEnrollment) • \(totalCaptured) of \(targetTotalEmbeddings) total")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }

            if let live = controller.liveAnalysis {
                HStack(spacing: 12) {
                    if Self.poseUsesYaw(pose) {
                        liveStatView("yaw", value: live.yaw, satisfied: yawSatisfied(pose, yaw: live.yaw))
                    }
                    if Self.poseUsesRoll(pose) {
                        liveStatView("roll", value: live.roll, satisfied: rollSatisfied(pose, roll: live.roll))
                    }
                    if Self.poseUsesSize(pose) {
                        liveStatView("size", value: Float(live.faceWidth),
                                     satisfied: sizeSatisfied(pose, faceWidth: live.faceWidth))
                    }
                    liveStatView("quality", value: live.quality,
                                 satisfied: live.quality >= FaceEnrollmentService.minimumCaptureQuality)
                }
                .font(.caption.monospacedDigit())
            } else if let err = controller.liveError {
                Label(err, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Looking for your face…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var verifyScanningView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.headline)
            }
            .foregroundStyle(.blue)

            if let live = controller.liveAnalysis {
                HStack(spacing: 14) {
                    Text("yaw: \(String(format: "%+.2f", live.yaw))").foregroundStyle(.secondary)
                    Text("roll: \(String(format: "%+.2f", live.roll))").foregroundStyle(.secondary)
                    Text("quality: \(String(format: "%.2f", live.quality))")
                        .foregroundStyle(live.quality >= FaceEnrollmentService.minimumCaptureQuality ? .green : .orange)
                }
                .font(.caption.monospacedDigit())
            } else if let err = controller.liveError {
                Label(err, systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Looking for your face…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let liveness = controller.liveLivenessState {
                HStack(spacing: 6) {
                    Image(systemName: liveness.isLive ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(liveness.isLive ? .green : .secondary)
                    if liveness.isLive {
                        Text("Liveness verified")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    } else if liveness.samplesCollected < liveness.minSamples {
                        Text("Liveness: collecting samples \(liveness.samplesCollected)/\(liveness.minSamples)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "Liveness: too still (yaw range %.3f, need %.3f)",
                                    liveness.yawRange, liveness.threshold))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let sim = controller.liveSimilarity {
                similarityProgressBar(sim: sim)
            }
        }
    }

    @ViewBuilder
    private func similarityProgressBar(sim: LiveSimilarity) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                Text(String(format: "centroid: %.3f", sim.centroid))
                    .foregroundStyle(sim.centroid >= sim.threshold ? .green : .primary)
                Text(String(format: "max: %.3f", sim.maxIndividual))
                    .foregroundStyle(sim.maxIndividual >= sim.threshold ? .green : .primary)
                Text(String(format: "thr: %.2f", sim.threshold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit())

            GeometryReader { geo in
                let centroidFrac = CGFloat(Swift.max(0.0, Swift.min(1.0, sim.centroid)))
                let thrFrac = CGFloat(Swift.max(0.0, Swift.min(1.0, sim.threshold)))
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.gray.opacity(0.2))
                    Rectangle()
                        .fill(sim.centroid >= sim.threshold ? Color.green : Color.orange)
                        .frame(width: geo.size.width * centroidFrac)
                    Rectangle()
                        .fill(Color.red.opacity(0.7))
                        .frame(width: 2)
                        .offset(x: geo.size.width * thrFrac - 1)
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func liveStatView(_ label: String, value: Float, satisfied: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(satisfied ? .green : .secondary)
            Text("\(label): \(String(format: "%+.2f", value))")
                .foregroundStyle(satisfied ? .green : .primary)
        }
    }

    // MARK: - Threshold slider (Face tab)

    @ViewBuilder
    private var thresholdSlider: some View {
        HStack(spacing: 8) {
            Text("Match threshold")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: $controller.matchThreshold, in: 0.45...0.95, step: 0.01)
                .frame(maxWidth: 200)
            Text(String(format: "%.2f", controller.matchThreshold))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Button("Reset") { controller.resetThreshold() }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
    }

    // MARK: - Controls (Face tab)

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if controller.isWorking && (currentEnrollmentPose != nil || controller.isVerifying) {
                Button("Cancel", role: .destructive) {
                    enrollmentTask?.cancel()
                    controller.cancelCurrentTask()
                }
            } else {
                Button {
                    let task = Task { await enroll() }
                    enrollmentTask = task
                } label: {
                    if controller.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Capture", systemImage: "camera.fill")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!actionsEnabled)

                Button {
                    controller.startVerifyOnly()
                } label: {
                    Label("Verify", systemImage: "magnifyingglass")
                }
                .disabled(!actionsEnabled)

                Button(role: .destructive) {
                    Task { await reset() }
                } label: {
                    Label("Reset", systemImage: "trash")
                }
                .disabled(controller.isWorking)
            }
        }
    }

    private var actionsEnabled: Bool {
        controller.camera.authorizationStatus == .authorized
        && !controller.isWorking
        && controller.service.isModelReady
    }

    // MARK: - Status label

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case .idle:
            Text(FaceEnrollmentService.hasEnrolledFace()
                 ? "A face is enrolled. Press Verify to scan or Run Unlock to test the full flow."
                 : "Press Capture to enroll. You'll be guided through 4 poses (straight, left, right, tilt).")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .enrolled(let report):
            VStack(spacing: 2) {
                Label("Enrolled \(report.savedEmbeddings) embeddings across 4 poses",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(report.savedURL.path)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

        case .verifiedAndLive(let result):
            VStack(spacing: 2) {
                Label("Match + liveness verified", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(String(format: "centroid: %.3f   max: %.3f   thr: %.2f   (vs %d)",
                            result.centroidSimilarity, result.maxIndividualSimilarity,
                            result.threshold, result.enrolledCount))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }

        case .noMatch(let result):
            VStack(spacing: 2) {
                Label("No match within \(Int(controller.verifyScanTimeoutSeconds))s",
                      systemImage: "xmark.seal.fill")
                    .foregroundStyle(.orange)
                Text(String(format: "best centroid: %.3f   best max: %.3f   thr: %.2f   (vs %d)",
                            result.centroidSimilarity, result.maxIndividualSimilarity,
                            result.threshold, result.enrolledCount))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }

        case .cancelled:
            Label("Cancelled.", systemImage: "xmark.circle").foregroundStyle(.secondary)

        case .info(let message):
            Label(message, systemImage: "info.circle")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)

        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }

    // MARK: - Enroll (pose-guided, gated by Touch ID / device password)

    private func enroll() async {
        // Gate enrollment behind device-owner auth so someone with brief physical
        // access to the unlocked Mac can't re-enroll their own face.
        guard await authenticate(reason: "Authenticate to enroll your face in FaceUnlock") else { return }

        // Enrollment writes encrypted embeddings, so the session key must be either
        // (a) already cached, (b) unwrapable via Touch ID, or (c) not-yet-created
        // (silent creation on first save). `ensureSessionUnlocked` covers all three.
        guard await controller.ensureSessionUnlocked(
            reason: "Unlock the session to encrypt your enrollment"
        ) else {
            controller.status = .failure("Session must be unlocked to save an encrypted enrollment.")
            return
        }

        controller.cancelCurrentTask()
        controller.isWorking = true
        controller.status = .idle
        totalCaptured = 0
        controller.liveAnalysis = nil
        controller.liveError = nil
        defer {
            controller.isWorking = false
            currentEnrollmentPose = nil
            poseProgress = (0, 0)
            controller.liveAnalysis = nil
            controller.liveError = nil
            currentPoseIndex = 0
            enrollmentTask = nil
        }

        var collected: [[Float]] = []
        let poses: [FacePose] = [
            .straight,
            .turnLeft, .turnRight,
            .rollLeft, .rollRight,
            .closer, .farther
        ]

        do {
            for (index, pose) in poses.enumerated() {
                currentPoseIndex = index
                currentEnrollmentPose = pose
                poseProgress = (0, framesPerPose)
                controller.liveAnalysis = nil
                controller.liveError = nil

                let embeddings = try await collectFrames(for: pose,
                                                         count: framesPerPose,
                                                         timeoutSeconds: perPoseTimeoutSeconds)
                collected.append(contentsOf: embeddings)
            }
            let url = try controller.service.saveEmbeddings(collected)
            // If saveEmbeddings just created a fresh session key (first-time use),
            // reflect the unlocked state in the UI.
            controller.refreshSetupState()
            controller.status = .enrolled(EnrollmentReport(savedURL: url, savedEmbeddings: collected.count))
        } catch is CancellationError {
            controller.status = .cancelled
        } catch {
            controller.status = .failure(error.localizedDescription)
        }
    }

    /// Prompts Touch ID / device password. Returns `true` only on explicit success.
    /// On cancel / failure / no biometry, updates the status and returns `false`.
    /// Used by all destructive / sensitive actions: Capture, Reset, Clear password.
    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            controller.status = .failure(
                "Authentication unavailable: \(policyError?.localizedDescription ?? "no biometry or password set on this Mac")"
            )
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if !success {
                controller.status = .failure("Authentication required.")
            }
            return success
        } catch let error as LAError where error.code == .userCancel || error.code == .systemCancel || error.code == .appCancel {
            controller.status = .cancelled
            return false
        } catch {
            controller.status = .failure("Authentication failed: \(error.localizedDescription)")
            return false
        }
    }

    private func collectFrames(for pose: FacePose, count: Int, timeoutSeconds: Double) async throws -> [[Float]] {
        var collected: [[Float]] = []
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while collected.count < count, Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: enrollmentPollIntervalNS)
            guard let frame = controller.camera.currentFrame() else { continue }

            do {
                let analysis = try controller.service.analyzeFrame(frame, includeQuality: true)
                controller.liveAnalysis = LiveAnalysis(
                    yaw: analysis.yaw,
                    roll: analysis.roll,
                    quality: analysis.quality,
                    faceWidth: analysis.face.boundingBox.width
                )
                controller.liveError = nil

                guard analysis.quality >= FaceEnrollmentService.minimumCaptureQuality else { continue }
                guard pose.matches(
                    yaw: analysis.yaw,
                    roll: analysis.roll,
                    faceWidth: analysis.face.boundingBox.width
                ) else { continue }

                collected.append(analysis.embedding)
                poseProgress = (collected.count, count)
                totalCaptured += 1
            } catch {
                controller.liveAnalysis = nil
                controller.liveError = (error as? FaceEnrollmentError)?.errorDescription ?? error.localizedDescription
                continue
            }
        }

        guard collected.count >= count else {
            throw FaceEnrollmentError.poseTimeout(pose)
        }
        return collected
    }

    // MARK: - Settings tab — Session-lock content

    @ViewBuilder
    private var sessionLockContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The password is encrypted at rest. Touch ID is required once per app launch to unwrap the session key. Auto-unlock won't work until then.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = controller.sessionUnlockError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Unlock Session Now") {
                    Task { await controller.unlockSession() }
                }
                Spacer()
            }
        }
    }

    // MARK: - Settings tab — Password content

    @ViewBuilder
    private var passwordContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: controller.hasStoredPassword ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(controller.hasStoredPassword ? .green : .orange)
                Text(controller.hasStoredPassword
                     ? "Password stored in Keychain"
                     : "No password stored")
                    .font(.callout)
                Spacer()
            }

            HStack(spacing: 8) {
                Button(controller.hasStoredPassword ? "Replace…" : "Set Password…") {
                    passwordMessage = nil
                    Task {
                        // If a key exists but the session is locked, prompt Touch ID
                        // BEFORE opening the sheet — otherwise the sheet's Save would
                        // fail with `.sessionLocked` and confuse the user.
                        let unlocked = await controller.ensureSessionUnlocked(
                            reason: "Authenticate to save your Mac password"
                        )
                        if unlocked {
                            showingPasswordSetup = true
                        } else {
                            passwordMessage = "Session unlock required to save the password."
                        }
                    }
                }
                if controller.hasStoredPassword {
                    Button("Test Read") {
                        Task { await testPasswordRead() }
                    }
                    .help("Read the password from Keychain (no prompt — face match is the auth).")
                    Button("Clear", role: .destructive) {
                        Task { await clearPassword() }
                    }
                }
                Spacer()
            }

            if let msg = passwordMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func testPasswordRead() async {
        // Password read requires the session key to be cached. If not, prompt for
        // Touch ID first so the user gets a coherent flow instead of a "session locked" error.
        guard await controller.ensureSessionUnlocked(
            reason: "Authenticate to read your stored Mac password"
        ) else {
            passwordMessage = "Read cancelled — session unlock required."
            return
        }
        passwordMessage = "Reading…"
        do {
            let byteCount = try await Task.detached(priority: .userInitiated) { () -> Int in
                var pw = try PasswordVault.readPassword()
                defer { pw.resetBytes(in: 0..<pw.count) }
                return pw.count
            }.value
            passwordMessage = "Read OK — \(byteCount) bytes returned."
        } catch {
            passwordMessage = "Read failed: \(error.localizedDescription)"
        }
    }

    private func clearPassword() async {
        guard await authenticate(reason: "Authenticate to clear the stored Mac password") else {
            passwordMessage = "Clear cancelled — authentication required."
            return
        }
        do {
            try PasswordVault.deletePassword()
            controller.refreshSetupState()
            passwordMessage = "Password cleared from Keychain."
        } catch {
            passwordMessage = "Clear failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings tab — Accessibility content

    @ViewBuilder
    private var accessibilityContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: controller.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(controller.accessibilityGranted ? .green : .orange)
                Text(controller.accessibilityGranted
                     ? "Granted — keystroke injection available"
                     : "Permission required for keystroke injection")
                    .font(.callout)
                Spacer()
            }

            HStack(spacing: 8) {
                if !controller.accessibilityGranted {
                    Button("Request Permission…") { requestAccessibility() }
                }
                Button("Re-check") {
                    controller.refreshSetupState()
                }
                Button(injectionCountdown > 0
                       ? "Typing in \(injectionCountdown)…"
                       : "Test Injection (5s delay)") {
                    Task { await testInjection() }
                }
                .disabled(!controller.accessibilityGranted || injectionCountdown > 0)
                Spacer()
            }

            if let msg = injectionMessage {
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func requestAccessibility() {
        let granted = KeystrokeInjector.promptForAccessibility()
        controller.accessibilityGranted = granted
        if !granted {
            injectionMessage = "macOS opened System Settings. Toggle FaceUnlock on under Privacy & Security → Accessibility, then click Re-check."
        }
    }

    private func testInjection() async {
        injectionMessage = "Focus a text field in another app (e.g. TextEdit) — typing in 5s…"
        injectionCountdown = 5
        for remaining in stride(from: 5, through: 1, by: -1) {
            injectionCountdown = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        injectionCountdown = 0

        do {
            let testBytes = Data("FaceUnlock test 123".utf8)
            try await Task.detached(priority: .userInitiated) {
                try KeystrokeInjector.typeAndReturn(testBytes)
            }.value
            injectionMessage = "Done. Did 'FaceUnlock test 123' + Return appear?"
        } catch {
            injectionMessage = "Injection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings tab — Auto-Unlock content

    @ViewBuilder
    private var autoUnlockContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auto-unlock when display wakes (while screen is locked)",
                   isOn: $controller.autoUnlockEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!controller.canAttemptUnlock)
                .help(controller.canAttemptUnlock
                      ? "When the display wakes from sleep and the screen is still locked, run face scan → liveness → password injection. Works even when the window is closed."
                      : "Enroll a face, save a password, and grant Accessibility first.")

            HStack(spacing: 6) {
                Text("Wait")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper(value: $controller.autoUnlockStartDelaySeconds, in: 0...30, step: 1) {
                    Text("\(Int(controller.autoUnlockStartDelaySeconds))s")
                        .font(.callout.monospacedDigit())
                        .frame(width: 28, alignment: .leading)
                }
                .controlSize(.small)
                .disabled(!controller.autoUnlockEnabled)
                Text("after display wake before camera turns on")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !controller.canAttemptUnlock {
                Label(controller.unlockReadinessHint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Activity tab — Screen status content

    @ViewBuilder
    private var screenStatusContent: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.lockMonitor.isScreenLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 24))
                .foregroundStyle(controller.lockMonitor.isScreenLocked ? .red : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.lockMonitor.isScreenLocked ? "Screen is locked" : "Screen is unlocked")
                    .font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Image(systemName: controller.lockMonitor.isMonitoring
                          ? "antenna.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .font(.caption)
                    Text(controller.lockMonitor.isMonitoring ? "Monitoring system events" : "Not monitoring")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Activity tab — Recent events content

    @ViewBuilder
    private var recentEventsContent: some View {
        if controller.lockMonitor.recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No events yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Press ⌃⌘Q to lock the screen — events will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(controller.lockMonitor.recentEvents.suffix(12).reversed()) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.kind.systemImage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .center)
                        Text(event.kind.description)
                            .font(.callout)
                        Spacer()
                        Text(Self.formattedTime(event.timestamp))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func formattedTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    // MARK: - Reset (gated by Touch ID / device password)

    private func reset() async {
        guard await authenticate(reason: "Authenticate to reset the enrolled face") else { return }
        do {
            let removed = try FaceEnrollmentService.deleteEnrolledFace()
            if removed.isEmpty {
                controller.status = .info("Nothing to reset — no enrolled face on disk.")
            } else {
                let names = removed.map { $0.lastPathComponent }.joined(separator: ", ")
                controller.status = .info("Reset complete. Removed: \(names)")
            }
        } catch {
            controller.status = .failure(error.localizedDescription)
        }
    }

    // MARK: - Pose component helpers

    private func yawSatisfied(_ pose: FacePose, yaw: Float) -> Bool {
        switch pose {
        case .straight:  return abs(yaw) < 0.12
        case .turnLeft:  return yaw < -0.15
        case .turnRight: return yaw >  0.15
        default:         return true   // yaw not the primary axis for this pose
        }
    }

    private func rollSatisfied(_ pose: FacePose, roll: Float) -> Bool {
        switch pose {
        case .straight:  return abs(roll) < 0.10
        case .rollLeft:  return roll < -0.15
        case .rollRight: return roll >  0.15
        default:         return true
        }
    }

    private func sizeSatisfied(_ pose: FacePose, faceWidth: CGFloat) -> Bool {
        switch pose {
        case .closer:  return faceWidth > 0.32
        case .farther: return faceWidth < 0.22
        default:       return true
        }
    }

    private static func poseUsesYaw(_ pose: FacePose) -> Bool {
        switch pose {
        case .straight, .turnLeft, .turnRight: return true
        default: return false
        }
    }

    private static func poseUsesRoll(_ pose: FacePose) -> Bool {
        switch pose {
        case .straight, .rollLeft, .rollRight: return true
        default: return false
        }
    }

    private static func poseUsesSize(_ pose: FacePose) -> Bool {
        switch pose {
        case .closer, .farther: return true
        default: return false
        }
    }
}

// MARK: - Password setup sheet

private struct PasswordSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    /// Called when the sheet dismisses. `true` if the password was saved.
    let onClose: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Mac password")
                .font(.title3.weight(.semibold))
            Text("Stored in macOS Keychain. Used to type your password into the lock screen after a successful face match.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Mac login password", text: $password)
            SecureField("Confirm password", text: $confirm)

            if password != confirm, !confirm.isEmpty {
                Label("Passwords don't match", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onClose(false)
                    dismiss()
                }
                .disabled(isSaving)
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || password.isEmpty || password != confirm)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        guard let passwordBytes = password.data(using: .utf8) else {
            errorMessage = "Could not encode password."
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                var localBytes = passwordBytes
                defer { localBytes.resetBytes(in: 0..<localBytes.count) }
                try PasswordVault.savePassword(localBytes)
            }.value
            onClose(true)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView(controller: AppController())
}
