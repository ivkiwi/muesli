import AppKit
import CoreAudio
import Foundation
import os

@MainActor
final class MeetingMonitor {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingDetection")
    private static let evaluationInterval: UInt64 = 3_000_000_000

    var calendarEventProvider: (() -> CalendarEventContext?)?
    var detectionEnabledProvider: (() -> Bool)?
    var isRecordingProvider: (() -> Bool)?
    var isStartingRecordingProvider: (() -> Bool)?
    var isCalendarNotificationVisibleProvider: (() -> Bool)?
    var promptVisibilityProvider: (() -> MeetingPromptVisibility)?
    var mutedDetectionBundleIDsProvider: (() -> Set<String>)?
    var onPromptCandidateChanged: ((MeetingCandidate?) -> Void)?

    private let resolver = MeetingCandidateResolver()
    private let signalCollector = MeetingSignalCollector()
    private let cameraMonitor = CameraActivityMonitor()
    private let sensorAttributionMonitor = ControlCenterSensorAttributionMonitor()
    private let promptState = MeetingPromptStateMachine()

    private var micListenerDeviceID: AudioDeviceID = 0
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var periodicEvaluationTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var pendingEvaluation = false
    private var workspaceObserver: NSObjectProtocol?
    private var globalSuppressUntil: Date?
    private var lastLoggedCandidateID: String?
    private var lastSuppressionLogKey: String?

    func start() {
        installMicListener()
        installDeviceChangeListener()
        installWorkspaceActivationObserver()

        cameraMonitor.onCameraStateChanged = { [weak self] _ in
            self?.scheduleEvaluation()
        }
        cameraMonitor.start()

        sensorAttributionMonitor.onAttributionsChanged = { [weak self] in
            DispatchQueue.main.async { self?.scheduleEvaluation() }
        }
        sensorAttributionMonitor.start()

        installPeriodicEvaluationLoop()
        scheduleEvaluation()
    }

    func stop() {
        removeMicListener()
        removeDeviceChangeListener()
        removeWorkspaceActivationObserver()
        cameraMonitor.stop()
        sensorAttributionMonitor.stop()
        periodicEvaluationTask?.cancel()
        periodicEvaluationTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        pendingEvaluation = false
    }

    func refreshState() {
        scheduleEvaluation()
    }

    func suppress(for duration: TimeInterval = 120) {
        globalSuppressUntil = Date().addingTimeInterval(duration)
        dismissVisiblePromptForSuppression()
    }

    func suppressWhileActive() {
        globalSuppressUntil = .distantFuture
        dismissVisiblePromptForSuppression()
    }

    func resumeAfterCooldown() {
        globalSuppressUntil = Date().addingTimeInterval(15)
    }

    func markPromptShown(_ candidate: MeetingCandidate) {
        promptState.markShown(candidate)
    }

    func markPromptAutoDismissed(_ candidate: MeetingCandidate) {
        promptState.markAutoDismissed(candidate)
        log("prompt_auto_dismissed id=\(candidate.id)")
    }

    func markPromptUserDismissed(_ candidate: MeetingCandidate) {
        promptState.markUserDismissed(candidate)
        log("prompt_suppressed id=\(candidate.id) reason=user_dismissed")
    }

    func markPromptClosed(_ candidate: MeetingCandidate) {
        promptState.markClosed(candidate)
    }

    func markRecordingStarted(_ candidate: MeetingCandidate?) {
        if let candidate {
            log("recording_started id=\(candidate.id)")
        } else {
            log("recording_started")
        }
    }

    private func dismissVisiblePromptForSuppression() {
        promptState.resetVisiblePrompt()
        onPromptCandidateChanged?(nil)
    }

    private func scheduleEvaluation() {
        guard detectionEnabledProvider?() ?? true else {
            dismissVisiblePromptForSuppression()
            return
        }

        if evaluationTask != nil {
            pendingEvaluation = true
            return
        }

        evaluationTask = Task { [weak self] in
            await self?.runScheduledEvaluations()
        }
    }

