import AppKit
import AVFoundation
import Observation
import SwiftUI
import GrokCore

/// Only one microphone capture may be active across the main and quick inputs.
@MainActor @Observable final class VoiceDictation: NSObject, AVAudioRecorderDelegate {
    static let shared = VoiceDictation()
    private(set) weak var owner: ChatStore?
    private(set) var startedAt: Date?
    @ObservationIgnored private var captureID: UUID?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var completion: CheckedContinuation<Data, Error>?
    @ObservationIgnored private var directory: URL?

    func start(in store: ChatStore) {
        guard owner == nil, store.canDictate else { return }
        let id = UUID()
        captureID = id
        owner = store
        store.startDictation { try await self.record(id: id) }
    }

    func stop(in store: ChatStore) {
        guard owner === store, let recorder else { return }
        recorder.stop()
        finish(recorder, successfully: true)
    }

    func cancel(in store: ChatStore) {
        store.cancelDictation()
        if owner === store, let id = captureID { cancelCapture(id: id) }
    }

    func stop() {
        if let owner { cancel(in: owner) }
    }

    private func record(id: UUID) async throws -> Data {
        defer { if captureID == id { cleanUp() } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard captureID == id else { throw CancellationError() }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: allowed = false
            }
            try Task.checkCancellation()
            guard captureID == id else { throw CancellationError() }
            guard allowed else { throw DictationError.microphoneDenied }
            guard AVCaptureDevice.default(for: .audio) != nil else { throw DictationError.noMicrophone }

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftyGrok-Dictation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            directory = folder
            let url = folder.appendingPathComponent("Recording.m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            self.recorder = recorder
            recorder.delegate = self
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                // Bound both microphone use and the size of the request to Grok.
                guard recorder.record(forDuration: 300) else {
                    finish(recorder, successfully: false)
                    return
                }
                startedAt = Date()
            }
        } onCancel: {
            Task { @MainActor in self.cancelCapture(id: id) }
        }
    }

    private func finish(_ recorder: AVAudioRecorder, successfully: Bool) {
        guard self.recorder === recorder, let completion else { return }
        self.completion = nil
        let result: Result<Data, Error>
        do {
            guard successfully else { throw DictationError.recordingFailed }
            let size = try recorder.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 5 * 1024 * 1024 else { throw DictationError.recordingFailed }
            result = .success(try Data(contentsOf: recorder.url))
        } catch { result = .failure(error) }
        cleanUp()
        completion.resume(with: result)
    }

    private func cancelCapture(id: UUID) {
        guard captureID == id else { return }
        let completion = completion
        self.completion = nil
        cleanUp()
        completion?.resume(throwing: CancellationError())
    }

    private func cleanUp() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        captureID = nil
        owner = nil
        startedAt = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finish(recorder, successfully: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.finish(recorder, successfully: false) }
    }
}

private enum DictationError: LocalizedError, SystemPermissionError {
    case microphoneDenied, noMicrophone, recordingFailed
    var systemPermission: SystemPermission? {
        if case .microphoneDenied = self { return .microphone }
        return nil
    }
    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return L10n.text("Allow microphone access for SwiftyGrok in System Settings → Privacy & Security → Microphone.")
        case .noMicrophone: return L10n.text("No microphone is available.")
        case .recordingFailed: return L10n.text("Could not record audio. Check your microphone and try again.")
        }
    }
}

@MainActor struct DictationButton: View {
    let store: ChatStore
    private var dictation: VoiceDictation { .shared }
    private var title: String {
        if !store.isDictating { return L10n.text("Dictate a message") }
        if dictation.owner === store, dictation.startedAt != nil { return L10n.text("Finish dictation") }
        return L10n.text("Cancel dictation")
    }

    var body: some View {
        Button {
            if store.isTranscribing { dictation.cancel(in: store) }
            else if store.isDictating, dictation.startedAt != nil { dictation.stop(in: store) }
            else if store.isDictating { dictation.cancel(in: store) }
            else { dictation.start(in: store) }
        } label: {
            Group {
                if store.isDictating, store.isTranscribing || dictation.owner !== store || dictation.startedAt == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: store.isDictating ? "stop.fill" : "mic")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(store.isDictating ? Color.red : .primary)
                }
            }
            .frame(width: 30, height: 30)
            .background(.primary.opacity(0.06), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .disabled(!store.isDictating && (!store.canDictate || dictation.owner != nil))
    }
}

@MainActor struct DictationStatus: View {
    let store: ChatStore
    private var dictation: VoiceDictation { .shared }

    var body: some View {
        HStack(spacing: 8) {
            if store.isTranscribing {
                ProgressView().controlSize(.small)
                Text(L10n.text("Transcribing with Grok…"))
            } else if dictation.owner === store, let startedAt = dictation.startedAt {
                Image(systemName: "waveform").foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text(L10n.text("Recording…"))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = min(300, max(0, Int(context.date.timeIntervalSince(startedAt))))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                }
            } else {
                ProgressView().controlSize(.small)
                Text(L10n.text("Accessing microphone…"))
            }
            Spacer(minLength: 0)
            Button { dictation.cancel(in: store) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).help(L10n.text("Cancel dictation"))
            .accessibilityLabel(L10n.text("Cancel dictation"))
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 4)
    }
}
