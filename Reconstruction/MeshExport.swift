import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A compacted copy of the live mesh.
struct MeshSnapshot {
    struct EditableObject {
        /// Human-readable RoomPlan category, made unique within the room.
        var name: String
        /// Faces occupied by this object in the untouched snapshot. The face
        /// list is explicit rather than assumed contiguous, so semantic and
        /// imported geometry can use the same edit pipeline.
        var faces: [Int]
    }

    var positions: [SIMD3<Float>] = []
    var colors: [SIMD3<UInt8>] = []
    var faces: [SIMD3<UInt32>] = []
    /// Pool index of each snapshot vertex.
    var poolIndices: [Int32] = []
    /// Named object groups are populated by RoomPlan or Hybrid segmentation.
    /// Plain Detailed Mesh scans have no semantic labels, so this stays empty.
    var editableObjects: [EditableObject] = []
}

extension Reconstructor {
    /// Copies the mesh out of the pools. Only call while the GPU is not integrating.
    func snapshot() -> MeshSnapshot {
        let c = counters.contents().bindMemory(to: Int32.self, capacity: Int(RT_COUNTER_COUNT))
        let slots = Int(c[Int(RT_COUNTER_TRIANGLE_HIGH_WATER)]) * Int(RT_MAX_TRIANGLES_PER_CUBE)
        let indices = triangles.contents().bindMemory(to: UInt32.self, capacity: slots * 3)
        let pool = vertices.contents().bindMemory(to: MeshVertex.self, capacity: settings.maxVertices)

        var mesh = MeshSnapshot()
        var remap = [Int32](repeating: -1, count: settings.maxVertices)
        for t in 0..<slots {
            let a = indices[3 * t], b = indices[3 * t + 1], c = indices[3 * t + 2]
            if a == b && b == c { continue }
            var face = SIMD3<UInt32>()
            for (j, index) in [a, b, c].enumerated() {
                if remap[Int(index)] < 0 {
                    remap[Int(index)] = Int32(mesh.positions.count)
                    let v = pool[Int(index)]
                    mesh.positions.append(SIMD3(v.position.0, v.position.1, v.position.2))
                    mesh.colors.append(SIMD3(UInt8(v.color & 0xFF), UInt8((v.color >> 8) & 0xFF), UInt8((v.color >> 16) & 0xFF)))
                    mesh.poolIndices.append(Int32(index))
                }
                face[j] = UInt32(remap[Int(index)])
            }
            mesh.faces.append(face)
        }
        return mesh
    }
}

extension MeshSnapshot {
    /// Binary PLY in metres, in ARKit's world frame (+y up).
    func writePLY(to url: URL) throws {
        var data = Data()
        let header = """
        ply
        format binary_little_endian 1.0
        comment RoomTwin scan, metres, +y up
        element vertex \(positions.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(faces.count)
        property list uchar int vertex_indices
        end_header

        """
        data.append(header.data(using: .ascii)!)
        data.reserveCapacity(data.count + positions.count * 15 + faces.count * 13)
        func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        for (p, c) in zip(positions, colors) {
            append(p.x.bitPattern.littleEndian)
            append(p.y.bitPattern.littleEndian)
            append(p.z.bitPattern.littleEndian)
            // Byte by byte: SIMD3<UInt8> is padded to 4 bytes in memory.
            append(c.x)
            append(c.y)
            append(c.z)
        }
        for f in faces {
            append(UInt8(3))
            append(Int32(f.x).littleEndian)
            append(Int32(f.y).littleEndian)
            append(Int32(f.z).littleEndian)
        }
        try data.write(to: url, options: .atomic)
    }
}

