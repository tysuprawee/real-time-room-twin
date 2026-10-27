import ARKit
import MetalKit
import RoomPlan
import SwiftUI

struct ExportedFile: Identifiable {
    let urls: [URL]
    let triangles: Int
    var id: URL { urls[0] }
}

/// UI-facing state for a scan; owns the Metal view and renderer.
final class ScanController: ObservableObject {
    @Published private(set) var stats = ReconstructionStats()
    /// False until the first tap on Start Scan; the camera runs but nothing is fused.
    @Published private(set) var hasStarted = false
    @Published private(set) var isScanning = false
    @Published private(set) var profile = ScanPerformanceProfile.detailed
    @Published private(set) var viewMode = MeshViewMode.color
    @Published private(set) var isExporting = false
    /// The scan as a 3D scene to look round, while the preview is open.
    @Published private(set) var preview: PreviewScene?
    @Published private(set) var isPreviewOpen = false
    @Published private(set) var isARPreviewActive = false
    @Published private(set) var isPreparingPreview = false
    /// Why frames aren't being fused right now, if tracking isn't normal.
    @Published private(set) var trackingHint: String?
    @Published private(set) var hybridExtractionSummary: String?
    @Published private(set) var samFurniturePhotoSummary: String?
    @Published private(set) var samFurnitureCanCapture = false
    @Published var exportedFile: ExportedFile?
    @Published var errorMessage: String?