    private func runScheduledEvaluations() async {
        repeat {
            pendingEvaluation = false
            await evaluateNow()
        } while pendingEvaluation && !Task.isCancelled
        evaluationTask = nil
    }

    private func evaluateNow() async {
        let now = Date()
        let visibility = promptVisibilityProvider?() ?? MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil)
        cameraMonitor.refresh()
        let sensorAttributions = sensorAttributionMonitor.snapshot(now: now)
        let collectedSignals = await signalCollector.collect(micDeviceID: micListenerDeviceID)
        guard !Task.isCancelled else { return }
        let audioInputProcesses = mergedAudioInputProcesses(
            collectedSignals.audioInputProcesses,
            sensorAttributions: sensorAttributions,
            runningProcessIDsByBundleID: collectedSignals.runningProcessIDsByBundleID
        )
        let micActive = collectedSignals.micActive || !audioInputProcesses.isEmpty || !sensorAttributions.micBundleIDs.isEmpty
        let cameraActive = cameraMonitor.isCameraActive || !sensorAttributions.cameraBundleIDs.isEmpty

        let snapshot = MeetingSignalSnapshot(
            micActive: micActive,
            cameraActive: cameraActive,
            calendarEvent: calendarEventProvider?(),
            runningApps: collectedSignals.runningApps,
            browserMeetings: collectedSignals.browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: collectedSignals.foregroundBundleID,
            now: now
        )

        let resolvedCandidate = isGloballySuppressed(now: now) ? nil : resolver.resolve(snapshot)
        let candidate = isMuted(resolvedCandidate) ? nil : resolvedCandidate
        logCandidateIfChanged(candidate)

        let decision = promptState.evaluate(
            candidate: candidate,
            detectionEnabled: detectionEnabledProvider?() ?? true,
            isRecording: isRecordingProvider?() ?? false,
            isStartingRecording: isStartingRecordingProvider?() ?? false,
            isCalendarNotificationVisible: isCalendarNotificationVisibleProvider?() ?? false,
            visibility: visibility,
            now: now
        )

        switch decision.action {
        case .show:
            guard let candidate = decision.candidate else { return }
            log("prompt_shown id=\(candidate.id) platform=\(candidate.platform.displayName) app=\(candidate.appName)")
            onPromptCandidateChanged?(candidate)
        case .hide:
            onPromptCandidateChanged?(nil)
        case .none:
            logSuppressionIfNeeded(decision)
        }
    }

    private func isGloballySuppressed(now: Date) -> Bool {
        guard let until = globalSuppressUntil else { return false }
        if now >= until {
            globalSuppressUntil = nil
            return false
        }
        return true
    }

    private func isMuted(_ candidate: MeetingCandidate?) -> Bool {
        guard let sourceBundleID = candidate?.sourceBundleID else { return false }
        return mutedDetectionBundleIDsProvider?().contains(sourceBundleID) ?? false
    }

    private func logCandidateIfChanged(_ candidate: MeetingCandidate?) {
        guard candidate?.id != lastLoggedCandidateID else { return }
        lastLoggedCandidateID = candidate?.id
        if let candidate {
            log("candidate_detected id=\(candidate.id) platform=\(candidate.platform.displayName) app=\(candidate.appName)")
        }
    }

    private func logSuppressionIfNeeded(_ decision: MeetingPromptDecision) {
        guard let candidate = decision.candidate else {
            lastSuppressionLogKey = nil
            return
        }
        let key = "\(candidate.id):\(decision.reason)"
        guard key != lastSuppressionLogKey else { return }
        lastSuppressionLogKey = key
        switch decision.reason {
        case .autoDismissedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=auto_dismissed")
        case .userDismissedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=user_dismissed")
        case .calendarNotificationVisible:
            log("prompt_suppressed id=\(candidate.id) reason=calendar_notification_visible")
        case .recording:
            log("prompt_suppressed id=\(candidate.id) reason=recording")
        default:
            break
        }
    }

    private func installPeriodicEvaluationLoop() {
        periodicEvaluationTask?.cancel()
        periodicEvaluationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.evaluationInterval)
                self?.scheduleEvaluation()
            }
        }
    }

    private func installWorkspaceActivationObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleEvaluation()
            }
        }
    }

    private func removeWorkspaceActivationObserver() {
        guard let workspaceObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        self.workspaceObserver = nil
    }

    private func mergedAudioInputProcesses(
        _ coreAudioProcesses: [AudioProcessActivity],
        sensorAttributions: SensorAttributionSnapshot,
        runningProcessIDsByBundleID: [String: pid_t]
    ) -> [AudioProcessActivity] {
        var processes = coreAudioProcesses
        let existingBundleIDs = Set(coreAudioProcesses.map(\.bundleID))

        for bundleID in sensorAttributions.micBundleIDs.sorted() {
            guard let appName = MeetingCandidateResolver.browserApps[bundleID] else { continue }
            guard !existingBundleIDs.contains(bundleID),
                  !existingBundleIDs.contains(where: { helperBundleID in
                      helperBundleID.lowercased().hasPrefix("\(bundleID.lowercased()).")
                  }) else {
                continue
            }

            processes.append(AudioProcessActivity(
                pid: runningProcessIDsByBundleID[bundleID] ?? 0,
                bundleID: bundleID,
                appName: appName,
                isRunningInput: true,
                isRunningOutput: false
            ))
        }

        return processes
    }

    private func installMicListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return }

        micListenerDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleEvaluation() }
        }
        micListenerBlock = block

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, nil, block)
    }

    private func removeMicListener() {
        guard micListenerDeviceID != 0, let block = micListenerBlock else { return }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &runningAddress, nil, block)
        micListenerDeviceID = 0
        micListenerBlock = nil
    }

    private func installDeviceChangeListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.removeMicListener()
                self?.installMicListener()
                self?.scheduleEvaluation()
            }
        }
        deviceChangeListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        deviceChangeListenerBlock = nil
    }

    private func log(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        fputs("[meeting-monitor] \(message)\n", stderr)
    }
}

