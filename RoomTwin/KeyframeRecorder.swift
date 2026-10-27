import ARKit
import CoreImage
import RoomPlan
import UIKit

/// Saves keyframes while scanning, for the offline furniture step: the color
/// photo, LiDAR depth and confidence, and the camera pose and intrinsics.
///
/// Layout of a scan folder:
///   keyframes/000000.jpg    color image as captured (landscape, sensor orientation)
///   keyframes/000000.depth  Float32 metres, depthWidth x depthHeight, row-major
///   keyframes/000000.conf   UInt8 ARConfidenceLevel per depth pixel (0 low ... 2 high)
///   keyframes.json          one entry per keyframe, see `Keyframe`
///
/// Poses are in the same ARKit world frame as the exported mesh.
final class KeyframeRecorder: @unchecked Sendable {
    enum Mode {
        case continuous
        /// One optional photo for each RoomPlan furniture item.
        case detectedFurniture
    }

    let folder: URL

    struct SavedKeyframe: Codable {
        let index: Int
        let timestamp: TimeInterval
        let image: String
        let depth: String
        let confidence: String
        let imageWidth: Int
        let imageHeight: Int
        let depthWidth: Int
        let depthHeight: Int
        /// fx, fy, cx, cy of the color image, in pixels.
        let intrinsics: [Float]
        /// Column-major 4x4. ARKit camera axes: +x right, +y up, looking down -z,
        /// with the image's +x to the right and +y down.
        let cameraToWorld: [Float]
        /// Present only in SAM Furniture mode. The RoomPlan box is stored with
        /// the photo so the server can constrain segmentation to this object.
        let targetIdentifier: String?
        let targetCategory: String?
        let targetCoverage: Float?
        let targetDimensions: [Float]?
        let targetTransform: [Float]?
    }

    private struct FurnitureTarget {
        let identifier: UUID
        let category: String
        let dimensions: SIMD3<Float>
        let transform: simd_float4x4
        let stableSince: TimeInterval

        var corners: [SIMD3<Float>] {
            [-1 as Float, 1].flatMap { x in
                [-1 as Float, 1].flatMap { y in
                    [-1 as Float, 1].map { z in
                        let world = transform * SIMD4(SIMD3(x, y, z) * dimensions / 2, 1)
                        return SIMD3(world.x, world.y, world.z)
                    }
                }
            }
        }
    }

    private let queue = DispatchQueue(label: "KeyframeRecorder", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let mode: Mode
    private var keyframes: [SavedKeyframe] = []                  // queue only
    private var lastSaved: (time: TimeInterval, transform: simd_float4x4)?
    private var pending = 0
    private var count = 0
    /// Main-thread state, updated by RoomPlan and consumed by `consider`.
    private var furnitureTargets: [UUID: FurnitureTarget] = [:]
    /// Session-wide capture checklist. Live RoomPlan updates may temporarily
    /// omit a box; that must not remove an item from the detected total.
    private var detectedTargets: [UUID: FurnitureTarget] = [:]
    private var detectionIDs: [UUID: UUID] = [:]
    private var photographedDetectionIDs = Set<UUID>()
    private var scheduledTargets = Set<UUID>()
    private var capturedTargets: [FurnitureTarget] = []
    private var captureRequested = false
    private var lastFurnitureStates: [UUID: FurniturePhotoState] = [:]
    private var lastReportedStates: [UUID: FurniturePhotoState] = [:]
    private var lastReportedStatus: (captured: Int, detected: Int, canCapture: Bool)?
    var onFurnitureStatus: ((Int, Int, Bool, [UUID: FurniturePhotoState]) -> Void)?

    init(folder: URL, mode: Mode = .continuous) throws {
        self.folder = folder
        self.mode = mode
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keyframes"),
                                                withIntermediateDirectories: true)
    }

