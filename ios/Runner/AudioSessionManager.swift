import AVFoundation
import os.log

/// Manages AVAudioSession configuration for CribCall.
/// Handles different audio modes for monitoring and listening roles.
class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "audio_session")
    private var isConfigured = false

    private init() {}

    /// Configure audio session for monitoring (capturing audio from microphone).
    /// Uses playAndRecord category for potential two-way communication.
    func configureForMonitoring() throws {
        let session = AVAudioSession.sharedInstance()

        os_log("Configuring audio session for monitoring", log: log, type: .info)

        do {
            // Use playAndRecord for potential two-way audio
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers]
            )

            // Set preferred sample rate to 16kHz (matching Android)
            try session.setPreferredSampleRate(16000)

            // Set preferred buffer duration for low latency
            try session.setPreferredIOBufferDuration(0.02) // 20ms

            try session.setActive(true, options: [])

            isConfigured = true
            os_log(
                "Audio session configured for monitoring: sampleRate=%{public}.0f",
                log: log,
                type: .info,
                session.sampleRate
            )
        } catch {
            os_log(
                "Failed to configure audio session for monitoring: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            throw error
        }
    }

    /// Configure audio session for listening (playing received audio).
    func configureForListening() throws {
        let session = AVAudioSession.sharedInstance()

        os_log("Configuring audio session for listening", log: log, type: .info)

        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )

            try session.setActive(true, options: [])

            isConfigured = true
            os_log("Audio session configured for listening", log: log, type: .info)
        } catch {
            os_log(
                "Failed to configure audio session for listening: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            throw error
        }
    }

    /// Deactivate the audio session.
    func deactivate() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            isConfigured = false
            os_log("Audio session deactivated", log: log, type: .info)
        } catch {
            os_log(
                "Failed to deactivate audio session: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
        }
    }

    /// Handle audio session interruptions (phone calls, other apps).
    func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            os_log("Audio session interrupted", log: log, type: .info)
            // Audio capture will be paused automatically

        case .ended:
            os_log("Audio session interruption ended", log: log, type: .info)
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume audio session
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        os_log("Audio session resumed after interruption", log: log, type: .info)
                    } catch {
                        os_log(
                            "Failed to resume audio session: %{public}@",
                            log: log,
                            type: .error,
                            error.localizedDescription
                        )
                    }
                }
            }

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            os_log("New audio device available", log: log, type: .info)
        case .oldDeviceUnavailable:
            os_log("Audio device unavailable", log: log, type: .info)
        case .categoryChange:
            os_log("Audio category changed", log: log, type: .info)
        default:
            break
        }
    }
}
