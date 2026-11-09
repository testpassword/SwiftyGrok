import SwiftUI
import AppKit
import AVFoundation
import PhotosUI
import CoreTransferable
import Quartz
import UniformTypeIdentifiers
import GrokCore

@MainActor struct AttachmentPickerButton: View {
    let store: ChatStore
    let chooseFiles: () -> Void
    @State private var presented = false
    @State private var showPhotos = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var body: some View {
        Button { presented.toggle() } label: {
            Group {
                if store.isReadingFiles { ProgressView().controlSize(.small).frame(width: 30, height: 30) }
                else { Image(systemName: "plus").font(.system(size: 18, weight: .medium)).frame(width: 30, height: 30) }
            }
            .background(.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain).contentShape(Circle())
        .help(L10n.text("Attach files")).accessibilityLabel(L10n.text("Attach files"))
        .disabled(!store.canAttachFiles)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                AttachmentMenuRow(title: L10n.text("Camera"), symbol: "camera",
                                  enabled: CameraAttachmentCapture.isAvailable) { select(.camera) }
                    .help(CameraAttachmentCapture.isAvailable ? L10n.text("Take a photo") : L10n.text("No camera is available"))
                AttachmentMenuRow(title: L10n.text("Photos"), symbol: "photo.on.rectangle") { select(.photos) }
                AttachmentMenuRow(title: L10n.text("Files"), symbol: "doc") { select(.files) }
            }
            .padding(8).frame(width: 230)
        }
        .photosPicker(isPresented: $showPhotos, selection: $selectedPhotos,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            importPhotos(items)
        }
        .onChange(of: store.canAttachFiles) { _, allowed in
            if !allowed { presented = false }
        }
    }

    private enum Source { case camera, photos, files }

    private func select(_ source: Source) {
        presented = false
        // Finish dismissing the popover before opening the system picker.
        DispatchQueue.main.async {
            guard store.canAttachFiles else { return }
            switch source {
            case .camera: importCameraPhoto()
            case .photos: showPhotos = true
            case .files: chooseFiles()
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        Task {
            var temporaryFiles: [URL] = []
            defer { temporaryFiles.forEach(TemporaryPhoto.remove) }
            // Reserve the draft before downloading from iCloud or loading a photo.
            // ChatStore rejects the result if the user switches chats meanwhile.
            await store.importFiles(resolvingURLs: {
                for item in items {
                    try Task.checkCancellation()
                    guard let photo = try await item.loadTransferable(type: TemporaryPhoto.self) else {
                        throw AttachmentPickerError.photoUnavailable
                    }
                    temporaryFiles.append(photo.url)
                }
                return temporaryFiles
            })
        }
    }

    private func importCameraPhoto() {
        Task {
            var file: URL?
            defer { if let file { TemporaryPhoto.remove(file) } }
            await store.importFiles(resolvingURLs: {
                file = try await CameraAttachmentCapture.shared.capture()
                return file.map { [$0] } ?? []
            })
        }
    }
}

@MainActor private struct AttachmentMenuRow: View {
    let title: String
    let symbol: String
    var enabled = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(.primary.opacity(0.07), in: Circle())
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(8).contentShape(Rectangle())
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(hovered && enabled ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .onHover { hovered = $0 }
    }
}

/// Keep a provider's temporary file alive until the existing file reader finishes.
private struct TemporaryPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let directory = try makeDirectory()
            let url = directory.appendingPathComponent(received.file.lastPathComponent)
            do { try FileManager.default.copyItem(at: received.file, to: url) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            return TemporaryPhoto(url: url)
        }
    }

    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// AppKit provides native live camera preview, capture, confirmation and cancel.
@MainActor private final class CameraAttachmentCapture: NSObject {
    static let shared = CameraAttachmentCapture()
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
    private var isCapturing = false
    private var continuation: CheckedContinuation<URL?, Error>?

    func capture() async throws -> URL? {
        guard !isCapturing else { throw AttachmentPickerError.cameraBusy }
        guard Self.isAvailable else { throw AttachmentPickerError.noCamera }
        isCapturing = true
        defer { isCapturing = false }
        NSApp.activate(ignoringOtherApps: true)
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw AttachmentPickerError.cameraDenied }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = IKPictureTaker.pictureTaker()!
            picker.setInputImage(nil)
            picker.setValue(true, forKey: IKPictureTakerAllowsVideoCaptureKey)
            picker.setValue(false, forKey: IKPictureTakerAllowsFileChoosingKey)
            picker.setValue(false, forKey: IKPictureTakerShowRecentPictureKey)
            picker.setValue(false, forKey: IKPictureTakerUpdateRecentPictureKey)
            picker.setValue(false, forKey: IKPictureTakerAllowsEditingKey)
            picker.setValue(false, forKey: IKPictureTakerShowEffectsKey)
            picker.setValue(L10n.text("Take a photo"), forKey: IKPictureTakerInformationalTextKey)
            picker.level = .floating
            picker.begin(withDelegate: self, didEnd: #selector(didEnd(_:returnCode:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func didEnd(_ picker: IKPictureTaker, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        guard let continuation else { return }
        self.continuation = nil
        guard returnCode == NSApplication.ModalResponse.OK.rawValue else {
            continuation.resume(returning: nil)
            return
        }
        do {
            guard let tiff = picker.outputImage()?.tiffRepresentation,
                  let image = NSBitmapImageRep(data: tiff),
                  let png = image.representation(using: .png, properties: [:]) else {
                throw AttachmentPickerError.photoUnavailable
            }
            let directory = try TemporaryPhoto.makeDirectory()
            let file = directory.appendingPathComponent("Camera.png")
            do { try png.write(to: file, options: .atomic) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            continuation.resume(returning: file)
        } catch { continuation.resume(throwing: error) }
    }
}

private enum AttachmentPickerError: LocalizedError, SystemPermissionError {
    case photoUnavailable, cameraDenied, noCamera, cameraBusy

    var systemPermission: SystemPermission? {
        if case .cameraDenied = self { return .camera }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .photoUnavailable: return L10n.text("Could not load the photo. Please try again.")
        case .cameraDenied: return L10n.text("Allow camera access for SwiftyGrok in System Settings → Privacy & Security → Camera.")
        case .noCamera: return L10n.text("No camera is available")
        case .cameraBusy: return L10n.text("The camera picker is already open.")
        }
    }
}
