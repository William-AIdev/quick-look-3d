import Foundation

struct ModelInformation: Codable, Equatable {
    struct Texture: Codable, Equatable {
        var name: String
        var width: Int?
        var height: Int?
    }
    struct Animation: Codable, Equatable {
        var name: String
        var duration: Double
    }
    var vertices: Int
    var triangles: Int
    var materials: Int
    var textures: [Texture]
    var animations: [Animation]
}

enum InformationField: String, CaseIterable, Codable, Identifiable {
    case fps, vertices, triangles, materials, textures, animations
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fps: return "实时 FPS"
        case .vertices: return "顶点数"
        case .triangles: return "三角形数"
        case .materials: return "材质数"
        case .textures: return "纹理尺寸"
        case .animations: return "动画时长"
        }
    }
}
