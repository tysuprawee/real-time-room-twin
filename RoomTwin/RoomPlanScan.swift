import ARKit
import RoomPlan
import SceneKit
import SwiftUI

/// Room layout scanning with Apple's RoomPlan, the alternative to the
/// detailed mesh: walls, doors, windows and labelled furniture. The finished
/// room becomes a mesh (RoomPlanMesh) so it opens in the same preview and
/// exports the same way, plus RoomPlan's own JSON. Exports go to
/// Documents/RoomPlan-<time>/.
@MainActor
final class RoomPlanScan: ObservableObject {
    struct CleanFurnitureIndicator: Identifiable {
        let id: UUID
        /// Rectangle in normalized RoomCaptureView coordinates.
        let rect: CGRect
        let state: FurniturePhotoState
    }

    enum Phase: Equatable {
        case idle, capturing, processing, done
    }

    @Published private(set) var phase = Phase.idle
    /// Apple's live view, while a scan is open.
    @Published private(set) var captureView: RoomCaptureView?
    @Published private(set) var preview: PreviewScene?
    @Published private(set) var isPreviewOpen = false
    @Published private(set) var isExporting = false
    @Published private(set) var isSavingToAccount = false
    @Published private(set) var isSavedToAccount = false
    @Published private(set) var isPreparingPreview = false
    @Published private(set) var isCleanMode = false
    @Published private(set) var cleanPhotoSummary: String?
    @Published private(set) var cleanCanCapture = false
    @Published private(set) var cleanFurnitureIndicators: [CleanFurnitureIndicator] = []
    @Published private(set) var cleanProgress: SAMFurnitureProgress?
    @Published var exportedFile: ExportedFile?
    @Published var errorMessage: String?
    /// What RoomPlan found, e.g. "4 walls · 2 doors · 1 window · 5 objects".
    @Published private(set) var summary: String?

    private var room: CapturedRoom?
    private var mesh: MeshSnapshot?
    private var viewer: simd_float4x4?
    private let delegate = CaptureDelegate()
    private var cleanRecorder: KeyframeRecorder?
    private var cleanFrameTimer: Timer?
    private weak var cleanAccount: Account?
    private var cleanObjects: [CapturedRoom.Object] = []
    private var cleanFurnitureStates: [UUID: FurniturePhotoState] = [:]

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    var isBusy: Bool { phase == .capturing || phase == .processing || isExporting || isSavingToAccount || isPreparingPreview }

    func start() {
        begin(clean: false, account: nil)
    }

    /// Clean uses RoomPlan's complete native capture animation and semantic
    /// room. No detailed reconstruction or Metal mesh is run.
    func startClean(account: Account) {
        begin(clean: true, account: account)
    }

