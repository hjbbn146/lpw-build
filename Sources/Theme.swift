import UIKit

enum Theme {
    static let background = UIColor(red: 0.043, green: 0.051, blue: 0.075, alpha: 1)
    static let backgroundTop = UIColor(red: 0.075, green: 0.086, blue: 0.125, alpha: 1)
    static let card = UIColor(red: 0.098, green: 0.110, blue: 0.145, alpha: 1)
    static let cardInner = UIColor(red: 0.137, green: 0.153, blue: 0.196, alpha: 1)
    static let accent = UIColor(red: 0.29, green: 0.87, blue: 0.72, alpha: 1)
    static let accentDim = UIColor(red: 0.29, green: 0.87, blue: 0.72, alpha: 0.16)
    static let text = UIColor.white
    static let sub = UIColor(red: 0.60, green: 0.64, blue: 0.71, alpha: 1)
    static let faint = UIColor(red: 0.42, green: 0.46, blue: 0.53, alpha: 1)
    static let warn = UIColor(red: 1.0, green: 0.63, blue: 0.31, alpha: 1)
    static let danger = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)

    static func titleFont(_ size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .bold)
    }
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

enum Ctl {

    static func label(_ text: String,
                      size: CGFloat,
                      weight: UIFont.Weight = .regular,
                      color: UIColor = Theme.text,
                      lines: Int = 1,
                      mono: Bool = false) -> UILabel {
        let l = UILabel()
        l.text = text
        l.numberOfLines = lines
        l.textColor = color
        l.font = mono ? Theme.mono(size) : Theme.font(size, weight)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func card() -> UIView {
        let v = UIView()
        v.backgroundColor = Theme.card
        v.layer.cornerRadius = 18
        v.layer.cornerCurve = .continuous
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 1, alpha: 0.06).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    static func sectionTag(_ text: String) -> UILabel {
        let l = label(text, size: 11.5, weight: .semibold, color: Theme.accent)
        l.font = UIFont.systemFont(ofSize: 11.5, weight: .bold)
        return l
    }

    static func button(_ title: String,
                       bg: UIColor,
                       fg: UIColor,
                       height: CGFloat = 50,
                       size: CGFloat = 16) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(fg, for: .normal)
        b.titleLabel?.font = Theme.font(size, .semibold)
        b.backgroundColor = bg
        b.layer.cornerRadius = 13
        b.layer.cornerCurve = .continuous
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }

    // 生成一张渐变图给背景用（避免额外资源文件）
    static func gradientImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors = [Theme.backgroundTop.cgColor, Theme.background.cgColor] as CFArray
            guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors,
                                     locations: [0, 0.55]) else { return }
            ctx.cgContext.drawLinearGradient(g,
                                             start: .zero,
                                             end: CGPoint(x: 0, y: size.height),
                                             options: [])
        }
    }
}
