import AVFoundation
import Flutter
import os.log

/// Audio capture service using AVAudioEngine.
/// Captures microphone audio at 16kHz mono 16-bit PCM (matching Android).
class AudioCaptureService: NSObject {
    static let shared = AudioCaptureService()

    private let log = OSLog(subsystem: "com.cribcall.cribcall", category: "audio_capture")

    private var audioEngine: AVAudioEngine?
    private var isCapturing = false
    private var eventSink: FlutterEventSink?
    private var packetCount = 0

    // Audio format: 16kHz mono 16-bit signed integer (matching Android)
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    // mDNS advertisement (passed from Dart, used for foreground-like behavior)
    private var mdnsAdvertisement: [String: Any]?

    private override init() {
        super.init()
    }

    // MARK: - Permission Handling

    func hasPermission() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - Capture Control

    func start(mdnsParams: [String: Any]? = nil) {
        if isCapturing {
            os_log("Already capturing", log: log, type: .info)
            return
        }

        mdnsAdvertisement = mdnsParams

        os_log("Starting audio capture", log: log, type: .info)

        do {
            // Configure audio session
            try AudioSessionManager.shared.configureForMonitoring()
            AudioSessionManager.shared.setupInterruptionHandling()

            // Create audio engine
            audioEngine = AVAudioEngine()
            guard let engine = audioEngine else {
                os_log("Failed to create audio engine", log: log, type: .error)
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            os_log(
                "Input format: sampleRate=%{public}.0f channels=%{public}d",
                log: log,
                type: .info,
                inputFormat.sampleRate,
                inputFormat.channelCount
            )

            // Create output format (16kHz mono)
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: targetChannels,
                interleaved: true
            ) else {
                os_log("Failed to create output format", log: log, type: .error)
                return
            }

            // Create converter for sample rate conversion if needed
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

            // Buffer size for 20ms at 16kHz = 320 samples
            let bufferSize: AVAudioFrameCount = 320

            // Install tap on input node
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: inputFormat
            ) { [weak self] buffer, time in
                self?.processAudioBuffer(buffer, converter: converter, outputFormat: outputFormat)
            }

            // Start the engine
            try engine.start()

            isCapturing = true
            packetCount = 0

            os_log("Audio capture started", log: log, type: .info)

        } catch {
            os_log(
                "Failed to start audio capture: %{public}@",
                log: log,
                type: .error,
                error.localizedDescription
            )
            stop()
        }
    }

    func stop() {
        os_log("Stopping audio capture", log: log, type: .info)

        isCapturing = false

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        mdnsAdvertisement = nil

        os_log("Audio capture stopped", log: log, type: .info)
    }

    // MARK: - Event Channel

    func setEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        outputFormat: AVAudioFormat
    ) {
        guard isCapturing, let sink = eventSink else { return }

        // If no conversion needed (already at target format), send directly
        guard let converter = converter else {
            sendPCMBuffer(inputBuffer)
            return
        }

        // Calculate output frame count based on sample rate ratio
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if status == .error {
            if let error = error {
                os_log(
                    "Conversion error: %{public}@",
                    log: log,
                    type: .error,
                    error.localizedDescription
                )
            }
            return
        }

        sendPCMBuffer(outputBuffer)
    }

    private func sendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let sink = eventSink else { return }

        // Get the raw bytes from the buffer
        guard let channelData = buffer.int16ChannelData else {
            // Try to get float data and convert
            if let floatData = buffer.floatChannelData {
                let frameLength = Int(buffer.frameLength)
                var int16Data = [Int16](repeating: 0, count: frameLength)

                for i in 0..<frameLength {
                    // Convert float (-1.0 to 1.0) to Int16 (-32768 to 32767)
                    let sample = floatData[0][i]
                    let clamped = max(-1.0, min(1.0, sample))
                    int16Data[i] = Int16(clamped * 32767)
                }

                let data = int16Data.withUnsafeBufferPointer { bufferPointer in
                    Data(buffer: bufferPointer)
                }

                packetCount += 1
                if packetCount == 1 || packetCount % 100 == 0 {
                    os_log(
                        "Audio packet #%{public}d (%{public}d bytes)",
                        log: log,
                        type: .info,
                        packetCount,
                        data.count
                    )
                }

                DispatchQueue.main.async {
                    sink(FlutterStandardTypedData(bytes: data))
                }
            }
            return
        }

        let frameLength = Int(buffer.frameLength)
        let data = Data(bytes: channelData[0], count: frameLength * 2) // 2 bytes per Int16

        packetCount += 1
        if packetCount == 1 || packetCount % 100 == 0 {
            os_log(
                "Audio packet #%{public}d (%{public}d bytes)",
                log: log,
                type: .info,
                packetCount,
                data.count
            )
        }

        DispatchQueue.main.async {
            sink(FlutterStandardTypedData(bytes: data))
        }
    }
}

// MARK: - Flutter Stream Handler

class AudioCaptureStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        AudioCaptureService.shared.setEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        AudioCaptureService.shared.setEventSink(nil)
        return nil
    }
}
