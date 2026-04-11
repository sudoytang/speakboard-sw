import AVFoundation
import CoreAudio

// Streams real-time PCM i16 LE audio at 16 kHz mono to the provided onChunk callback.
// Each call to onChunk delivers a Data blob containing raw 16-bit signed little-endian samples.
//
// LATENCY NOTE: Call warmUp() once after mic permission is granted to pre-start the
// AVAudioEngine.  Subsequent startRecording() calls open a gate on the already-running
// tap instead of rebuilding the engine chain, eliminating the ~200 ms startup delay.
final class AudioRecorder {

    private struct InputFormatKey: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormatRawValue: Int
        let isInterleaved: Bool

        init(_ format: AVAudioFormat) {
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            commonFormatRawValue = Int(format.commonFormat.rawValue)
            isInterleaved = format.isInterleaved
        }
    }

    private struct HardwareListener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private(set) var isRecording = false

    /// Called on the AVAudioEngine internal thread with raw i16 LE PCM at 16 kHz mono.
    var onChunk: ((Data) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterInputFormat: InputFormatKey?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var audioChainDirty = true
    private var engineConfigObserver: NSObjectProtocol?
    private var hardwareListeners: [HardwareListener] = []

    init() {
        registerHardwareListeners()
    }

    deinit {
        unregisterHardwareListeners()
        removeEngineObserver()
    }

    // MARK: - Public

    /// Pre-start the audio engine so the first startRecording() is instant.
    /// Safe to call multiple times; no-op if already warm.
    func warmUp() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.engine == nil || self.audioChainDirty else { return }
                do {
                    try self.buildAndStartEngine()
                } catch {
                    print("[recorder] warmUp failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Tear down the warmed-up engine when low-latency startup is not needed.
    func coolDown() {
        guard !isRecording else { return }
        teardownEngine()
        audioChainDirty = true
    }

    /// Request microphone permission if needed, then start capturing audio.
    func startRecording(completion: @escaping (Error?) -> Void) {
        guard !isRecording else { completion(nil); return }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    completion(NSError(domain: "AudioRecorder", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Microphone access denied."]))
                    return
                }
                guard let self else { return }
                do {
                    // Rebuild only if the chain is dirty or engine was never started.
                    if self.engine == nil || self.audioChainDirty || !(self.engine?.isRunning ?? false) {
                        try self.buildAndStartEngine()
                    }
                    // Open the gate — tap is already running.
                    self.isRecording = true
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    /// Stop capturing. The engine keeps running so the next startRecording() is instant.
    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        // Do NOT remove the tap or stop the engine — keep it warm for the next session.
        // If the audio chain became dirty while recording, rebuild it now.
        if audioChainDirty {
            teardownEngine()
            // Re-warm immediately so it is ready for the next session.
            do { try buildAndStartEngine() } catch {
                print("[recorder] re-warm after dirty stop failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    /// Build (or rebuild) the engine, install the tap, and start the engine.
    private func buildAndStartEngine() throws {
        teardownEngine()

        let engine = AVAudioEngine()
        self.engine = engine
        audioChainDirty = false

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.markAudioChainDirty()
        }

        let inputNode = engine.inputNode

        // format: nil lets AVAudioEngine use the native hardware format,
        // avoiding tap-format-mismatch crashes with Bluetooth devices.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] inBuf, _ in
            guard let self, self.isRecording,       // gate: only forward when active
                  let conv = self.converter(for: inBuf.format) else { return }

            let ratio = self.outputFormat.sampleRate / inBuf.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outputFormat,
                                                frameCapacity: outCapacity) else { return }

            var inputConsumed = false
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                inputConsumed = true
                return inBuf
            }

            guard status != .error, outBuf.frameLength > 0 else { return }

            let data = Self.toI16LE(outBuf)
            if !data.isEmpty { self.onChunk?(data) }
        }

        try engine.start()
    }

    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        let key = InputFormatKey(inputFormat)
        if converterInputFormat == key, let converter {
            return converter
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("[recorder] cannot create audio converter for input format: \(inputFormat)")
            return nil
        }
        self.converter = converter
        converterInputFormat = key
        return converter
    }

    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        removeEngineObserver()
        engine = nil
        converter = nil
        converterInputFormat = nil
    }

    private func markAudioChainDirty() {
        audioChainDirty = true
        converter = nil
        converterInputFormat = nil

        if !isRecording {
            teardownEngine()
        }
    }

    private func registerHardwareListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.markAudioChainDirty()
            }

            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )

            if status == noErr {
                hardwareListeners.append(HardwareListener(address: address, block: block))
            } else {
                print("[recorder] failed to add hardware listener: \(status)")
            }
        }
    }

    private func unregisterHardwareListeners() {
        for listener in hardwareListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener.block
            )
        }
        hardwareListeners.removeAll()
    }

    private func removeEngineObserver() {
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigObserver = nil
        }
    }

    // MARK: - Float32 mono → i16 LE

    private static func toI16LE(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let channels = buffer.floatChannelData else { return Data() }
        let n = Int(buffer.frameLength)
        var data = Data(count: n * 2)
        data.withUnsafeMutableBytes { ptr in
            let p = ptr.baseAddress!.assumingMemoryBound(to: Int16.self)
            for i in 0..<n {
                let clamped = max(-1.0, min(1.0, channels[0][i]))
                p[i] = Int16(clamped * 32_767)
            }
        }
        return data
    }
}
