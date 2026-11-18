import UIKit
import PhotosUI
import UniformTypeIdentifiers

// PHPicker 选视频。
// preferredAssetRepresentationMode = .current 很关键：
// 让系统直接给原始文件，而不是先转成「兼容格式」，否则画质在选片的瞬间就掉了。
final class VideoPicker: NSObject, PHPickerViewControllerDelegate {

    private let onPick: (URL?) -> Void

    init(onPick: @escaping (URL?) -> Void) {
        self.onPick = onPick
        super.init()
    }

    func makeController() -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .videos
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = self
        return vc
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) {
            guard let provider = results.first?.itemProvider else {
                self.onPick(nil)
                return
            }
            let typeId = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeId) else {
                Diag.log("选中的文件不是影片类型")
                self.onPick(nil)
                return
            }
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, err in
                guard let url = url else {
                    Diag.log("取文件失败：\(err?.localizedDescription ?? "未知")")
                    DispatchQueue.main.async { self.onPick(nil) }
                    return
                }
                // 这个 url 在闭包返回后会被系统删掉，必须立刻复制出来
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("src_\(Int(Date().timeIntervalSince1970)).mov")
                try? FileManager.default.removeItem(at: dst)
                do {
                    try FileManager.default.copyItem(at: url, to: dst)
                    Diag.log("已选入：\(dst.lastPathComponent)")
                    DispatchQueue.main.async { self.onPick(dst) }
                } catch {
                    Diag.log("复制源文件失败：\(error.localizedDescription)")
                    DispatchQueue.main.async { self.onPick(nil) }
                }
            }
        }
    }
}
