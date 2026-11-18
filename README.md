# lpw-build

纯构建仓库：在 GitHub 的 macOS runner 上用真 Xcode toolchain 编译
「无损实况」（视频 → iOS 锁屏实况壁纸）的 IPA。

- 源码在 `Sources/`（Swift + UIKit + AVFoundation）
- 构建定义在 `.github/workflows/build.yml`
- 产物通过 Actions artifact 与 Release 双通道发布

核心：视频轨与音频轨走 `AVAssetReader/Writer outputSettings: nil` 全直通，
不重编码，分辨率与码率与源文件完全一致。