extension MeshSnapshot {
    /// Writes a .usdz that Quick Look previews on iPhone and Mac.
    ///
    /// Quick Look ignores per-vertex colors, so the colors are baked into a
    /// texture: each triangle gets a 2x2-texel cell holding its corner colors,
    /// and its UVs sit on those texel centers. Corners therefore can't share
    /// vertices, so the USDZ has 3 vertices per triangle.
    ///
    /// Viewers blend neighbouring cells when the model is small on screen, so
    /// triangles are sorted along a 3D Z-order curve and their cells laid out
    /// in 2D Z-order tiles: cells that get blended belong to nearby triangles.
    func writeUSDZ(to url: URL, adding nodes: [SCNNode] = []) throws {
        // Resolve image contents while all source assets are still available.
        // USDZ's writer can then package every texture with the full scene.
        let assets = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        let exportNodes = try nodes.map { try selfContainedExportNode($0, assets: assets) }
        if faces.isEmpty {
            guard !exportNodes.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            let scene = SCNScene()
            exportNodes.forEach { scene.rootNode.addChildNode($0) }
            guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return
        }
        guard !faces.isEmpty else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        let tileSide = 32, cellsPerTile = tileSide * tileSide
        let tileCount = (faces.count + cellsPerTile - 1) / cellsPerTile
        let tilesPerRow = Int(Double(tileCount).squareRoot().rounded(.up))
        let tileRows = (tileCount + tilesPerRow - 1) / tilesPerRow
        let width = tilesPerRow * tileSide * 2, height = tileRows * tileSide * 2
        let order = spatialOrder()

        // Smooth normals from area-weighted face normals; triangles wind
        // counter-clockwise seen from free space.
        var vertexNormals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for f in faces {
            let a = positions[Int(f.x)], b = positions[Int(f.y)], c = positions[Int(f.z)]
            let n = simd_cross(b - a, c - a)
            vertexNormals[Int(f.x)] += n
            vertexNormals[Int(f.y)] += n
            vertexNormals[Int(f.z)] += n
        }

        var texels = [UInt8](repeating: 255, count: width * height * 4)
        var points = [Float](), normals = [Float](), uvs = [Float]()
        points.reserveCapacity(faces.count * 9)
        normals.reserveCapacity(faces.count * 9)
        uvs.reserveCapacity(faces.count * 6)
        for (i, faceIndex) in order.enumerated() {
            let f = faces[faceIndex]
            let tile = i / cellsPerTile, cell = mortonDecode2D(UInt32(i % cellsPerTile))
            let x = ((tile % tilesPerRow) * tileSide + cell.x) * 2
            let y = ((tile / tilesPerRow) * tileSide + cell.y) * 2
            let corners = [Int(f.x), Int(f.y), Int(f.z)]
            // Texels (x, y), (x+1, y), (x, y+1) hold the corner colors; the
            // fourth, beyond the triangle, gets the mean of the other two.
            let cellTexels = [(x, y), (x + 1, y), (x, y + 1)]
            for (corner, (tx, ty)) in zip(corners, cellTexels) {
                let c = colors[corner]
                let t = (ty * width + tx) * 4
                texels[t] = c.x; texels[t + 1] = c.y; texels[t + 2] = c.z
                let p = positions[corner], n = simd_normalize(vertexNormals[corner])
                points += [p.x, p.y, p.z]
                normals += [n.x, n.y, n.z]
                uvs += [(Float(tx) + 0.5) / Float(width), (Float(ty) + 0.5) / Float(height)]
            }
            let b = colors[corners[1]], c = colors[corners[2]]
            let t = ((y + 1) * width + x + 1) * 4
            texels[t] = UInt8((UInt16(b.x) + UInt16(c.x)) / 2)
            texels[t + 1] = UInt8((UInt16(b.y) + UInt16(c.y)) / 2)
            texels[t + 2] = UInt8((UInt16(b.z) + UInt16(c.z)) / 2)
        }

        let textureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-color.png")
        try writePNG(texels, width: width, height: height, to: textureURL)
        defer { try? FileManager.default.removeItem(at: textureURL) }

        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBytes { Data($0) }, semantic: semantic,
                              vectorCount: values.count / components, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0,
                              dataStride: components * 4)
        }
        let indices = Array(0..<UInt32(faces.count * 3))
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                                         primitiveCount: faces.count, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source(points, .vertex, components: 3),
                                             source(normals, .normal, components: 3),
                                             source(uvs, .texcoord, components: 2)],
                                   elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = textureURL
        material.roughness.contents = 1.0
        material.metalness.contents = 0.0
        geometry.materials = [material]

        let scene = SCNScene()
        let node = SCNNode(geometry: geometry)
        node.name = "Scan"
        scene.rootNode.addChildNode(node)
        for decoration in exportNodes {
            scene.rootNode.addChildNode(decoration)
        }
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Face indices sorted by the 3D Z-order code of their centroids.
    private func spatialOrder() -> [Int] {
        let lo = positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let hi = positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let scale = 1023 / simd_max(hi - lo, SIMD3(repeating: 1e-6))
        let codes = faces.map { f -> UInt32 in
            let centroid = (positions[Int(f.x)] + positions[Int(f.y)] + positions[Int(f.z)]) / 3
            let q = SIMD3<UInt32>(simd_clamp((centroid - lo) * scale, .zero, SIMD3(repeating: 1023)))
            return spreadBits3(q.x) | spreadBits3(q.y) << 1 | spreadBits3(q.z) << 2
        }
        return codes.indices.sorted { codes[$0] < codes[$1] }
    }
}