    /// Updates the live RoomPlan furniture boxes. A box must stop changing for
    /// half a second before the user can take its optional photo. Include
    /// low-confidence detections so every detected item can be photographed.
    func updateFurniture(_ objects: [CapturedRoom.Object]) {
        guard mode == .detectedFurniture else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let liveIDs = Set(objects.map(\.identifier))
        var assignedDetectionIDs = Set(liveIDs.compactMap { detectionIDs[$0] })
        var next: [UUID: FurnitureTarget] = [:]
        for object in objects {
            let old = furnitureTargets[object.identifier]
            let moved = old.map { simd_distance($0.transform.position, object.transform.position) } ?? .infinity
            let resized = old.map { simd_length($0.dimensions - object.dimensions) } ?? .infinity
            let turned = old.map {
                abs(simd_dot(simd_normalize($0.transform.forward), simd_normalize(object.transform.forward)))
            } ?? 0
            let stable = old != nil && moved < 0.04 && resized < 0.06 && turned > cos(Float.pi / 36)
            next[object.identifier] = FurnitureTarget(
                identifier: object.identifier, category: RoomPlanMesh.name(of: object.category),
                dimensions: object.dimensions, transform: object.transform,
                stableSince: stable ? old!.stableSince : now)
            guard let target = next[object.identifier] else { continue }
            // Reuse a missing detection only for a nearly identical box.
            // Two separate objects present in the same update always count
            // separately, even if their boxes are close or overlapping.
            let previousID = detectionIDs[target.identifier]
            let reidentified = detectedTargets
                .filter { !liveIDs.contains($0.value.identifier)
                    && !assignedDetectionIDs.contains($0.key)
                    && Self.sameFurniture($0.value, target) }
                .min { simd_distance($0.value.transform.position, target.transform.position)
                    < simd_distance($1.value.transform.position, target.transform.position) }?.key
            let detectionID = previousID ?? reidentified ?? target.identifier
            detectionIDs[target.identifier] = detectionID
            detectedTargets[detectionID] = target
            assignedDetectionIDs.insert(detectionID)
        }
        furnitureTargets = next
        var states: [UUID: FurniturePhotoState] = [:]
        for target in next.values {
            states[target.identifier] = isDuplicateOfCaptured(target)
                ? .captured : lastFurnitureStates[target.identifier] ?? .detected
        }
        publishFurnitureStatus(states)
    }

    /// Arms exactly one photo for the next live frame. The request is accepted
    /// only while a stable, uncaptured box is yellow (at least 20% visible).
    @discardableResult
    func requestFurniturePhoto() -> Bool {
        guard mode == .detectedFurniture, pending == 0, !captureRequested,
              lastFurnitureStates.values.contains(.ready) else { return false }
        captureRequested = true
        publishFurnitureStatus(lastFurnitureStates)
        return true
    }

