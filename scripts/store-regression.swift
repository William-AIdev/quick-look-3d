import Cocoa
import ImageIO
func check(_ value: Bool, _ message: String) { if !value { print("FAIL: \(message)"); exit(1) }; print("PASS: \(message)") }
func spin(until done: () -> Bool) { let end = Date().addingTimeInterval(30); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }; check(done(), "asynchronous preload completes") }
let app = NSApplication.shared
let repository = URL(fileURLWithPath: CommandLine.arguments[1])
let work = repository.appendingPathComponent("build/store-regression-" + UUID().uuidString)
let fm = FileManager.default
try fm.createDirectory(at: work, withIntermediateDirectories: true)
let store = try PreviewStore(root: work.appendingPathComponent("store"))
var settings = PreviewSettings()
settings.framesPerSecond = 15
try store.save(settings)
check(try PreviewStore(root: work.appendingPathComponent("store")).settings() == settings, "settings survive a new store instance")
let fixture = repository.appendingPathComponent("renderer/tests/fixtures/textured.glb")
let source = work.appendingPathComponent("model.glb")
try fm.copyItem(at: fixture, to: source)
let first = try store.prepare(source, settings: settings)
check(!first.cacheHit && first.reducedTextures == 1, "cold import downsizes embedded texture")
let hit = try store.prepare(source, settings: settings)
check(hit.cacheHit && hit.data == first.data, "warm import reuses persistent payload")
func word(_ data: Data, _ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) } }
func imageWidth(_ data: Data) throws -> Int {
 let end = 20 + word(data, 12)
 let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<end)) as! [String: Any]
 let images = json["images"] as! [[String: Any]]; let views = json["bufferViews"] as! [[String: Any]]
 let view = views[images[0]["bufferView"] as! Int]; let start = end + 8 + (view["byteOffset"] as? Int ?? 0)
 let bytes = data.subdata(in: start..<start+(view["byteLength"] as! Int))
 let image = CGImageSourceCreateWithData(bytes as CFData, nil)!
 return (CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary)[kCGImagePropertyPixelWidth] as! Int
}
check(try imageWidth(first.data) == 1024, "economy texture is 1024 pixels")
for name in ["textured-draco", "textured-meshopt"] {
 let prepared = try store.prepare(repository.appendingPathComponent("renderer/tests/fixtures/"+name+".glb"), settings: settings)
 check(prepared.reducedTextures == 1, "combined compressed texture optimized: " + name)
 try prepared.data.write(to: repository.appendingPathComponent("build/"+name+"-optimized.glb"))
}
try first.data.write(to: repository.appendingPathComponent("build/textured-optimized.glb"))
var original = settings; original.quality = "original"
let full = try store.prepare(source, settings: original)
check(!full.cacheHit && full.reducedTextures == 0, "quality change invalidates cache variant")
check(try imageWidth(full.data) == 4096, "original quality retains 4096 pixels")
try fm.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: source.path)
check(try !store.prepare(source, settings: settings).cacheHit, "source modification invalidates cache")
let cache = store.root.appendingPathComponent("Previews-v1")
for file in try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) where file.pathExtension == "bin" { try Data("corrupt".utf8).write(to: file) }
check(try !store.prepare(source, settings: settings).cacheHit, "checksum rejects corrupt payload")
try Data("orphan".utf8).write(to: cache.appendingPathComponent("orphan.bin"))
try store.save(settings)
check(!fm.fileExists(atPath: cache.appendingPathComponent("orphan.bin").path), "orphan entry cleaned")
try store.clear()
check(try store.statistics().count == 0, "clear removes entries")
var small = settings; small.cacheMegabytes = 64; small.quality = "original"
for index in 0..<3 {
 let file = work.appendingPathComponent("large-\(index).fbx")
 try Data(repeating: UInt8(index), count: 24*1024*1024).write(to: file)
 _ = try store.prepare(file, settings: small)
}
let stats = try store.statistics()
check(stats.bytes <= 64*1024*1024 && stats.count == 2, "LRU cache stays within 64 MiB quota")
var capped = settings; capped.maximumFileMegabytes = 16
var refused = false
do { _ = try store.prepare(work.appendingPathComponent("large-0.fbx"), settings: capped) } catch { refused = true }
check(refused, "oversized source rejected before read")
var cancelled = false
do { _ = try store.prepare(source, settings: settings, cancelled: { true }) } catch { cancelled = true }
check(cancelled, "preparation honors cancellation")
var malformed = Data(); for value: UInt32 in [0x46546c67,2,24,4,0x4e4f534a] { var v = value.littleEndian; withUnsafeBytes(of: &v) { malformed.append(contentsOf: $0) } }; malformed.append(Data("[]  ".utf8))
var rejected = false
do { _ = try GLBPreviewOptimizer.optimize(malformed, limit: 1024, cancelled: { false }) } catch { rejected = true }
check(rejected, "non-object GLB JSON fails without crashing")
let folder = work.appendingPathComponent("folder")
try fm.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
let triangle = try Data(contentsOf: repository.appendingPathComponent("renderer/tests/fixtures/plain.glb"))
for index in 0..<100 { try triangle.write(to: folder.appendingPathComponent("\(index).glb")) }
try triangle.write(to: folder.appendingPathComponent("nested/extra.VRM"))
try triangle.write(to: folder.appendingPathComponent("ignored.txt"))
try fm.createSymbolicLink(at: folder.appendingPathComponent("link.glb"), withDestinationURL: source)
check(try FolderScanner.scan(folder, recursive: false, cancelled: { false }).count == 100, "non-recursive scan skips subfolders and symlinks")
check(try FolderScanner.scan(folder, recursive: true, cancelled: { false }).count == 101, "recursive scan counts only supported regular files")
try store.clear()
let model = PreloadModel(store: store)
var confirmations = 0
model.confirmLargeImport = { count in confirmations += 1; check(count == 101, "confirmation counts supported models"); return false }
model.importFolder(folder); spin(until: { !model.busy })
check(confirmations == 1 && model.completed == 0, "101-file decline performs no preparation")
check(try store.statistics().count == 0, "declined import writes no cache")
model.settings.recursive = false
model.importFolder(folder); spin(until: { !model.busy })
check(confirmations == 1 && model.completed == 100, "100-file import needs no confirmation")
model.settings.recursive = true
model.confirmLargeImport = { _ in confirmations += 1; model.cancel(); return true }
model.importFolder(folder); spin(until: { !model.busy })
check(confirmations == 2 && model.completed == 0, "cancellation stops confirmed import before first model")
print("PASS: store and preload regression complete")
