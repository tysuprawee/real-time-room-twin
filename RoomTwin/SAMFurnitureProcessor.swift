import Foundation
import simd

struct SAMFurnitureProgress: Equatable {
    let title: String
    let detail: String
    let fraction: Double
}

struct SAMFurnitureReplacement {
    let targetIdentifier: String
    let category: String
    let targetDimensions: SIMD3<Float>
    let targetTransform: simd_float4x4
    let mesh: MeshSnapshot
    /// The manually captured image used to create this model. It becomes the
    /// thumbnail when the generated object is added to My Objects.
    let sourcePhoto: URL
}

private struct SAMFurnitureServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Turns the one best photo captured for each RoomPlan furniture item into a
/// world-positioned SAM 3D mesh. The result is not exposed to the preview until
/// every successful replacement has been downloaded and fitted into the room.
enum SAMFurnitureProcessor {
    typealias Progress = @MainActor (SAMFurnitureProgress) -> Void

    @MainActor
    static func run(folder: URL, photos: [KeyframeRecorder.SavedKeyframe],
                    progress: Progress) async throws -> [SAMFurnitureReplacement] {
        guard !photos.isEmpty else {
            progress(.init(title: "Keeping original furniture",
                           detail: "No optional photos taken", fraction: 0.94))
            return []
        }
        guard let config = ObjectServerConfig.load() else {
            throw SAMFurnitureServerError(message: "Start the SAM server with ObjectServer/start.sh before using SAM Furniture.")
        }
        let candidates = Client.candidates(config)
        progress(.init(title: "Connecting to SAM 3D",
                       detail: candidates.count > 1 ? "Checking Colab and fal.ai fallback" : "Checking the generation server",
                       fraction: 0.08))
        var clients: [Client] = []
        var connectionFailures: [String] = []
        for client in candidates {
            do {
                let health: HealthReply = try await client.send("GET", "health", timeout: 8)
                guard health.generator.state == "ready" || health.generator.state == "loading" else {
                    throw SAMFurnitureServerError(message: health.generator.message
                        ?? "generator is \(health.generator.state)")
                }
                clients.append(client)
            } catch {
                connectionFailures.append("\(client.label): \(error.localizedDescription)")
                Diagnostics.log("SAM provider \(client.label) unavailable: \(error)")
            }
        }
        guard !clients.isEmpty else {
            throw SAMFurnitureServerError(message: connectionFailures.first
                ?? "No SAM provider is running. Start ObjectServer/start.sh, then tap Retry.")
        }

        let output = folder.appendingPathComponent("sam-replacements")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var replacements: [SAMFurnitureReplacement] = []
        var failures: [String] = []
        for (index, photo) in photos.enumerated() {
            guard let identifier = photo.targetIdentifier, let category = photo.targetCategory else { continue }
            let number = index + 1
            let base = 0.1 + 0.82 * Double(index) / Double(photos.count)
            let share = 0.82 / Double(photos.count)
            var errors: [String] = []
            var completed: SAMFurnitureReplacement?
            for (providerIndex, client) in clients.enumerated() {
                if providerIndex > 0 {
                    progress(.init(title: "Switching \(category) to fal.ai",
                                   detail: "The local SAM attempt failed · retrying the same manual photo",
                                   fraction: base + 0.12 * share))
                }
                do {
                    completed = try await replacement(
                        photo: photo, identifier: identifier, category: category,
                        folder: folder, output: output, client: client,
                        number: number, total: photos.count, base: base, share: share,
                        progress: progress)
                    break
                } catch {
                    errors.append("\(client.label): \(error.localizedDescription)")
                    Diagnostics.log("SAM furniture \(category) on \(client.label) failed: \(error)")
                }
            }
            if let completed {
                replacements.append(completed)
            } else {
                failures.append("\(category): \(errors.last ?? "all SAM providers failed")")
            }
        }
        guard !replacements.isEmpty else {
            throw SAMFurnitureServerError(message: failures.first ?? "SAM 3D could not replace the detected furniture.")
        }
        progress(.init(title: "Rebuilding the detailed room",
                       detail: failures.isEmpty ? "Filling the surfaces behind each replacement"
                           : "\(replacements.count) replaced · \(failures.count) left as scanned",
                       fraction: 0.94))
        return replacements
    }