    /// Saves `frame` if the camera has moved or turned enough since the last
    /// keyframe, at most twice a second. Call on the main thread with frames
    /// that were fused into the mesh.
    func consider(_ frame: ARFrame, viewportSize: CGSize) {
        let transform = frame.camera.transform
        let target: (value: FurnitureTarget, coverage: Float)?
        switch mode {
        case .continuous:
            if let last = lastSaved {
                let elapsed = frame.timestamp - last.time
                let moved = simd_distance(transform.columns.3, last.transform.columns.3)
                let turned = simd_dot(transform.columns.2, last.transform.columns.2)
                guard elapsed >= 0.5, elapsed >= 3 || moved >= 0.15 || turned <= cos(Float.pi / 18) else { return }
            }
            target = nil
        case .detectedFurniture:
            let eligible = eligibleFurniture(in: frame, viewportSize: viewportSize)
            let ready = Set(eligible.map { $0.value.identifier })
            var states: [UUID: FurniturePhotoState] = [:]
            for item in furnitureTargets.values {
                states[item.identifier] = isDuplicateOfCaptured(item) ? .captured
                    : ready.contains(item.identifier) || scheduledTargets.contains(item.identifier) ? .ready
                    : .detected
            }
            publishFurnitureStatus(states)
            guard captureRequested, let best = eligible.first else { return }
            target = best
        }

        guard pending == 0, let sceneDepth = frame.sceneDepth,
              let confidenceMap = sceneDepth.confidenceMap else { return }
        if let target {
            captureRequested = false
            scheduledTargets.insert(target.value.identifier)
            publishFurnitureStatus(lastFurnitureStates)
        }
        lastSaved = (frame.timestamp, transform)

        let index = count
        count += 1
        let name = String(format: "keyframes/%06d", index)
        let depth = copyPlane(sceneDepth.depthMap, bytesPerPixel: 4)
        let confidence = copyPlane(confidenceMap, bytesPerPixel: 1)
        let image = frame.capturedImage
        let k = frame.camera.intrinsics
        let c = transform.columns
        let targetTransform = target.map { value in
            let c = value.value.transform.columns
            return [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        let keyframe = SavedKeyframe(index: index, timestamp: frame.timestamp,
                                image: name + ".jpg", depth: name + ".depth", confidence: name + ".conf",
                                imageWidth: CVPixelBufferGetWidth(image), imageHeight: CVPixelBufferGetHeight(image),
                                depthWidth: CVPixelBufferGetWidth(sceneDepth.depthMap),
                                depthHeight: CVPixelBufferGetHeight(sceneDepth.depthMap),
                                intrinsics: [k[0][0], k[1][1], k[2][0], k[2][1]],
                                cameraToWorld: [c.0, c.1, c.2, c.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
                                targetIdentifier: target?.value.identifier.uuidString,
                                targetCategory: target?.value.category,
                                targetCoverage: target?.coverage,
                                targetDimensions: target.map { [$0.value.dimensions.x, $0.value.dimensions.y,
                                                                $0.value.dimensions.z] },
                                targetTransform: targetTransform)
        pending += 1
        queue.async { [self] in
            guard let jpeg = context.jpegRepresentation(
                of: CIImage(cvPixelBuffer: image), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
            else {
                DispatchQueue.main.async { self.finishPending(target: target?.value, succeeded: false) }
                return
            }
            do {
                try jpeg.write(to: folder.appendingPathComponent(keyframe.image))
                try depth.write(to: folder.appendingPathComponent(keyframe.depth))
                try confidence.write(to: folder.appendingPathComponent(keyframe.confidence))
                keyframes.append(keyframe)
                // Rewritten every time so the list survives the app being killed.
                try JSONEncoder().encode(keyframes).write(to: folder.appendingPathComponent("keyframes.json"),
                                                          options: .atomic)
                DispatchQueue.main.async { self.finishPending(target: target?.value, succeeded: true) }
            } catch {
                Diagnostics.log("keyframe \(index) not saved: \(error.localizedDescription)")
                DispatchQueue.main.async { self.finishPending(target: target?.value, succeeded: false) }
            }
        }
    }

    /// Waits for the last JPEG/depth write and returns the targeted photos.
    func furniturePhotos() async -> [SavedKeyframe] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.keyframes.filter { $0.targetIdentifier != nil }) }
        }
    }

