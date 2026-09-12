import AVFoundation
import Foundation

actor Recorder {
    struct Session: Sendable, Equatable {
        let id: UUID
        let url: URL
    }

    private var recorder: AVAudioRecorder?
    private var session: Session?

    func start(id: UUID) throws -> Session {
        stopCurrent()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lossless-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: destination, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
        let session = Session(id: id, url: destination)
        self.session = session
        return session
    }

    func level() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        return max(0, min(1, (decibels + 55) / 55))
    }

    @discardableResult
    func stop(id: UUID) -> URL? {
        guard session?.id == id else { return nil }
        return stopCurrent()
    }

    @discardableResult
    private func stopCurrent() -> URL? {
        recorder?.stop()
        recorder = nil
        defer { session = nil }
        return session?.url
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