    @MainActor
    private static func replacement(
        photo: KeyframeRecorder.SavedKeyframe, identifier: String, category: String,
        folder: URL, output: URL, client: Client, number: Int, total: Int,
        base: Double, share: Double, progress: Progress
    ) async throws -> SAMFurnitureReplacement {
        progress(.init(title: "Uploading \(category)",
                       detail: "Furniture \(number) of \(total) · \(client.label) · one manual photo",
                       fraction: base))
        let files = try await Task.detached(priority: .utility) {
            () throws -> (image: Data, depth: Data, confidence: Data) in
            try SAMFurnitureProcessor.files(for: photo, in: folder)
        }.value
        let entryData = try JSONEncoder().encode(photo)
        let entry = try JSONSerialization.jsonObject(with: entryData) as! [String: Any]
        let added: PhotoReply = try await client.send("POST", "photos", [
            "entry": entry,
            "image": files.image.base64EncodedString(),
            "depth": files.depth.base64EncodedString(),
            "confidence": files.confidence.base64EncodedString(),
        ], timeout: 90)

        progress(.init(title: "Finding \(category)",
                       detail: "\(client.label) is constrained to the detected RoomPlan box",
                       fraction: base + 0.15 * share))
        let segmented: SegmentReply = try await client.send(
            "POST", "photos/\(added.id)/segment", ["prompt": prompt(for: category)], timeout: 240)
        let job: JobReply = try await client.send(
            "POST", "photos/\(added.id)/generate", ["mask": segmented.mask, "preserveWorld": true],
            timeout: 20)

        let started = Date()
        while true {
            try await Task.sleep(for: .seconds(1))
            let status: JobStatus = try await client.send("GET", "jobs/\(job.job)", timeout: 15)
            if status.state == "done" { break }
            if status.state == "failed" {
                throw SAMFurnitureServerError(message: status.message ?? "SAM 3D generation failed")
            }
            let elapsed = Int(Date().timeIntervalSince(started))
            if elapsed >= 420 {
                throw SAMFurnitureServerError(message: "\(client.label) timed out after 7 minutes.")
            }
            progress(.init(title: "Building \(category) in 3D",
                           detail: "Furniture \(number) of \(total) · \(status.provider ?? client.label) · "
                               + "\(status.message ?? "Working") · \(elapsed)s",
                           fraction: base + 0.2 * share + min(Double(elapsed) / 120, 0.72) * share))
        }

        progress(.init(title: "Downloading \(category)",
                       detail: "\(client.label) · keeping its RoomPlan position", fraction: base + 0.94 * share))
        let data = try await client.data("GET", "jobs/\(job.job)/model.ply", timeout: 120)
        let url = output.appendingPathComponent("\(identifier).ply")
        let downloaded = try await Task.detached { () -> MeshSnapshot in
            try data.write(to: url, options: .atomic)
            return try MeshSnapshot(ply: url)
        }.value
        guard !downloaded.faces.isEmpty else {
            throw SAMFurnitureServerError(message: "SAM returned an empty \(category) model")
        }
        guard let dimensions = photo.targetDimensions, dimensions.count == 3,
              let transform = photo.targetTransform, transform.count == 16 else {
            throw SAMFurnitureServerError(message: "The saved \(category) target has no RoomPlan pose.")
        }
        let targetDimensions = SIMD3(dimensions[0], dimensions[1], dimensions[2])
        let targetTransform = simd_float4x4(columns: (
            SIMD4(transform[0], transform[1], transform[2], transform[3]),
            SIMD4(transform[4], transform[5], transform[6], transform[7]),
            SIMD4(transform[8], transform[9], transform[10], transform[11]),
            SIMD4(transform[12], transform[13], transform[14], transform[15])))
        let mesh = fit(downloaded, to: targetDimensions, transform: targetTransform)
        try await Task.detached(priority: .utility) { try mesh.writePLY(to: url) }.value
        return .init(
            targetIdentifier: identifier, category: category,
            targetDimensions: targetDimensions,
            targetTransform: targetTransform,
            mesh: mesh,
            sourcePhoto: folder.appendingPathComponent(photo.image))
    }

    /// Normalizes both local-SAM and fal.ai output into the same upright,
    /// uniformly scaled RoomPlan box. Providers may differ in world pose, but
    /// the semantic box is the stable placement authority.
    private static func fit(_ source: MeshSnapshot, to dimensions: SIMD3<Float>,
                            transform: simd_float4x4) -> MeshSnapshot {
        var output = source
        guard !source.positions.isEmpty, all(dimensions .> SIMD3<Float>(repeating: 1e-4)) else { return output }
        let target = upright(transform)
        let inverse = target.inverse
        var local = source.positions.map { point -> SIMD3<Float> in
            let transformed = inverse * SIMD4(point, 1)
            return SIMD3(transformed.x, transformed.y, transformed.z)
        }

        func bounds(_ points: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>) {
            (points.reduce(SIMD3<Float>(repeating: .infinity), simd_min),
             points.reduce(SIMD3<Float>(repeating: -.infinity), simd_max))
        }
        var (low, high) = bounds(local)
        var size = simd_max(high - low, SIMD3<Float>(repeating: 1e-4))
        let sourceRatio = size.x / size.z
        let targetRatio = dimensions.x / dimensions.z
        if abs(log(sourceRatio / targetRatio)) > abs(log((1 / sourceRatio) / targetRatio)) {
            local = local.map { SIMD3($0.z, $0.y, -$0.x) }
            (low, high) = bounds(local)
            size = simd_max(high - low, SIMD3<Float>(repeating: 1e-4))
        }
        let origin = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
        let scale = 0.96 * min(
            min(dimensions.x / size.x, dimensions.y / size.y),
            dimensions.z / size.z)
        output.positions = local.map { point in
            var fitted = (point - origin) * scale
            fitted.y -= dimensions.y / 2
            let transformed = target * SIMD4(fitted, 1)
            return SIMD3(transformed.x, transformed.y, transformed.z)
        }
        return output
    }