    /// Deletes the keyframes once pending writes are done. Exports in the folder are kept.
    func discard() {
        queue.async { [folder] in
            let files = FileManager.default
            try? files.removeItem(at: folder.appendingPathComponent("keyframes"))
            try? files.removeItem(at: folder.appendingPathComponent("keyframes.json"))
            if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? files.removeItem(at: folder)
            }
        }
    }

    private func copyPlane(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var data = Data(capacity: width * height * bytesPerPixel)
        for row in 0..<height {
            data.append(base + row * stride, count: width * bytesPerPixel)
        }
        return data
    }

    private func finishPending(target: FurnitureTarget?, succeeded: Bool) {
        pending -= 1
        guard let target else { return }
        scheduledTargets.remove(target.identifier)
        if succeeded {
            capturedTargets.append(target)
            photographedDetectionIDs.insert(detectionIDs[target.identifier] ?? target.identifier)
        }
        var states = lastFurnitureStates
        for item in furnitureTargets.values where isDuplicateOfCaptured(item) {
            states[item.identifier] = .captured
        }
        publishFurnitureStatus(states)
    }

    /// Highest-quality target whose projected box is at least 20% inside the
    /// actual portrait viewport. Small detected items are eligible too.
    private func eligibleFurniture(in frame: ARFrame, viewportSize requestedSize: CGSize)
        -> [(value: FurnitureTarget, coverage: Float)] {
        let now = ProcessInfo.processInfo.systemUptime
        let viewport = requestedSize.width > 1 && requestedSize.height > 1
            ? requestedSize
            : CGSize(width: CVPixelBufferGetHeight(frame.capturedImage),
                     height: CVPixelBufferGetWidth(frame.capturedImage))
        let visible = CGRect(origin: .zero, size: viewport)
        let cameraFromWorld = frame.camera.transform.inverse
        var eligible: [(FurnitureTarget, Float, CGFloat)] = []
        for target in furnitureTargets.values {
            guard now - target.stableSince >= 0.5,
                  !scheduledTargets.contains(target.identifier),
                  !isDuplicateOfCaptured(target) else { continue }
            let corners = target.corners
            guard corners.allSatisfy({ (cameraFromWorld * SIMD4($0, 1)).z < -0.08 }) else { continue }
            let projected = corners.map {
                frame.camera.projectPoint($0, orientation: .portrait, viewportSize: viewport)
            }
            guard let minX = projected.map(\.x).min(), let maxX = projected.map(\.x).max(),
                  let minY = projected.map(\.y).min(), let maxY = projected.map(\.y).max() else { continue }
            let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let area = box.width * box.height
            guard area > 0 else { continue }
            let coverage = Float(box.intersection(visible).area / area)
            let apparent = area / max(viewport.width * viewport.height, 1)
            guard coverage >= 0.2 else { continue }
            eligible.append((target, coverage, apparent))
        }
        return eligible.sorted {
            $0.1 + Float(min($0.2, 0.25)) > $1.1 + Float(min($1.2, 0.25))
        }.map { ($0.0, $0.1) }
    }

    private func publishFurnitureStatus(_ states: [UUID: FurniturePhotoState]) {
        lastFurnitureStates = states
        let canCapture = states.values.contains(.ready) && pending == 0 && !captureRequested
        let status = (photographedDetectionIDs.count, detectedTargets.count, canCapture)
        guard lastReportedStatus?.captured != status.0
                || lastReportedStatus?.detected != status.1
                || lastReportedStatus?.canCapture != status.2
                || lastReportedStates != states else { return }
        lastReportedStatus = status
        lastReportedStates = states
        onFurnitureStatus?(status.0, status.1, status.2, states)
    }

    /// RoomPlan can briefly remove and re-add an object while refining the
    /// room. Treat a nearly identical box as the already photographed object,
    /// while keeping adjacent chairs separate.
    private func isDuplicateOfCaptured(_ target: FurnitureTarget) -> Bool {
        if let detectionID = detectionIDs[target.identifier],
           photographedDetectionIDs.contains(detectionID) { return true }
        return capturedTargets.contains { captured in
            // For known distinct detections, proximity must not mark a new
            // neighboring item as captured.
            if let a = detectionIDs[captured.identifier], let b = detectionIDs[target.identifier] {
                return a == b
            }
            return Self.sameFurniture(captured, target)
        }
    }

    private static func sameFurniture(_ a: FurnitureTarget, _ b: FurnitureTarget) -> Bool {
        guard a.category == b.category else { return false }
        let size = max(simd_length(a.dimensions), 0.1)
        return simd_distance(a.transform.position, b.transform.position) < 0.08 * size
            && simd_length(a.dimensions - b.dimensions) < 0.12 * size
    }
}

private extension simd_float4x4 {
    var position: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
    var forward: SIMD3<Float> { SIMD3(columns.2.x, columns.2.y, columns.2.z) }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : width * height }
}
