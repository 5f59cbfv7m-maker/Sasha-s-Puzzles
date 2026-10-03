#!/usr/bin/env swift
// Seamless table tiles for the board's backdrop: wood, linen and felt.
//
//   swift Scripts/make-table-textures.swift [outdir]
//
// Default outdir is Sources/Resources/Table. Each tile is 512 px and wraps on
// both axes (every noise lattice repeats at the tile size), so the board can
// tile it without seams. Drawn at 2× it covers 256 pt per repeat.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 512
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/Resources/Table",
              isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: - Periodic noise

func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 1_442_695_040_888_963_407))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h & 0xFFFF) / 65_535
}

/// Value noise on a lattice that wraps (`period` cells across, `periodY` down,
/// equal unless given), sampled at u, v in 0..<1.
func noise(_ u: Double, _ v: Double, period: Int, periodY: Int? = nil, seed: Int) -> Double {
    let py = periodY ?? period
    let x = u * Double(period), y = v * Double(py)
    let x0 = Int(floor(x)), y0 = Int(floor(y))
    let fx = x - Double(x0), fy = y - Double(y0)
    let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
    func at(_ i: Int, _ j: Int) -> Double {
        hash(((i % period) + period) % period, ((j % py) + py) % py, seed)
    }
    let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * sx
    let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * sx
    return top + (bottom - top) * sy
}

func fbm(_ u: Double, _ v: Double, period: Int, octaves: Int, seed: Int) -> Double {
    var sum = 0.0, amp = 0.5, total = 0.0, p = period
    for o in 0..<octaves {
        sum += amp * noise(u, v, period: p, seed: seed + o * 31)
        total += amp; amp *= 0.5; p *= 2
    }
    return sum / total
}

typealias RGB = (Double, Double, Double)
func hex(_ s: String) -> RGB {
    let v = Int(s, radix: 16)!
    return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
}
func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t) }
func scale(_ c: RGB, _ k: Double) -> RGB { (c.0 * k, c.1 * k, c.2 * k) }

func write(_ name: String, _ pixel: (Double, Double) -> RGB) throws {
    var bytes = [UInt8](repeating: 255, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let c = pixel(Double(x) / Double(size), Double(y) / Double(size))
            let i = (y * size + x) * 4
            bytes[i] = UInt8(max(0, min(255, c.0 * 255)))
            bytes[i + 1] = UInt8(max(0, min(255, c.1 * 255)))
            bytes[i + 2] = UInt8(max(0, min(255, c.2 * 255)))
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let url = out.appending(path: "\(name).jpg")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
    CGImageDestinationFinalize(dest)
    print(url.lastPathComponent)
}

// MARK: - Wood: four light-oak planks, long grain running across

let oakLight = hex("d8bc93"), oakDark = hex("b08757")
try write("table-wood") { u, v in
    let plank = Int(v * 4)
    let local = v * 4 - Double(plank)
    // Long, nearly straight grain: noise stretched along the plank.
    let drift = noise(u, v, period: 2, periodY: 8, seed: 11 + plank * 7) * 1.2
        + noise(u, v, period: 4, periodY: 32, seed: 12 + plank) * 0.35
    let grain = 0.5 + 0.5 * sin((local * 26 + drift * 4 + Double(plank) * 1.7) * 2 * .pi)
    let streaks = noise(u, v, period: 8, periodY: 256, seed: 13 + plank)
    let fine = noise(u, v, period: 32, periodY: 512, seed: 14 + plank)
    var c = mix(oakLight, oakDark, pow(grain, 3) * 0.32 + streaks * 0.28 + fine * 0.12)
    c = scale(c, 0.95 + 0.09 * hash(plank, 0, 3))             // each plank its own tone
    let edge = min(local, 1 - local) * Double(size) / 4       // px to the seam
    if edge < 1.5 { c = scale(c, 0.74 + 0.12 * edge) }
    return c
}

// MARK: - Linen: a fine plain weave with slubs, in warm oatmeal

let linen = hex("e6d9c2")
try write("table-linen") { u, v in
    let threads = 128.0                                       // per tile, each way
    let tx = u * threads, ty = v * threads
    let warp = 0.5 + 0.5 * cos(2 * .pi * tx)
    let weft = 0.5 + 0.5 * cos(2 * .pi * ty)
    let over = (Int(tx) + Int(ty)) % 2 == 0                   // over-under
    let slubX = fbm(u, v * 0.02, period: 32, octaves: 2, seed: 21)
    let slubY = fbm(u * 0.02, v, period: 32, octaves: 2, seed: 22)
    let thread = over ? warp * (0.8 + 0.4 * slubX) : weft * (0.8 + 0.4 * slubY)
    let blotch = fbm(u, v, period: 4, octaves: 3, seed: 23)
    return scale(linen, 0.86 + 0.12 * thread + 0.06 * (blotch - 0.5))
}

// MARK: - Felt: soft sage, matted fibres and no pattern

let felt = hex("7f8f68")
try write("table-felt") { u, v in
    let fibres = fbm(u, v, period: 128, octaves: 2, seed: 41)
    let tufts = fbm(u, v, period: 16, octaves: 3, seed: 42)
    let shade = fbm(u, v, period: 4, octaves: 2, seed: 43)
    return scale(felt, 0.86 + 0.14 * fibres + 0.1 * (tufts - 0.5) + 0.08 * (shade - 0.5))
}