    private static func upright(_ transform: simd_float4x4) -> simd_float4x4 {
        var forward = SIMD3(transform.columns.2.x, 0, transform.columns.2.z)
        if simd_length_squared(forward) < 1e-5 {
            let right = SIMD3(transform.columns.0.x, 0, transform.columns.0.z)
            forward = SIMD3(-right.z, 0, right.x)
        }
        forward = simd_normalize(forward)
        let right = simd_normalize(SIMD3(forward.z, 0, -forward.x))
        var result = matrix_identity_float4x4
        result.columns.0 = SIMD4(right, 0)
        result.columns.1 = SIMD4(0, 1, 0, 0)
        result.columns.2 = SIMD4(forward, 0)
        result.columns.3 = SIMD4(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, 1)
        return result
    }

    private static func prompt(for category: String) -> String {
        switch category {
        case "storage": "cabinet"
        case "washerDryer": "washer dryer"
        default: category
        }
    }

    private static func files(for photo: KeyframeRecorder.SavedKeyframe, in folder: URL) throws
        -> (image: Data, depth: Data, confidence: Data) {
        (try Data(contentsOf: folder.appendingPathComponent(photo.image)),
         try Data(contentsOf: folder.appendingPathComponent(photo.depth)),
         try Data(contentsOf: folder.appendingPathComponent(photo.confidence)))
    }

    private struct PhotoReply: Decodable { let id: String }
    private struct SegmentReply: Decodable { let mask: Int }
    private struct JobReply: Decodable { let job: String }
    private struct JobStatus: Decodable {
        let state: String
        let message: String?
        let provider: String?
    }
    private struct HealthReply: Decodable {
        struct Generator: Decodable {
            let state: String
            let provider: String?
            let message: String?
        }
        let generator: Generator
    }

    private struct Client {
        let url: String
        let token: String
        let label: String

        static func candidates(_ config: ObjectServerConfig) -> [Client] {
            let primaryLabel = config.provider == "fal.ai" ? "fal.ai" : "Local SAM 3D"
            var values = [Client(url: config.url, token: config.token, label: primaryLabel)]
            if let fallback = config.fallbackURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fallback.isEmpty, fallback != config.url {
                values.append(Client(url: fallback, token: config.token, label: "fal.ai"))
            } else if config.provider == "fal.ai" {
                values[0] = Client(url: config.url, token: config.token, label: "fal.ai")
            }
            return values
        }

        func send<Reply: Decodable>(_ method: String, _ path: String,
                                    _ body: [String: Any]? = nil,
                                    timeout: TimeInterval = 30) async throws -> Reply {
            try JSONDecoder().decode(Reply.self, from: await data(method, path, body, timeout: timeout))
        }

        func data(_ method: String, _ path: String, _ body: [String: Any]? = nil,
                  timeout: TimeInterval = 30) async throws -> Data {
            guard let base = URL(string: url) else {
                throw SAMFurnitureServerError(message: "The SAM server address is invalid.")
            }
            var request = URLRequest(url: base.appending(path: path))
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue(token, forHTTPHeaderField: "X-Token")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError {
                let address = base.host ?? "the configured server"
                switch error.code {
                case .timedOut:
                    throw SAMFurnitureServerError(message:
                        "\(label) did not answer \(path) within \(Int(timeout)) seconds.")
                case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
                     .notConnectedToInternet, .secureConnectionFailed:
                    throw SAMFurnitureServerError(message:
                        "Cannot reach \(label) at \(address). Keep ObjectServer/start.sh running.")
                default:
                    throw SAMFurnitureServerError(message: "\(label) connection failed: \(error.localizedDescription)")
                }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let server = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error
                throw SAMFurnitureServerError(message: server ?? "SAM server returned HTTP \(status)")
            }
            return data
        }
    }

    private struct ErrorReply: Decodable { let error: String }
}
