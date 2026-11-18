import UIKit

/// iOS 原生（Settings / inset-grouped）配色。
/// 全部使用系统语义色：浅色 / 深色 / 提高对比度模式都自动正确。
enum Theme {
    static let bg         = UIColor.systemGroupedBackground
    static let card       = UIColor.secondarySystemGroupedBackground
    static let cardInner  = UIColor.tertiarySystemGroupedBackground
    static let accent     = UIColor.systemBlue
    static let onAccent   = UIColor.white
    static let text       = UIColor.label
    static let sub        = UIColor.secondaryLabel
    static let faint      = UIColor.tertiaryLabel
    static let separator  = UIColor.separator
    static let warn       = UIColor.systemOrange
    static let danger     = UIColor.systemRed
    static let ok         = UIColor.systemGreen

    /// 固定字号，绝不跟随「动态字体」。
    /// systemFont(ofSize:) 在系统开大字模式时仍会被放大，配合固定高度卡片会让整页错乱
    /// —— 老板反馈过两次「生成后整个画面变得非常大」，这里用 descriptor 锁死。
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let d = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        return UIFont(descriptor: d, size: size)
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        let d = UIFont.monospacedSystemFont(ofSize: size, weight: weight).fontDescriptor
        return UIFont(descriptor: d, size: size)
    }
}

/// 原生风格控件工厂
enum Ctl {

    static func label(_ text: String,
                      size: CGFloat,
                      weight: UIFont.Weight = .regular,
                      color: UIColor = Theme.text,
                      lines: Int = 0) -> UILabel {
        let l = UILabel()
        l.text = text
        l.numberOfLines = lines
        l.textColor = color
        l.font = Theme.font(size, weight)
        l.adjustsFontForContentSizeCategory = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// 系统 Settings 里的分组卡片：圆角 10、纯色底
    static func card(corner: CGFloat = 10) -> UIView {
        let v = UIView()
        v.backgroundColor = Theme.card
        v.layer.cornerRadius = corner
        v.layer.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    /// 分组标题：系统样式是 13pt 常规、次要色、左侧留白
    static func sectionHeader(_ text: String) -> UILabel {
        label(text, size: 13, weight: .regular, color: Theme.sub)
    }

    static func separator(_ inset: CGFloat = 16) -> UIView {
        let v = UIView()
        v.backgroundColor = Theme.separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    /// SF Symbol 图标
    static func icon(_ name: String, color: UIColor = Theme.accent, size: CGFloat = 18, weight: UIFont.Weight = .semibold) -> UIImageView {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: symbolWeight(weight))
        let iv = UIImageView(image: UIImage(systemName: name, withConfiguration: cfg))
        iv.tintColor = color
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.setContentCompressionResistancePriority(.required, for: .horizontal)
        return iv
    }

    private static func symbolWeight(_ w: UIFont.Weight) -> UIImage.SymbolWeight {
        switch w {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        case .light: return .light
        default: return .regular
        }
    }

    /// 主按钮：系统填充样式（圆角 12 / 高 50 / 半粗 17pt）
    static func filledButton(_ title: String, height: CGFloat = 50) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(Theme.onAccent, for: .normal)
        b.titleLabel?.font = Theme.font(17, .semibold)
        b.titleLabel?.adjustsFontForContentSizeCategory = false
        b.backgroundColor = Theme.accent
        b.layer.cornerRadius = 12
        b.layer.cornerCurve = .continuous
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }

    /// 次按钮：系统浅填充
    static func tintedButton(_ title: String, height: CGFloat = 46) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(Theme.accent, for: .normal)
        b.titleLabel?.font = Theme.font(16, .semibold)
        b.titleLabel?.adjustsFontForContentSizeCategory = false
        b.backgroundColor = Theme.cardInner
        b.layer.cornerRadius = 12
        b.layer.cornerCurve = .continuous
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }

    /// 一行：左图标 + 标题 + 右侧值
    static func row(icon iconName: String?, title: String, valueView: UIView? = nil,
                    titleSize: CGFloat = 15, muted: Bool = false) -> UIView {
        let h = UIStackView()
        h.axis = .horizontal
        h.alignment = .center
        h.spacing = 12
        h.translatesAutoresizingMaskIntoConstraints = false
        if let n = iconName {
            // 必须限定 Ctl.，否则会被同名参数 iconName/icon 遮蔽
            h.addArrangedSubview(Ctl.icon(n, size: 17))
        }
        let t = label(title, size: titleSize, weight: muted ? .regular : .regular,
                      color: Theme.text)
        t.setContentHuggingPriority(.defaultLow, for: .horizontal)
        h.addArrangedSubview(t)
        if let v = valueView {
            h.addArrangedSubview(v)
        }
        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            h.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            h.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            h.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11)
        ])
        return box
    }
}
