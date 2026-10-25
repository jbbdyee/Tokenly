// Raw (no colour management) pixel access for an 8-bit RGB(A) PNG.
import Foundation
import ImageIO
import CoreGraphics
struct Raw {
    let w: Int, h: Int, bpr: Int, bpp: Int, data: [UInt8], image: CGImage
    init(_ path: String) {
        let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        w = image.width; h = image.height; bpr = image.bytesPerRow; bpp = image.bitsPerPixel / 8
        let d = image.dataProvider!.data! as Data
        data = [UInt8](d)
    }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = y * bpr + x * bpp; return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2])) }
}
extension Raw {
    init(fromImage img: CGImage) {
        // Render into a known straight-RGBA buffer layout? Keep the image's own bytes (values untouched).
        image = img; w = img.width; h = img.height; bpr = img.bytesPerRow; bpp = img.bitsPerPixel / 8
        data = [UInt8](img.dataProvider!.data! as Data)
    }
}