    private func begin(clean: Bool, account: Account?) {
        Diagnostics.action(clean ? "clean roomplan start" : "roomplan start")
        let view = RoomCaptureView(frame: .zero)
        delegate.onResult = { [weak self] room, error in self?.finished(room, error) }
        delegate.onUpdate = { [weak self] room in
            Task { @MainActor in
                guard let self, self.phase == .capturing else { return }
                self.summary = Self.describe(room)
                if self.isCleanMode {
                    self.cleanObjects = room.objects
                    self.cleanRecorder?.updateFurniture(room.objects)
                }
            }
        }
        view.delegate = delegate
        view.captureSession.delegate = delegate
        isCleanMode = clean
        cleanAccount = account
        cleanPhotoSummary = clean ? "Looking for furniture" : nil
        cleanCanCapture = false
        cleanFurnitureIndicators = []
        cleanObjects = []
        cleanFurnitureStates = [:]
        cleanProgress = nil
        if clean {
            do {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                cleanRecorder = try KeyframeRecorder(
                    folder: documents.appendingPathComponent("RoomTwin-Clean-\(Self.timestamp())"),
                    mode: .detectedFurniture)
                cleanRecorder?.onFurnitureStatus = { [weak self] captured, detected, canCapture, states in
                    Task { @MainActor in
                        guard let self else { return }
                        self.cleanFurnitureStates = states
                        self.cleanCanCapture = canCapture
                        self.cleanPhotoSummary = detected == 0 ? "Looking for furniture"
                            : canCapture ? "Optional Photo ready · \(captured) of \(detected) captured · others keep default shape"
                            : "\(captured) of \(detected) captured · show 20% for optional Photo"
                    }
                }
            } catch {
                errorMessage = "Could not create the Clean scan folder: \(error.localizedDescription)"
                cleanRecorder = nil
            }
        } else {
            cleanRecorder = nil
        }
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        captureView = view
        if clean {
            cleanFrameTimer?.invalidate()
            cleanFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, self.phase == .capturing, let view,
                          let frame = view.captureSession.arSession.currentFrame else { return }
                    let size = view.bounds.size.width > 1 ? view.bounds.size : UIScreen.main.bounds.size
                    self.cleanRecorder?.consider(frame, viewportSize: size)
                    self.updateCleanFurnitureIndicators(frame: frame, viewportSize: size)
                }
            }
        }
        room = nil
        mesh = nil
        preview = nil
        isPreviewOpen = false
        isSavedToAccount = false
        summary = nil
        isSavedToAccount = false
        phase = .capturing
    }

    @discardableResult
    func captureCleanFurniturePhoto() -> Bool {
        guard isCleanMode else { return false }
        let accepted = cleanRecorder?.requestFurniturePhoto() == true
        if accepted {
            Diagnostics.action("clean SAM furniture photo")
        } else {
            cleanPhotoSummary = "Show at least 20% of a furniture box for an optional photo"
        }
        return accepted
    }

    /// Ends the scan; RoomPlan then builds the room and shows it in its view.
    func finish() {
        guard phase == .capturing, let captureView else { return }
        Diagnostics.action("roomplan finish")
        viewer = captureView.captureSession.arSession.currentFrame?.camera.transform
        cleanFrameTimer?.invalidate()
        cleanFrameTimer = nil
        cleanFurnitureIndicators = []
        captureView.captureSession.stop()
        phase = .processing
    }

    /// Drops the scan and goes back to Start Scan.
    func close() {
        if phase == .capturing { captureView?.captureSession.stop() }
        cleanFrameTimer?.invalidate()
        cleanFrameTimer = nil
        cleanRecorder?.discard()
        cleanRecorder = nil
        cleanAccount = nil
        isCleanMode = false
        cleanPhotoSummary = nil
        cleanCanCapture = false
        cleanFurnitureIndicators = []
        cleanObjects = []
        cleanFurnitureStates = [:]
        cleanProgress = nil
        delegate.onUpdate = nil
        captureView = nil
        preview = nil
        isPreviewOpen = false
        room = nil
        mesh = nil
        summary = nil
        phase = .idle
    }

    /// Projects RoomPlan furniture into the native capture view. These are
    /// translucent status fills only; Apple's white boxes and animation stay
    /// fully native and visible around them.
    private func updateCleanFurnitureIndicators(frame: ARFrame, viewportSize: CGSize) {
        guard isCleanMode, viewportSize.width > 1, viewportSize.height > 1 else {
            cleanFurnitureIndicators = []
            return
        }
        let cameraFromWorld = frame.camera.transform.inverse
        let viewport = CGRect(origin: .zero, size: viewportSize)
        cleanFurnitureIndicators = cleanObjects.compactMap { object in
            let corners = [-1 as Float, 1].flatMap { x in
                [-1 as Float, 1].flatMap { y in
                    [-1 as Float, 1].map { z -> SIMD3<Float> in
                        let local = SIMD3(x, y, z) * object.dimensions / 2
                        let world = object.transform * SIMD4(local, 1)
                        return SIMD3(world.x, world.y, world.z)
                    }
                }
            }
            guard corners.allSatisfy({ (cameraFromWorld * SIMD4($0, 1)).z < -0.08 }) else { return nil }
            let points = corners.map {
                frame.camera.projectPoint($0, orientation: .portrait, viewportSize: viewportSize)
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
            let visible = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .intersection(viewport)
            guard !visible.isNull, visible.width >= 12, visible.height >= 12 else { return nil }
            let normalized = CGRect(x: visible.minX / viewportSize.width,
                                    y: visible.minY / viewportSize.height,
                                    width: visible.width / viewportSize.width,
                                    height: visible.height / viewportSize.height)
            return CleanFurnitureIndicator(id: object.identifier, rect: normalized,
                state: cleanFurnitureStates[object.identifier] ?? .detected)
        }
    }

    func openPreview() {
        guard let mesh, !isBusy else { return }
        Diagnostics.action("roomplan preview")
        if preview != nil {
            isPreviewOpen = true
            return
        }
        isPreparingPreview = true
        let viewer = viewer
        Task {
            let preview = await Task.detached { PreviewScene(mesh: mesh, viewer: viewer) }.value
            isPreparingPreview = false
            self.preview = preview
            self.isPreviewOpen = true
        }
    }

    func closePreview() {
        isPreviewOpen = false
    }

    /// USDZ and PLY of the room as shown in the preview, and RoomPlan's JSON of
    /// every wall, door, window and object with its category, size and pose.
    func export() {
        guard let room, let mesh, !isExporting else { return }
        Diagnostics.action("roomplan export")
        isExporting = true
        let edits = preview?.exportContents()
        Task {
            let result = await Task.detached { Result { try Self.write(room, mesh, edits) } }.value
            isExporting = false
            switch result {
            case .success(let urls): exportedFile = ExportedFile(urls: urls, triangles: mesh.faces.count)
            case .failure(let error): errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// Saves the same edited room shown in Orbit/Walk to the signed-in user's
    /// private Supabase storage and records it in `room_layouts`.
    func saveToAccount(_ account: Account) {
        guard let room, let mesh, !isBusy, !isSavedToAccount else { return }
        Diagnostics.action("roomplan cloud save")
        isSavingToAccount = true
        let edits = preview?.exportContents()
        Task {
            do {
                let urls = try await Task.detached { try Self.write(room, mesh, edits) }.value
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                try await account.saveRoomLayout(model: urls[0], ply: urls[1], json: urls[2], edits: urls[3],
                                                 name: "Room \(formatter.string(from: Date()))")
                isSavedToAccount = true
            } catch {
                errorMessage = "Couldn't save the room: \(error.localizedDescription)"
            }
            isSavingToAccount = false
        }
    }

    /// Opens a room saved to the account in the preview. RoomPlan's JSON
    /// rebuilds the room as scanned, every piece editable, and the furniture
    /// goes back as it was saved (see PreviewScene.restoreFurniture).
    /// Exporting or saving it again works as for a new scan.
    func open(_ layout: Account.SavedRoomLayout, from account: Account) async throws {
        guard !isBusy else { return }
        Diagnostics.action("roomplan open saved")
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        let files = try await account.roomFiles(for: layout)
        let kinds = FurnitureLibrary.kinds
        let (room, mesh, preview) = try await Task.detached {
            let room = try JSONDecoder().decode(CapturedRoom.self, from: Data(contentsOf: files.json))
            let library = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                FurnitureLibrary.mesh(kind).map { (kind, $0) }
            })
            let mesh = RoomPlanMesh.build(room, library: library)
            let preview = PreviewScene(mesh: mesh, viewer: nil)
            if let saved = try? SCNScene(url: files.model) {
                if let edits = files.edits,
                   let metadata = try? JSONDecoder().decode(RoomEditMetadata.self, from: Data(contentsOf: edits)) {
                    preview.restoreEdits(from: saved, metadata: metadata)
                } else {
                    // Rooms saved before edit metadata remain readable.
                    preview.restoreFurniture(from: saved)
                }
            }
            return (room, mesh, preview)
        }.value
        close()
        self.room = room
        self.mesh = mesh
        self.preview = preview
        summary = Self.describe(room)
        isSavedToAccount = false
        phase = .done
        isPreviewOpen = true
    }

    private func finished(_ room: CapturedRoom?, _ error: Error?) {
        guard let room else {
            errorMessage = "RoomPlan couldn't build the room: \(error?.localizedDescription ?? "unknown error")"
            phase = .capturing
            return
        }
        self.room = room
        summary = Self.describe(room)
        if isCleanMode {
            finishClean(room)
            return
        }
        let kinds = FurnitureLibrary.kinds
        Task {
            let mesh = await Task.detached {
                let library = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                    FurnitureLibrary.mesh(kind).map { (kind, $0) }
                })
                return RoomPlanMesh.build(room, library: library)
            }.value
            Diagnostics.log("roomplan: \(self.summary ?? ""), \(mesh.faces.count) triangles")
            self.mesh = mesh
            phase = .done
        }
    }

    private func finishClean(_ room: CapturedRoom) {
        guard let recorder = cleanRecorder else {
            errorMessage = "Clean mode could not access its furniture photos."
            buildCleanRoom(room, replacements: [])
            return
        }
        Task {
            let photos = await recorder.furniturePhotos()
            var replacements: [SAMFurnitureReplacement] = []
            if !photos.isEmpty {
                do {
                    replacements = try await SAMFurnitureProcessor.run(
                        folder: recorder.folder, photos: photos) { [weak self] progress in
                            self?.cleanProgress = progress
                        }
                } catch {
                    errorMessage = "SAM replacement was skipped: \(error.localizedDescription)"
                    Diagnostics.log("clean SAM replacement failed, keeping RoomPlan objects: \(error)")
                }
            }

            if !replacements.isEmpty, let account = cleanAccount {
                cleanProgress = .init(title: "Saving SAM objects to My Objects",
                                      detail: "Every generated replacement is saved automatically",
                                      fraction: 0.96)
                let saved = await SAMGeneratedObjectLibrary.save(
                    replacements, in: recorder.folder, to: account) { [weak self] detail in
                        self?.cleanProgress = .init(title: "Saving SAM objects to My Objects",
                                                   detail: detail, fraction: 0.97)
                    }
                if !saved.failures.isEmpty {
                    errorMessage = "The room is ready, but some SAM objects could not be saved to My Objects: "
                        + saved.failures.joined(separator: "; ")
                }
            }
            buildCleanRoom(room, replacements: replacements)
        }
    }

    private func buildCleanRoom(_ room: CapturedRoom, replacements: [SAMFurnitureReplacement]) {
        cleanProgress = .init(title: "Building the editable clean room",
                              detail: "Keeping every original RoomPlan object movable", fraction: 0.99)
        let kinds = FurnitureLibrary.kinds
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let library = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                    FurnitureLibrary.mesh(kind).map { (kind, $0) }
                })
                return SAMCleanRoomMesh.build(room: room, library: library, replacements: replacements)
            }.value
            mesh = result.mesh
            summary = "Clean RoomPlan · \(result.mesh.editableObjects.count) movable object"
                + "\(result.mesh.editableObjects.count == 1 ? "" : "s") · \(result.replacements) SAM replacement"
                + "\(result.replacements == 1 ? "" : "s")"
            cleanProgress = nil
            phase = .done
            Diagnostics.log("clean RoomPlan result: \(summary ?? "")")
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private nonisolated static func write(_ room: CapturedRoom, _ mesh: MeshSnapshot,
                                          _ edits: PreviewScene.ExportContents?) throws -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "RoomPlan-\(formatter.string(from: Date()))"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = folder.appendingPathComponent(name)
        let usdz = base.appendingPathExtension("usdz"), ply = base.appendingPathExtension("ply")
        let json = base.appendingPathExtension("json")
        let editJSON = base.appendingPathExtension("edits.json")
        try mesh.writePLY(to: ply)
        var exportMesh = edits?.scan ?? mesh
        if let edits {
            exportMesh.faces = exportMesh.faces.enumerated().compactMap {
                edits.replacedScanFaces.contains($0.offset) ? nil : $0.element
            }
        }
        try exportMesh.writeUSDZ(to: usdz, adding: edits?.nodes ?? [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(room).write(to: json)
        let metadata = edits?.metadata ?? RoomEditMetadata(version: RoomEditMetadata.currentVersion,
                                                           furniture: [], wallMaterials: [], floorMaterial: nil,
                                                           lighting: nil,
                                                           enclosure: .init(ceiling: false, openWalls: false),
                                                           snappingEnabled: false)
        try encoder.encode(metadata).write(to: editJSON)
        return [usdz, ply, json, editJSON]
    }

    private static func describe(_ room: CapturedRoom) -> String {
        func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [count(room.walls.count, "wall"), count(room.doors.count, "door"), count(room.windows.count, "window"),
                count(room.objects.count, "object")].compactMap { $0 }.joined(separator: " · ")
    }
}

