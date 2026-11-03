import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GLBPreviewOptimizer {
    struct Output { let data: Data; let reducedTextures: Int }
    static func optimize(_ data: Data, limit: Int, cancelled: () -> Bool) throws -> Output {
        func word(_ offset: Int) -> Int {
            guard offset >= 0, offset + 4 <= data.count else { return -1 }
            return data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
        guard data.count >= 4, word(0) == 0x46546c67 else { return Output(data: data, reducedTextures: 0) }
        guard data.count >= 20, word(4) == 2, word(8) == data.count, word(16) == 0x4e4f534a,
              word(12) > 0, word(12) <= data.count - 20 else { throw CocoaError(.fileReadCorruptFile) }
        guard limit > 0 else { return Output(data: data, reducedTextures: 0) }
        let jsonEnd = 20 + word(12)
        guard var json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<jsonEnd)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        guard jsonEnd + 8 <= data.count, word(jsonEnd+4) == 0x004e4942,
              word(jsonEnd) == data.count - jsonEnd - 8,
              let images = json["images"] as? [[String: Any]],
              var views = json["bufferViews"] as? [[String: Any]],
              var buffers = json["buffers"] as? [[String: Any]], !buffers.isEmpty,
              buffers[0]["uri"] == nil else { return Output(data: data, reducedTextures: 0) }
        // Unknown buffer-view extensions can encode offsets we cannot safely relocate.
        if views.contains(where: { view in
            let keys = (view["extensions"] as? [String: Any])?.keys.map { $0 } ?? []
            return keys.contains { $0 != "EXT_meshopt_compression" }
        }) { return Output(data: data, reducedTextures: 0) }
        let binary = data.subdata(in: jsonEnd+8..<data.count)
        func slice(_ offset: Int, _ length: Int) throws -> Data {
            guard offset >= 0, length >= 0, offset <= binary.count, length <= binary.count - offset else { throw CocoaError(.fileReadCorruptFile) }
            return binary.subdata(in: offset..<offset+length)
        }
        var protectedViews = Set<Int>()
        func collectViews(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if key == "bufferView", let index = child as? Int { protectedViews.insert(index) }
                    else { collectViews(child) }
                }
            } else if let array = value as? [Any] { array.forEach(collectViews) }
        }
        for (key, value) in json where key != "images" { collectViews(value) }
        var replacements = [Int: Data]()
        for index in images.indices {
            if cancelled() { throw CocoaError(.userCancelled) }
            guard let viewIndex = images[index]["bufferView"] as? Int, views.indices.contains(viewIndex), !protectedViews.contains(viewIndex),
                  (views[viewIndex]["buffer"] as? Int ?? 0) == 0,
                  let mime = images[index]["mimeType"] as? String, ["image/png", "image/jpeg"].contains(mime),
                  let length = views[viewIndex]["byteLength"] as? Int else { continue }
            let encoded = try slice(views[viewIndex]["byteOffset"] as? Int ?? 0, length)
            guard let source = CGImageSourceCreateWithData(encoded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0) > limit else { continue }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let output = NSMutableData()
            let type = mime == "image/jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
            guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            replacements[viewIndex] = output as Data
        }
        guard !replacements.isEmpty else { return Output(data: data, reducedTextures: 0) }
        var packed = Data()
        func append(_ bytes: Data) throws -> Int {
            guard bytes.count <= max(data.count, 16 * 1024 * 1024) * 2 - packed.count else { throw CocoaError(.fileReadCorruptFile) }
            while packed.count % 4 != 0 { packed.append(0) }
            let offset = packed.count
            packed.append(bytes)
            return offset
        }
        for index in views.indices {
            if cancelled() { throw CocoaError(.userCancelled) }
            let view = views[index]
            if (view["buffer"] as? Int ?? 0) == 0 {
                guard let length = view["byteLength"] as? Int else { throw CocoaError(.fileReadCorruptFile) }
                let bytes = try replacements[index] ?? slice(view["byteOffset"] as? Int ?? 0, length)
                views[index]["byteOffset"] = try append(bytes)
                views[index]["byteLength"] = bytes.count
            }
            if var extensions = view["extensions"] as? [String: Any], var meshopt = extensions["EXT_meshopt_compression"] as? [String: Any], (meshopt["buffer"] as? Int ?? 0) == 0 {
                guard let length = meshopt["byteLength"] as? Int else { throw CocoaError(.fileReadCorruptFile) }
                meshopt["byteOffset"] = try append(slice(meshopt["byteOffset"] as? Int ?? 0, length))
                extensions["EXT_meshopt_compression"] = meshopt
                views[index]["extensions"] = extensions
            }
        }
        buffers[0]["byteLength"] = packed.count
        json["buffers"] = buffers; json["bufferViews"] = views; json["images"] = images
        var encoded = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while encoded.count % 4 != 0 { encoded.append(0x20) }
        while packed.count % 4 != 0 { packed.append(0) }
        guard encoded.count + packed.count + 28 <= Int(UInt32.max) else { throw CocoaError(.fileReadCorruptFile) }
        var result = Data()
        func emit(_ value: Int) { var value = UInt32(value).littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        emit(0x46546c67); emit(2); emit(12+8+encoded.count+8+packed.count)
        emit(encoded.count); emit(0x4e4f534a); result.append(encoded)
        emit(packed.count); emit(0x004e4942); result.append(packed)
        return Output(data: result, reducedTextures: replacements.count)
    }
}