private struct MeetingCollectedSignals {
    let micActive: Bool
    let runningApps: [RunningAppInfo]
    let browserMeetings: [BrowserMeetingContext]
    let audioInputProcesses: [AudioProcessActivity]
    let foregroundBundleID: String?
    let runningProcessIDsByBundleID: [String: pid_t]
}

private actor MeetingSignalCollector {
    private let browserCollector = BrowserMeetingActivityCollector()
    private let audioProcessCollector = AudioProcessAttributionCollector()

    func collect(micDeviceID: AudioDeviceID) async -> MeetingCollectedSignals {
        let runningAppSnapshots = currentRunningApps()
        let browserMeetings = await browserCollector.collect(runningApps: runningAppSnapshots)

        return MeetingCollectedSignals(
            micActive: isMicActive(deviceID: micDeviceID),
            runningApps: runningAppSnapshots.map {
                RunningAppInfo(bundleID: $0.bundleID, isActive: $0.isActive)
            },
            browserMeetings: browserMeetings,
            audioInputProcesses: audioProcessCollector.activeInputProcesses(),
            foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            runningProcessIDsByBundleID: runningProcessIDsByBundleID(from: runningAppSnapshots)
        )
    }

    private func currentRunningApps() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppSnapshot(
                bundleID: bundleID,
                appName: app.localizedName ?? MeetingCandidateResolver.browserApps[bundleID] ?? bundleID,
                processIdentifier: app.processIdentifier,
                isActive: app.isActive
            )
        }
    }

    private func runningProcessIDsByBundleID(from apps: [RunningAppSnapshot]) -> [String: pid_t] {
        var processIDs: [String: pid_t] = [:]
        for app in apps where processIDs[app.bundleID] == nil {
            processIDs[app.bundleID] = app.processIdentifier
        }
        return processIDs
    }

    private func isMicActive(deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }

        var isRunning: UInt32 = 0
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &runningAddress,
            0,
            nil,
            &size,
            &isRunning
        ) == noErr else { return false }

        return isRunning != 0
    }
}
