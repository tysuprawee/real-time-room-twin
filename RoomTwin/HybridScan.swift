import RoomPlan
import SwiftUI

/// What the shared Detailed Mesh + RoomPlan capture becomes after scanning.
enum HybridOutputMode: String, Codable {
    /// RoomPlan owns the whole clean room; the detailed scan supplies colour.
    case semanticRoom
    /// RoomPlan owns the clean geometry, the detailed scan supplies only
    /// surface colour, and manually photographed furniture is replaced by SAM.
    case clean
    /// The detailed scan stays authoritative. RoomPlan only limits the
    /// offline SAM pipeline to furniture it actually detected.
    case samFurnitureReplacement

    var usesManualFurnitureCapture: Bool {
        self == .clean || self == .samFurnitureReplacement
    }

    var usesCleanRoomGeometry: Bool {
        self == .clean || self == .semanticRoom
    }
}

struct SAMReplacementManifest: Encodable {
    let version = 1
    let mode: HybridOutputMode
    let detectedFurnitureOnly = true
    let localSurfaceFill = true
    let roomPlanFile: String
    let detailedMeshFile: String
    let targetCount: Int
}

/// Coordinates RoomPlan semantics with the existing detailed reconstruction.
/// Both consumers observe one ARSession, so their transforms share a world
/// frame and the camera is never opened twice.
@MainActor
final class HybridScan: ObservableObject {
    enum Phase: Equatable {
        case idle, capturing, processing, done, failed
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var summary: String?
    @Published private(set) var instruction: String?
    @Published private(set) var usedDetailedFallback = false
    @Published private(set) var outputMode = HybridOutputMode.semanticRoom
    @Published private(set) var processingProgress: SAMFurnitureProgress?
    @Published var errorMessage: String?

    private var captureSession: RoomCaptureSession?
    private var completedRoom: CapturedRoom?
    private weak var account: Account?
    private let delegate = HybridCaptureDelegate()

    var isBusy: Bool { phase == .capturing || phase == .processing }

    func start(with scan: ScanController, account: Account? = nil,
               outputMode: HybridOutputMode = .semanticRoom) {
        guard phase == .idle, let arSession = scan.arSession else {
            errorMessage = "The detailed scanner's AR session is not available."
            return
        }
        Diagnostics.action(outputMode == .semanticRoom ? "hybrid start"
            : outputMode == .clean ? "clean scan start" : "SAM furniture scan start")
        self.outputMode = outputMode
        self.account = account
        scan.startScanning(profile: .hybrid,
                           keyframeMode: outputMode.usesManualFurnitureCapture ? .detectedFurniture : .continuous)
        let capture = RoomCaptureSession(arSession: arSession)
        delegate.onUpdate = { [weak self, weak scan] room in
            Task { @MainActor in
                guard let self, self.phase == .capturing else { return }
                scan?.updateHybridGuide(room, furnitureOnly: self.outputMode == .samFurnitureReplacement)
                if self.outputMode.usesManualFurnitureCapture {
                    scan?.updateSAMFurnitureTargets(room.objects)
                }
                self.summary = Self.describe(room)
            }
        }
        delegate.onInstruction = { [weak self] value in
            Task { @MainActor in
                guard let self, self.phase == .capturing else { return }
                self.instruction = Self.describe(value)
            }
        }
        delegate.onEnd = { [weak self, weak scan] data, error in
            Task { @MainActor in
                guard let self, let scan, self.phase != .idle else { return }
                self.process(data, reportedError: error, scan: scan)
            }
        }
        capture.delegate = delegate
        captureSession = capture
        switch outputMode {
        case .semanticRoom:
            summary = "Detailed mesh + RoomPlan · one AR session"
            instruction = "Move slowly and show every wall and piece of furniture"
        case .clean:
            summary = "Clean RoomPlan geometry · scan colours · manual SAM replacements"
            instruction = "Optional photos · Yellow at 20% visible · Green: captured · Skip to keep default shape"
        case .samFurnitureReplacement:
            summary = "Detailed room + RoomPlan-detected SAM targets"
            instruction = "Optional photos · Yellow at 20% visible · Green: captured · Skip to keep scanned shape"
        }
        usedDetailedFallback = false
        processingProgress = nil
        completedRoom = nil
        errorMessage = nil
        phase = .capturing
        capture.run(configuration: RoomCaptureSession.Configuration())
    }

