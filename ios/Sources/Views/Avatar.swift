import CryptoKit
import SwiftUI

struct Avatar: View {
    let key: String
    var chat: String?
    var topic = false
    var size: CGFloat = 40

    var body: some View {
        let cells = glyph(Data(SHA256.hash(data: Data(key.utf8))))
        let ink = tone(hue(key), light: (0.6, 0.5), dark: (0.35, 0.95))
        let paper = tone(hue(chat ?? key), light: (0.25, 0.97), dark: (0.5, 0.32))
        let shape = topic ? AnyShape(RoundedRectangle(cornerRadius: size / 4)) : AnyShape(Circle())
        return Canvas { context, canvas in
            let unit: Double = canvas.width / 8
            for row in 0..<5 {
                for column in 0..<5 {
                    let source: Int = row * 3 + (column < 3 ? column : 4 - column)
                    if cells[source] {
                        let x: Double = (1.5 + Double(column)) * unit
                        let y: Double = (1.5 + Double(row)) * unit
                        let cell = CGRect(x: x, y: y, width: unit, height: unit)
                        context.fill(Path(cell), with: .color(ink))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .background(paper, in: shape)
    }

    private func glyph(_ digest: Data) -> [Bool] {
        var cells: [Bool] = (0..<15).map { index in
            let byte: UInt8 = digest[1 + index / 8]
            let bit: UInt8 = (byte >> UInt8(index % 8)) & 1
            return bit == 1
        }
        var next = 3
        while cells.filter({ $0 }).count < 6 {
            cells[Int(digest[next]) % 15] = true
            next += 1
        }
        while cells.filter({ $0 }).count > 11 {
            cells[Int(digest[next]) % 15] = false
            next += 1
        }
        return cells
    }
}

func color(of key: String) -> Color {
    tone(hue(key), light: (0.6, 0.55), dark: (0.5, 0.85))
}

private func hue(_ key: String) -> Double {
    Double(Data(SHA256.hash(data: Data(key.utf8)))[0] % 12) / 12
}

private func tone(_ hue: Double, light: (saturation: Double, brightness: Double), dark: (saturation: Double, brightness: Double)) -> Color {
    Color(UIColor { traits in
        let tone = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(hue: hue, saturation: tone.saturation, brightness: tone.brightness, alpha: 1)
    })
}