/// Copy materials before resolving their image contents: SceneKit clones share
/// geometry/materials with the editor, so export must not change live materials.
private func selfContainedExportNode(_ source: SCNNode, assets: URL) throws -> SCNNode {
    let copy = source.clone()
    var failure: Error?
    copy.enumerateHierarchy { node, _ in
        guard failure == nil, let original = node.geometry,
              let geometry = original.copy() as? SCNGeometry else { return }
        node.geometry = geometry
        geometry.materials = original.materials.map { material in
            let result = material.copy() as! SCNMaterial
            let properties = [result.diffuse, result.normal, result.roughness, result.metalness,
                              result.ambientOcclusion, result.emission, result.transparent,
                              result.multiply, result.specular, result.displacement, result.reflective]
            for property in properties {
                do {
                    guard let image = try exportTextureImage(property.contents) else { continue }
                    let file = assets.appendingPathComponent(UUID().uuidString + ".png")
                    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                    property.contents = file
                } catch { failure = error }
            }
            return result
        }
    }
    if let failure { throw failure }
    return copy
}

private func exportTextureImage(_ contents: Any?) throws -> CGImage? {
    guard let contents else { return nil }
    // Core Foundation casts do not perform Swift's conditional type check.
    // Check the CF type identifier before interpreting the value as CGImage.
    if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
        return (contents as! CGImage)
    }
    #if canImport(UIKit)
    if let image = contents as? UIImage { return image.cgImage }
    #elseif canImport(AppKit)
    if let image = contents as? NSImage { return image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    #endif
    if let data = contents as? Data,
       let source = CGImageSourceCreateWithData(data as CFData, nil) {
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    let file: URL?
    if let url = contents as? URL { file = url }
    else if let path = contents as? String {
        file = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
    } else { file = nil }
    if let file, file.isFileURL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        return image
    }
    return nil
}

/// Spaces the low 10 bits of v two zero bits apart, for a 3D Morton code.
private func spreadBits3(_ v: UInt32) -> UInt32 {
    var x = v & 0x3FF
    x = (x | x << 16) & 0x030000FF
    x = (x | x << 8) & 0x0300F00F
    x = (x | x << 4) & 0x030C30C3
    x = (x | x << 2) & 0x09249249
    return x
}

/// Inverse of a 2D Morton code: even bits are x, odd bits are y.
private func mortonDecode2D(_ code: UInt32) -> (x: Int, y: Int) {
    func compact(_ v: UInt32) -> Int {
        var x = v & 0x55555555
        x = (x | x >> 1) & 0x33333333
        x = (x | x >> 2) & 0x0F0F0F0F
        x = (x | x >> 4) & 0x00FF00FF
        x = (x | x >> 8) & 0x0000FFFF
        return Int(x)
    }
    return (compact(code), compact(code >> 1))
}

private func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
    var pixels = rgba
    let image = pixels.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
    }
    guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}