    let view = MTKView()
    private var renderer: ScanRenderer?
    /// Scanning has gone on since the preview was made, so it shows less
    /// than the scan does; View and Export make it afresh.
    private var isPreviewStale = false
    /// Each scan gets a folder in Documents with its keyframes and exports.
    private var keyframes: KeyframeRecorder?
    private var isActive = true
    /// Final RoomPlan semantics for a Hybrid scan. RoomPlan supplies the clean
    /// authoritative topology; the detailed mesh supplies captured colour and
    /// remains available as the raw PLY/export fallback.
    private var hybridRoom: CapturedRoom?
    private var hybridOutputMode: HybridOutputMode?
    private var samFurnitureStates: [UUID: FurniturePhotoState] = [:]
    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        guard ScanRenderer.isSupported else {
            errorMessage = "This device has no LiDAR scanner. RoomTwin needs an iPhone 12 Pro or later Pro model, or an iPad Pro."
            return
        }
        do {
            let renderer = try ScanRenderer(view: view)
            renderer.onStats = { [weak self] in self?.stats = $0 }
            renderer.onTrackingHint = { [weak self] in self?.trackingHint = $0 }
            self.renderer = renderer
        } catch {
            errorMessage = "Could not set up Metal: \(error)"
        }
    }

    func start() {
        renderer?.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        renderer?.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Stops drawing while the app is inactive. A frame drawn while the phone
    /// locks or the app switcher opens can wait a full second for a drawable,
    /// blocking the main thread.
    func setActive(_ active: Bool) {
        isActive = active
        updateDrawing()
    }

    /// The live view stops behind Orbit/Walk, but remains visible beneath the
    /// transparent SceneKit overlay in AR Edit.
    private func updateDrawing() {
        view.isPaused = !isActive || (isPreviewOpen && !isARPreviewActive)
    }

    /// Reading the mesh pools while the GPU writes them would give a torn
    /// mesh, so scanning and reset wait for these.
    var isBusy: Bool {
        isExporting || isPreparingPreview
    }

    func startScanning(profile: ScanPerformanceProfile = .detailed,
                       keyframeMode: KeyframeRecorder.Mode = .continuous) {
        self.profile = profile
        renderer?.use(profile)
        renderer?.setRoomPlanGuide([])
        hasStarted = true
        startRecording(mode: keyframeMode)
        setScanning(true)
        Diagnostics.action("start scan")
    }

    func toggleScanning() {
        setScanning(!isScanning)
        Diagnostics.action(isScanning ? "scan" : "pause")
    }

    func pauseScanning() {
        setScanning(false)
    }

    func installHybridRoom(_ room: CapturedRoom, outputMode: HybridOutputMode = .semanticRoom) {
        hybridRoom = room
        hybridOutputMode = outputMode
        hybridExtractionSummary = nil
        samFurniturePhotoSummary = nil
        samFurnitureCanCapture = false
        samFurnitureStates = [:]
        isPreviewStale = true
    }

    func updateHybridGuide(_ room: CapturedRoom, furnitureOnly: Bool = false) {
        let surfaces = furnitureOnly ? [] : (room.walls + room.doors + room.windows + room.openings + room.floors)
            .map { RoomPlanGuideBox(transform: $0.transform, dimensions: $0.dimensions, identifier: nil) }
        let objects = room.objects.map {
            RoomPlanGuideBox(transform: $0.transform, dimensions: $0.dimensions,
                             identifier: $0.identifier,
                             state: samFurnitureStates[$0.identifier] ?? .detected)
        }
        let boxes = surfaces + objects
        renderer?.setRoomPlanGuide(boxes)
    }

    func updateSAMFurnitureTargets(_ objects: [CapturedRoom.Object]) {
        keyframes?.updateFurniture(objects)
    }

    @discardableResult
    func captureSAMFurniturePhoto() -> Bool {
        let accepted = keyframes?.requestFurniturePhoto() == true
        if accepted {
            Diagnostics.action("SAM furniture photo")
        } else {
            samFurniturePhotoSummary = "Optional photos · show 20% of a red box to turn it yellow"
        }
        return accepted
    }

    /// The camera's latest frame, for Object mode's photo.
    var currentFrame: ARFrame? {
        renderer?.session.currentFrame
    }

    /// The scanner's existing world-tracking session. AR Edit reuses it so no
    /// second camera session competes with reconstruction.
    var arSession: ARSession? { renderer?.session }

    /// Object Capture and AR Quick Look need the camera to themselves. Unlike
    /// stop(), this keeps the screen awake.
    func setCameraPaused(_ paused: Bool) {
        if paused { renderer?.pause() } else { renderer?.start() }
    }

    /// Object mode uses the camera but not the room: fusion pauses and the mesh is hidden.
    func setObjectMode(_ on: Bool) {
        if on { setScanning(false) }
        renderer?.viewMode = on ? .hidden : viewMode
        Diagnostics.action(on ? "object mode" : "room mode")
    }

    func cycleViewMode() {
        let modes = MeshViewMode.allCases
        viewMode = modes[(modes.firstIndex(of: viewMode)! + 1) % modes.count]
        renderer?.viewMode = viewMode
        Diagnostics.action("view mode \(viewMode.label)")
    }

    /// Clears the scan and goes back to Start Scan, where either kind of scan can begin.
    func reset() {
        renderer?.reset()
        stats = ReconstructionStats()
        setScanning(false)
        keyframes?.discard()
        keyframes = nil
        renderer?.keyframes = nil
        preview = nil
        isPreviewStale = false
        isPreviewOpen = false
        isARPreviewActive = false
        hasStarted = false
        hybridRoom = nil
        hybridOutputMode = nil
        hybridExtractionSummary = nil
        samFurniturePhotoSummary = nil
        samFurnitureCanCapture = false
        samFurnitureStates = [:]
        renderer?.setRoomPlanGuide([])
        profile = .detailed
        renderer?.use(.detailed)
        Diagnostics.action("reset")
    }

    func export() {
        guard let renderer, !isBusy else { return }
        Diagnostics.action("export")
        isExporting = true
        setScanning(false)
        if isPreviewStale {
            // The edits are exported with the scan they were made on, so bring that up to date first.
            buildPreview { [weak self] in
                self?.isExporting = false
                self?.export()
            }
            return
        }
        let reconstructor = renderer.reconstructor
        let folder = keyframes?.folder ?? Self.documents
        let edits = preview?.exportContents()
        let semanticRoom = hybridRoom
        let outputMode = hybridOutputMode
        renderer.whenGPUIdle { [weak self] in
            var stepStart = ProcessInfo.processInfo.systemUptime
            func step(_ name: String) {
                let now = ProcessInfo.processInfo.systemUptime
                Diagnostics.log(String(format: "export: %@ took %.0f ms", name, (now - stepStart) * 1000))
                stepStart = now
            }
            let mesh = reconstructor.snapshot()
            step("snapshot of \(mesh.faces.count) triangles")
            let base = folder.appendingPathComponent("RoomTwin-\(Self.timestamp())")
            let ply = base.appendingPathExtension("ply")
            let usdz = base.appendingPathExtension("usdz")
            let result = Result { () -> [URL] in
                try mesh.writePLY(to: ply)
                step("PLY")
                var exportMesh = edits?.scan ?? mesh
                if let edits {
                    exportMesh.faces = exportMesh.faces.enumerated().compactMap {
                        edits.replacedScanFaces.contains($0.offset) ? nil : $0.element
                    }
                }
                try exportMesh.writeUSDZ(to: usdz, adding: edits?.nodes ?? [])
                step("USDZ")
                var urls = [usdz, ply]
                if let semanticRoom {
                    let json = base.appendingPathExtension("roomplan.json")
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(semanticRoom).write(to: json, options: .atomic)
                    urls.append(json)
                    step("RoomPlan JSON")
                    if let outputMode, outputMode.usesManualFurnitureCapture {
                        let manifest = base.appendingPathExtension("sam.json")
                        let value = SAMReplacementManifest(
                            mode: outputMode,
                            roomPlanFile: json.lastPathComponent,
                            detailedMeshFile: ply.lastPathComponent,
                            targetCount: semanticRoom.objects.count)
                        try JSONEncoder().encode(value).write(to: manifest, options: .atomic)
                        urls.append(manifest)
                        step("SAM replacement manifest")
                    }
                }
                return urls
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success(let urls):
                    Diagnostics.action("share sheet opening")
                    self.exportedFile = ExportedFile(urls: urls, triangles: mesh.faces.count)
                case .failure(let error): self.errorMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Pauses scanning and opens the scan as a 3D scene. Scanning can resume
    /// after closing it.
    func openPreview() {
        guard renderer != nil, !isBusy else { return }
        Diagnostics.action("preview")
        if preview != nil, !isPreviewStale {
            isARPreviewActive = false
            isPreviewOpen = true
            updateDrawing()
            return
        }
        isPreparingPreview = true
        setScanning(false)
        buildPreview { [weak self] in
            guard let self else { return }
            self.isPreparingPreview = false
            guard self.preview != nil else { return }
            self.isARPreviewActive = false
            self.isPreviewOpen = true
            self.updateDrawing()
        }
    }

    /// Completes SAM Furniture before any unfinished scan can be shown. The
    /// expensive network/model work happens while HybridScan owns the progress
    /// screen; only the final detailed-room + replacement scene is published.
    @MainActor
    func prepareSAMFurniture(room: CapturedRoom, outputMode: HybridOutputMode, account: Account?,
                             progress: @escaping SAMFurnitureProcessor.Progress) async throws -> String {
        guard let recorder = keyframes, let renderer else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The SAM scan folder is unavailable."])
        }
        isPreparingPreview = true
        defer { isPreparingPreview = false }
        progress(.init(title: "Preparing the detailed room", detail: "Waiting for the last furniture photo", fraction: 0.03))
        let photos = await recorder.furniturePhotos()
        let detailed: MeshSnapshot = await withCheckedContinuation { continuation in
            renderer.whenGPUIdle {
                continuation.resume(returning: renderer.reconstructor.snapshot())
            }
        }
        let replacements = try await SAMFurnitureProcessor.run(
            folder: recorder.folder, photos: photos, progress: progress)
        if let account {
            progress(.init(title: "Saving SAM objects to My Objects",
                           detail: "Every generated replacement is saved automatically", fraction: 0.945))
            let libraryResult = await SAMGeneratedObjectLibrary.save(
                replacements, in: recorder.folder, to: account) { detail in
                    progress(.init(title: "Saving SAM objects to My Objects", detail: detail, fraction: 0.95))
                }
            if !libraryResult.failures.isEmpty {
                errorMessage = "Some SAM objects could not be added to My Objects: "
                    + libraryResult.failures.joined(separator: "; ")
            }
        }
        let replacementBase: MeshSnapshot
        let cleanSummary: String?
        if outputMode == .clean {
            progress(.init(title: "Building the clean room",
                           detail: "Using RoomPlan geometry and sampling only colour from the mesh",
                           fraction: 0.955))
            let kinds = FurnitureLibrary.kinds
            let library = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in
                FurnitureLibrary.mesh(kind).map { (kind, $0) }
            })
            let semantic = await Task.detached(priority: .userInitiated) {
                HybridSemanticMesh.build(room: room, detailed: detailed, library: library)
            }.value
            guard semantic.usedRoomPlanLayout else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                    "RoomPlan did not produce enough clean surfaces for Clean mode."])
            }
            replacementBase = semantic.mesh
            cleanSummary = semantic.summary
        } else {
            replacementBase = detailed
            cleanSummary = nil
        }
        progress(.init(title: "Fitting replacements into the room",
                       detail: outputMode == .clean
                           ? "Replacing RoomPlan furniture on clean textured surfaces"
                           : "Preserving detailed walls and repairing only hidden surfaces",
                       fraction: 0.97))
        let result = await Task.detached(priority: .userInitiated) {
            SAMFurnitureMesh.build(room: room, detailed: replacementBase, replacements: replacements)
        }.value
        guard replacements.isEmpty || result.replacements > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "Generated models no longer matched the final RoomPlan furniture identifiers."])
        }
        progress(.init(title: "Building the editable preview", detail: "Almost ready", fraction: 0.99))
        let viewer = renderer.session.currentFrame?.camera.transform
        let newPreview = await Task.detached(priority: .userInitiated) {
            PreviewScene(mesh: result.mesh, viewer: viewer)
        }.value
        preview = newPreview
        isPreviewStale = false
        let summary = outputMode == .clean
            ? "Clean · \(cleanSummary ?? "RoomPlan surfaces + scan colours") · \(result.replacements) SAM replacement\(result.replacements == 1 ? "" : "s")"
            : result.summary
        hybridExtractionSummary = summary
        return summary
    }

    @MainActor
    func revealPreparedPreview() {
        guard preview != nil else { return }
        isARPreviewActive = false
        isPreviewOpen = true
        updateDrawing()
    }

    /// Makes the preview from the scan as it is now. One made before, from
    /// less of the scan, hands its furniture and looks over to the new one.
    private func buildPreview(then done: @escaping () -> Void) {
        guard let renderer else { return }
        let reconstructor = renderer.reconstructor
        let viewer = renderer.session.currentFrame?.camera.transform
        let semanticRoom = hybridRoom
        let outputMode = hybridOutputMode
        let furnitureKinds = FurnitureLibrary.kinds
        renderer.whenGPUIdle { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let raw = reconstructor.snapshot()
            let hybrid = outputMode?.usesCleanRoomGeometry == true ? semanticRoom.map { room in
                let library = Dictionary(uniqueKeysWithValues: furnitureKinds.compactMap { kind in
                    FurnitureLibrary.mesh(kind).map { (kind, $0) }
                })
                return HybridSemanticMesh.build(room: room, detailed: raw, library: library)
            } : nil
            let mesh = hybrid?.mesh ?? raw
            if let hybrid { Diagnostics.log("hybrid semantic mesh: \(hybrid.summary)") }
            let samSummary: String?
            if outputMode == .samFurnitureReplacement {
                samSummary = "Detailed room preserved · \(semanticRoom?.objects.count ?? 0) detected furniture targets for SAM 3D"
            } else if outputMode == .clean {
                samSummary = "Clean RoomPlan surfaces · scan colours only · \(semanticRoom?.objects.count ?? 0) SAM targets"
            } else {
                samSummary = nil
            }
            let preview = mesh.faces.isEmpty ? nil : PreviewScene(mesh: mesh, viewer: viewer)
            Diagnostics.log(String(format: "preview: %d triangles in %.0f ms", mesh.faces.count,
                                   (ProcessInfo.processInfo.systemUptime - start) * 1000))
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPreviewStale = false
                self.hybridExtractionSummary = hybrid?.summary ?? samSummary
                if let preview {
                    if let earlier = self.preview { preview.continueEdits(from: earlier) }
                    self.preview = preview
                } else {
                    self.errorMessage = "Nothing scanned yet. Scan for a few seconds first."
                }
                done()
            }
        }
    }

    func closePreview() {
        Diagnostics.action("close preview")
        renderer?.viewMode = viewMode
        isARPreviewActive = false
        isPreviewOpen = false
        updateDrawing()
    }

    func setARPreviewActive(_ active: Bool) {
        guard isPreviewOpen, active != isARPreviewActive else { return }
        isARPreviewActive = active
        // The ARSession intentionally remains running throughout the detailed
        // preview, preserving its world origin. In AR Edit Metal draws only
        // the camera; SceneKit supplies the editable virtual furniture.
        renderer?.viewMode = active ? .hidden : viewMode
        updateDrawing()
        Diagnostics.action(active ? "AR edit" : "preview camera")
    }

    private func setScanning(_ scanning: Bool) {
        isScanning = scanning
        renderer?.isScanning = scanning
        if scanning, preview != nil { isPreviewStale = true }
    }

    private func startRecording(mode: KeyframeRecorder.Mode = .continuous) {
        do {
            keyframes = try KeyframeRecorder(folder: Self.documents.appendingPathComponent("RoomTwin-\(Self.timestamp())"),
                                             mode: mode)
            keyframes?.onFurnitureStatus = { [weak self] captured, detected, canCapture, states in
                guard let self else { return }
                self.samFurnitureCanCapture = canCapture
                self.samFurnitureStates = states
                self.samFurniturePhotoSummary = detected == 0
                    ? "Looking for furniture"
                    : canCapture
                        ? "\(captured) of \(detected) captured · optional Photo ready"
                        : "\(captured) of \(detected) captured · photos optional"
                self.renderer?.setFurniturePhotoStates(states)
            }
        } catch {
            keyframes = nil
            errorMessage = "Could not create the scan folder: \(error.localizedDescription)"
        }
        renderer?.keyframes = keyframes
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        // Without a fixed locale, a 12-hour time setting turns HH into "2 PM".
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }
}