/// RoomPlan's view delegate has to be NSCoding; nothing here is ever archived.
@objc(RoomTwinCaptureDelegate)
private final class CaptureDelegate: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    var onResult: ((CapturedRoom?, Error?) -> Void)?
    var onUpdate: ((CapturedRoom) -> Void)?

    override init() { super.init() }
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        onResult?(error == nil ? processedResult : nil, error)
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        onUpdate?(room)
    }
}

/// Shows RoomPlan's own live view.
struct RoomCaptureContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ view: RoomCaptureView, context: Context) {}
}

/// Status is shown only inside furniture. Red has no photo, yellow is framed
/// well enough to capture, and green has already been captured for SAM.
struct CleanFurnitureStatusOverlay: View {
    let indicators: [RoomPlanScan.CleanFurnitureIndicator]

    var body: some View {
        GeometryReader { geometry in
            ForEach(indicators) { indicator in
                let rect = CGRect(x: indicator.rect.minX * geometry.size.width,
                                  y: indicator.rect.minY * geometry.size.height,
                                  width: indicator.rect.width * geometry.size.width,
                                  height: indicator.rect.height * geometry.size.height)
                ZStack {
                    RoundedRectangle(cornerRadius: min(12, min(rect.width, rect.height) * 0.12))
                        .fill(indicator.color.opacity(0.18))
                    Image(systemName: indicator.symbol)
                        .font(.system(size: min(22, max(12, min(rect.width, rect.height) * 0.18)),
                                      weight: .bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(indicator.color.opacity(0.92), in: Circle())
                        .shadow(radius: 2)
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

private extension RoomPlanScan.CleanFurnitureIndicator {
    var color: Color {
        switch state {
        case .detected: .red
        case .ready: .yellow
        case .captured: .green
        }
    }

    var symbol: String {
        switch state {
        case .detected: "camera.badge.ellipsis"
        case .ready: "camera.fill"
        case .captured: "checkmark"
        }
    }
}

/// Our buttons over RoomPlan's view, for each step of a room layout scan.
struct RoomPlanControls: View {
    @ObservedObject var scan: RoomPlanScan
    @EnvironmentObject private var account: Account

    var body: some View {
        VStack(spacing: 12) {
            if let summary = scan.summary {
                Text(summary).capsule()
            }
            if scan.isCleanMode, let photos = scan.cleanPhotoSummary, scan.phase == .capturing {
                Label(photos, systemImage: "camera.viewfinder").capsule()
            }
            Spacer()
            if let message = scan.errorMessage {
                Text(message)
                    .capsule()
                    .onTapGesture { scan.errorMessage = nil }
            }
            switch scan.phase {
            case .capturing:
                HStack(spacing: 12) {
                    Button("Cancel", systemImage: "xmark", action: scan.close)
                        .buttonStyle(.bordered)
                    if scan.isCleanMode {
                        Button("Photo", systemImage: "camera.fill") { _ = scan.captureCleanFurniturePhoto() }
                            .buttonStyle(.borderedProminent)
                            .tint(scan.cleanCanCapture ? .yellow : .gray)
                            .disabled(!scan.cleanCanCapture)
                    }
                    Button("Done", systemImage: "checkmark", action: scan.finish)
                        .buttonStyle(.borderedProminent)
                }
                .tint(.white)
                .foregroundStyle(.black)
            case .processing:
                if let progress = scan.cleanProgress {
                    DeterminateProcessingProgress(progress: progress)
                } else {
                    // RoomPlan's own processing, then the summary arrives and the mesh is built.
                    ProcessingProgress(stage: scan.summary == nil
                        ? .init(title: "Finishing the room layout", key: "roomplan", range: 0...0.8, guess: 5)
                        : .init(title: scan.isCleanMode ? "Preparing Clean mode" : "Building the room model",
                                key: "roomplan-mesh", range: 0.8...1, guess: 1.5))
                }
            case .done:
                VStack(spacing: 10) {
                    Button(scan.isSavedToAccount ? "Saved to Account" : scan.isSavingToAccount ? "Saving to Account" : "Save to Account",
                           systemImage: scan.isSavedToAccount ? "checkmark.icloud.fill" : "icloud.and.arrow.up") {
                        scan.saveToAccount(account)
                    }
                    .buttonStyle(.borderedProminent)
                    // White like the rest, so its label needs to be dark to show.
                    .foregroundStyle(.black)
                    .disabled(scan.isBusy || scan.isSavedToAccount)
                    HStack(spacing: 12) {
                        Button("New Scan", systemImage: "arrow.counterclockwise", action: scan.close)
                            .disabled(scan.isBusy)
                        Button(scan.isPreparingPreview ? "Loading" : "View", systemImage: "view.3d", action: scan.openPreview)
                            .disabled(scan.isBusy)
                        Button(scan.isExporting ? "Saving" : "Export", systemImage: "square.and.arrow.up", action: scan.export)
                            .disabled(scan.isBusy)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            case .idle:
                EmptyView()
            }
        }
        .padding()
    }
}

private extension View {
    func capsule() -> some View {
        font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}
