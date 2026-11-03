import ImageIO
import UIKit
import os

/// Loads remote images downsampled to the pixel size they're shown at.
/// Decoding happens off the main thread; decoded images live in a
/// cost-limited memory cache, encoded bytes in a disk URLCache.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let decodeQueue = DispatchQueue(label: "duocord.image.decode", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]
    private let log = Logger(subsystem: "com.saphid.duocord.native", category: "images")

    private init() {
        memory.totalCostLimit = 96 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    /// Discord's media proxy resizes on request; asking for the display size
    /// cuts bytes and decode time for large uploads.
    static func sized(_ url: URL, pixelWidth: Int, pixelHeight: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if components.host == "cdn.discordapp.com", components.path.hasPrefix("/attachments/") {
            components.host = "media.discordapp.net"
        }
        guard components.host == "media.discordapp.net" else { return url }
        var items = (components.queryItems ?? []).filter { !["width", "height", "format", "quality"].contains($0.name) }
        items.append(URLQueryItem(name: "format", value: "webp"))
        items.append(URLQueryItem(name: "quality", value: "lossless"))
        items.append(URLQueryItem(name: "width", value: String(pixelWidth)))
        items.append(URLQueryItem(name: "height", value: String(pixelHeight)))
        components.queryItems = items
        return components.url ?? url
    }

    private static func key(_ url: URL, _ size: CGSize) -> String { "\(url.absoluteString)#\(Int(size.width))x\(Int(size.height))" }

    func cached(_ url: URL, pointSize: CGSize) -> UIImage? {
        memory.object(forKey: Self.key(url, pointSize) as NSString)
    }

    /// Loads `url` for display at `pointSize`. Completion runs on the main thread.
    @discardableResult
    func load(_ url: URL, pointSize: CGSize, scale: CGFloat = 3, completion: @escaping @MainActor (UIImage?) -> Void) -> String {
        let key = Self.key(url, pointSize)
        if let image = memory.object(forKey: key as NSString) {
            MainActor.assumeIsolated { completion(image) }
            return key
        }
        let deliver: (UIImage?) -> Void = { image in DispatchQueue.main.async { completion(image) } }
        lock.lock()
        if inFlight[key] != nil {
            inFlight[key]?.append(deliver)
            lock.unlock()
            return key
        }
        inFlight[key] = [deliver]
        lock.unlock()

        let maxPixel = Int(max(pointSize.width, pointSize.height) * scale)
        if url.scheme == "mock" {
            decodeQueue.async { [self] in finish(key, image: MockImages.image(for: url, pointSize: pointSize, scale: scale)) }
            return key
        }
        let task = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, error == nil else {
                self.finish(key, image: nil)
                return
            }
            self.decodeQueue.async {
                self.finish(key, image: Self.downsample(data, maxPixel: maxPixel, scale: scale))
            }
        }
        task.priority = URLSessionTask.highPriority
        task.resume()
        return key
    }

    private func finish(_ key: String, image: UIImage?) {
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key as NSString, cost: cost)
        }
        lock.lock()
        let waiters = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        for waiter in waiters { waiter(image) }
    }

    /// ImageIO thumbnailing decodes straight to the target size and forces
    /// decoding here so the main thread never decompresses.
    nonisolated static func downsample(_ data: Data, maxPixel: Int, scale: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    func clearMemory() { memory.removeAllObjects() }
}

/// Deterministic generated images for the mock data set: `mock://image/<seed>/<w>x<h>`.
nonisolated enum MockImages {
    /// FNV-1a, so generated images are the same on every launch.
    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash & 0x7FFF_FFFF_FFFF)
    }

    static func image(for url: URL, pointSize: CGSize, scale: CGFloat) -> UIImage? {
        let seed = stableHash(url.absoluteString)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let size = CGSize(width: max(1, pointSize.width), height: max(1, pointSize.height))
        let hue = CGFloat(seed % 360) / 360
        let isAvatar = url.host == "avatar"
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor,
                          UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.45, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            if !isAvatar {
                // A few shapes so scrolling content is visibly distinct.
                for i in 0..<5 {
                    let r = CGFloat((seed >> (i * 3)) % 40 + 20) / 100 * min(size.width, size.height) / 2
                    let x = CGFloat((seed >> (i * 2)) % 100) / 100 * size.width
                    let y = CGFloat((seed >> (i * 4)) % 100) / 100 * size.height
                    UIColor.white.withAlphaComponent(0.12 + CGFloat(i) * 0.04).setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
        }
    }
}
