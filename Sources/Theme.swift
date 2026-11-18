import UIKit

// 跟随系统浅色 / 深色模式。
// 浅色模式：纯白背景 + 浅灰卡片 + 深色文字（强调色压深，保证白底上的对比度）
// 深色模式：深空背景 + 深灰卡片 + 白字
private func dyn(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { trait in
        trait.userInterfaceStyle == .dark ? dark : light
    }
}

func hexColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
    UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

enum Theme {
    static let background = dyn(light: .white, dark: hexColor(0x0B0D13))
    static let card       = dyn(light: hexColor(0xF2F4F7), dark: hexColor(0x191C25))
    static let cardInner  = dyn(light: hexColor(0xE8EBF0), dark: hexColor(0x232733))
    static let accent     = dyn(light: hexColor(0x0E9F7E), dark: hexColor(0x4ADEBB))
    static let onAccent   = dyn(light: .white, dark: hexColor(0x04160F))
    static let text       = dyn(light: hexColor(0x111318), dark: .white)
    static let sub        = dyn(light: hexColor(0x5B6472), dark: hexColor(0x99A1AF))
    static let faint      = dyn(light: hexColor(0x8A93A3), dark: hexColor(0x6B7482))
    static let warn       = dyn(light: hexColor(0xB45309), dark: hexColor(0xFFA05C))
    static let danger     = dyn(light: hexColor(0xD92D20), dark: hexColor(0xFF6B6B))

    static func titleFont(_ size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .bold)
    }
    // 固定字号，不跟随系统「动态字体」。
    // systemFont(ofSize:) 在系统开启大字模式时仍会被放大，配合固定高度的卡片
    // 会导致文字溢出、界面错乱（用户反馈"生成后整个画面变得非常大"）。
    // 用 fontDescriptor + 指定 size 的方式创建，系统不再自动缩放。
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let d = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        return UIFont(descriptor: d, size: size)
    }
    static func mono(_ size: CGFloat) -> UIFont {
        let d = UIFont.monospacedSystemFont(ofSize: size, weight: .regular).fontDescriptor
        return UIFont(descriptor: d, size: size)
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
        l.adjustsFontForContentSizeCategory = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    static func card() -> UIView {
        let v = UIView()
        v.backgroundColor = Theme.card
        v.layer.cornerRadius = 18
        v.layer.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    static func sectionTag(_ text: String) -> UILabel {
        label(text, size: 11.5, weight: .bold, color: Theme.accent)
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
        b.titleLabel?.adjustsFontForContentSizeCategory = false
        b.backgroundColor = bg
        b.layer.cornerRadius = 13
        b.layer.cornerCurve = .continuous
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }
}
