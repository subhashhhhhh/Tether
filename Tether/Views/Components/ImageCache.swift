//
//  ImageCache.swift
//  Tether
//
//  Pictures from the phone (contact photos, app glyphs, attachment previews,
//  album art) decoded once and downsampled to the size they're drawn at,
//  not decoded again on every redraw at full size.
//

import AppKit
import ImageIO

enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// The image in `data`, at most `maxPixels` on its longer side. `key`
    /// names the picture; by default its bytes do.
    static func image(_ data: Data, key: String? = nil, maxPixels: Int = 256) -> NSImage? {
        let cacheKey = "\(key ?? String(data.hashValue)):\(data.count):\(maxPixels)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}
