import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImagePreview: Sendable {
  let bytes: Data
  let width: Int
  let height: Int
  let originalWidth: Int
  let originalHeight: Int
  var content: JSONValue {
    ["type": "image", "mimeType": "image/jpeg", "data": .string(bytes.base64EncodedString())]
  }
  var metadata: JSONValue {
    ["width": .int(width), "height": .int(height), "originalWidth": .int(originalWidth),
     "originalHeight": .int(originalHeight), "mimeType": "image/jpeg", "preview": true]
  }
  static func make(_ bytes: Data, maxDimension: Int = 1600) throws -> Self {
    guard (320...2048).contains(maxDimension),
          let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 50_000, height <= 50_000, width * height <= 200_000_000,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension, kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else {
      throw Failure("unsupported_image", "This is not a supported, bounded raster image.", "Use PNG, JPEG, HEIC or another ImageIO-supported raster format.")
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw Failure.invalid("Cannot encode the image preview.")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length <= 4_194_304 else {
      throw Failure.invalid("Preview exceeds 4 MiB; request a smaller maxDimension.")
    }
    return Self(bytes: output as Data, width: image.width, height: image.height, originalWidth: width, originalHeight: height)
  }
}