    func finish(with scan: ScanController) {
        guard phase == .capturing, let captureSession else { return }
        Diagnostics.action("hybrid finish")
        phase = .processing
        processingProgress = outputMode.usesManualFurnitureCapture
            ? .init(title: "Finalizing RoomPlan", detail: "Confirming detected furniture", fraction: 0.01) : nil
        instruction = nil
        scan.pauseScanning()
        // Detailed preview/AR Edit keep the shared session alive and retain
        // the exact world origin used by both capture pipelines.
        captureSession.stop(pauseARSession: false)
    }

    func close(with scan: ScanController) {
        Diagnostics.action("hybrid close")
        delegate.onUpdate = nil
        delegate.onInstruction = nil
        delegate.onEnd = nil
        captureSession?.delegate = nil
        if phase == .capturing { captureSession?.stop(pauseARSession: false) }
        captureSession = nil
        phase = .idle
        summary = nil
        instruction = nil
        usedDetailedFallback = false
        processingProgress = nil
        completedRoom = nil
        account = nil
        errorMessage = nil
        scan.reset()
    }

    private func process(_ data: CapturedRoomData, reportedError: Error?, scan: ScanController) {
        guard phase != .idle else { return }
        phase = .processing
        let builder = RoomBuilder(options: [.beautifyObjects])
        Task {
            do {
                let room = try await builder.capturedRoom(from: data)
                guard phase != .idle else { return }
                scan.installHybridRoom(room, outputMode: outputMode)
                completedRoom = room
                if outputMode.usesManualFurnitureCapture {
                    await completeSAMFurniture(room, scan: scan)
                    return
                }
                summary = Self.describe(room)
                usedDetailedFallback = false
                phase = .done
                captureSession = nil
                Diagnostics.log("hybrid RoomPlan result (\(outputMode.rawValue)): \(summary ?? "")")
                scan.openPreview()
            } catch {
                guard phase != .idle else { return }
                usedDetailedFallback = true
                let reason = reportedError?.localizedDescription ?? error.localizedDescription
                errorMessage = "RoomPlan couldn't finish (\(reason)). Your detailed mesh is still available."
                summary = "RoomPlan unavailable · detailed mesh preserved"
                phase = .done
                captureSession = nil
                Diagnostics.log("hybrid falling back to detailed mesh: \(reason)")
                scan.openPreview()
            }
        }
    }

    func retry(with scan: ScanController) {
        guard phase == .failed, let completedRoom else { return }
        phase = .processing
        errorMessage = nil
        Task { await completeSAMFurniture(completedRoom, scan: scan) }
    }

    private func completeSAMFurniture(_ room: CapturedRoom, scan: ScanController) async {
        do {
            let result = try await scan.prepareSAMFurniture(room: room, outputMode: outputMode,
                                                            account: account) { [weak self] value in
                self?.processingProgress = value
            }
            guard phase != .idle else { return }
            processingProgress = .init(title: "Room ready", detail: result, fraction: 1)
            summary = result
            usedDetailedFallback = false
            phase = .done
            captureSession = nil
            Diagnostics.log("SAM furniture result: \(result)")
            scan.revealPreparedPreview()
        } catch {
            guard phase != .idle else { return }
            processingProgress = nil
            errorMessage = "Replacement stopped: \(error.localizedDescription)"
            summary = "The unfinished scan is hidden. Start the SAM server and retry, or begin a new scan."
            phase = .failed
            captureSession = nil
            Diagnostics.log("SAM furniture processing failed: \(error)")
        }
    }

    private static func describe(_ room: CapturedRoom) -> String {
        func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return [count(room.walls.count, "wall"), count(room.doors.count, "door"),
                count(room.windows.count, "window"), count(room.objects.count, "object")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func describe(_ instruction: RoomCaptureSession.Instruction) -> String? {
        switch instruction {
        case .moveCloseToWall: "Move closer to the wall"
        case .moveAwayFromWall: "Move farther from the wall"
        case .slowDown: "Move the phone more slowly"
        case .turnOnLight: "Turn on more lights"
        case .lowTexture: "Aim at an area with more visual detail"
        case .normal: nil
        @unknown default: nil
        }
    }
}

private final class HybridCaptureDelegate: NSObject, RoomCaptureSessionDelegate {
    var onUpdate: ((CapturedRoom) -> Void)?
    var onInstruction: ((RoomCaptureSession.Instruction) -> Void)?
    var onEnd: ((CapturedRoomData, Error?) -> Void)?

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        onUpdate?(room)
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        onInstruction?(instruction)
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        onEnd?(data, error)
    }
}
