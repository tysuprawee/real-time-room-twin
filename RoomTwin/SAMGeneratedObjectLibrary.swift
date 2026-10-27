import Foundation
import UIKit

/// Persists every successful SAM 3D result in the signed-in user's object
/// library. A marker beside the generated model makes Retry idempotent.
@MainActor
enum SAMGeneratedObjectLibrary {
    struct Result {
        var saved = 0
        var alreadySaved = 0
        var failures: [String] = []
    }

    static func save(_ replacements: [SAMFurnitureReplacement],
                     in folder: URL, to account: Account,
                     progress: ((String) -> Void)? = nil) async -> Result {
        var result = Result()
        guard let user = account.session?.userID else {
            result.failures = replacements.map { "\($0.category): Log in to save this object." }
            return result
        }
        let output = folder.appendingPathComponent("sam-replacements")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (index, replacement) in replacements.enumerated() {
            let stem = replacement.targetIdentifier.lowercased()
            let marker = output.appendingPathComponent("\(stem).\(user).owner-drive-library-saved")
            if FileManager.default.fileExists(atPath: marker.path) {
                result.alreadySaved += 1
                continue
            }
            progress?("Adding \(replacement.category) to My Objects · \(index + 1) of \(replacements.count)")
            do {
                let model = output.appendingPathComponent("\(stem).usdz")
                if !FileManager.default.fileExists(atPath: model.path) {
                    let source = replacement.mesh
                    try await Task.detached(priority: .utility) {
                        var libraryMesh = source
                        guard let low = libraryMesh.positions.reduce(nil as SIMD3<Float>?, { value, point in
                            value.map { simd_min($0, point) } ?? point
                        }), let high = libraryMesh.positions.reduce(nil as SIMD3<Float>?, { value, point in
                            value.map { simd_max($0, point) } ?? point
                        }) else { return }
                        let origin = SIMD3((low.x + high.x) / 2, low.y, (low.z + high.z) / 2)
                        libraryMesh.positions = libraryMesh.positions.map { $0 - origin }
                        try libraryMesh.writeUSDZ(to: model)
                    }.value
                }
                let thumbnail = UIImage(contentsOfFile: replacement.sourcePhoto.path)
                try await account.save(model: model, thumbnail: thumbnail,
                                       name: "SAM 3D \(displayName(replacement.category))")
                try Data("saved".utf8).write(to: marker, options: .atomic)
                result.saved += 1
            } catch {
                result.failures.append("\(replacement.category): \(error.localizedDescription)")
                Diagnostics.log("SAM library save failed for \(replacement.category): \(error)")
            }
        }
        return result
    }

    private static func displayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                 options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
