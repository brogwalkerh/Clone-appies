import Foundation
import ClutterModule
#if canImport(Vision)
import Vision
#endif

/// `ImageFeatureProvider` backed by Vision's `VNGenerateImageFeaturePrintRequest`.
/// `SimilarImagesScanner` clusters the returned vectors by cosine distance.
///
/// The request runs on a detached utility task so a Pictures-folder scan never
/// blocks the main actor; `nil` means "not an image or Vision could not read it".
public struct VisionImageFeatureProvider: ImageFeatureProvider {
    /// Lowercased path extensions worth handing to Vision. Anything else is
    /// skipped up front so the scanner does not pay for a failed request per file.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "dng", "raw", "cr2", "nef", "arw"
    ]

    public init() {}

    public func featurePrint(for url: URL) async throws -> [Float]? {
        guard VisionImageFeatureProvider.looksLikeImage(url) else { return nil }
        #if canImport(Vision)
        let target = url
        return await Task.detached(priority: .utility) {
            VisionImageFeatureProvider.computeFeaturePrint(at: target)
        }.value
        #else
        return nil
        #endif
    }

    static func looksLikeImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    #if canImport(Vision)
    /// Synchronous Vision call; always invoked off the main actor.
    private static func computeFeaturePrint(at url: URL) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return observation.floatVector
    }
    #endif
}

#if canImport(Vision)
extension VNFeaturePrintObservation {
    /// Copies the feature print into a `[Float]`. Only `.float` element types are
    /// supported; `.double` prints (not produced by this request today) yield `nil`.
    var floatVector: [Float]? {
        guard elementType == .float, elementCount > 0 else { return nil }
        let stride = MemoryLayout<Float>.stride
        guard data.count >= elementCount * stride else { return nil }
        // `Data` storage is not guaranteed to be 4-byte aligned, so read each
        // element unaligned instead of binding the buffer to `Float`.
        return data.withUnsafeBytes { raw -> [Float] in
            (0..<elementCount).map { raw.loadUnaligned(fromByteOffset: $0 * stride, as: Float.self) }
        }
    }
}
#endif
