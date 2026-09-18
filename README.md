# MirrorBridge

MirrorBridge 是一款面向 Android 的相机连接与照片工作台。它用 Flutter 构建界面，用 Kotlin 处理 Android 媒体库、USB/PTP、实时取景和本地图像处理。

## 能做什么

- 通过 USB OTG/PTP 或相机 Wi-Fi 连接 Nikon 相机。
- 浏览相机存储中的照片和视频，分页查看缩略图。
- 选择媒体批量同步到手机，支持进度、取消、失败重试和记录清理。
- 浏览手机媒体，导入照片、RAW 预览和视频，并支持筛选、分享与删除记录。
- 实时取景、触屏对焦、拍摄，以及快门、光圈、ISO 等参数调整。
- 使用网格、峰值、直方图、波形和监看 LUT 辅助构图。
- 查看照片、缩放旋转、添加边框和 EXIF 文字，导出新的高分辨率副本。
- 使用内置 3D Cube LUT，或导入经过严格校验的 `.cube` 文件。

## 环境

- Flutter 3.44.5 / Dart 3.12
- JDK 21
- Android SDK 36、Build Tools 36.0.0、NDK 28.2.13676358
- Python 3

Windows 构建脚本会优先读取 `FLUTTER_BIN`、`ANDROID_HOME`、`ANDROID_SDK_ROOT` 和 `JAVA_HOME`，也会查找仓库旁的本地工具链。

## 构建与测试

在仓库根目录执行：

```powershell
pwsh -NoProfile -File scripts/build-local.ps1 -Target check
pwsh -NoProfile -File scripts/build-local.ps1 -Target native -JavaHome C:/path/to/jdk-21
pwsh -NoProfile -File scripts/build-local.ps1 -Target arm64 -JavaHome C:/path/to/jdk-21
```

macOS / Linux：

```bash
bash scripts/build-local.sh check
bash scripts/build-local.sh native
bash scripts/build-local.sh arm64
```

构建产物位于 `dist/`。`check` 会执行资源检查、静态分析和 Flutter 测试；`native` 会运行 Kotlin 单元测试。涉及真实相机的集成测试还需要 Android 设备和兼容的 Nikon 相机。

## 目录

```text
lib/                 Flutter 页面、状态、协议和仓库
android/             Android 工程与 Kotlin 平台层
assets/              演示媒体、内置 LUT 和模板资源
test/                Flutter 单元与组件测试
integration_test/    设备与相机集成测试
scripts/             构建、资源生成和检查脚本
```

## LUT 文件

导入入口只接受扩展名为 `.cube` 的 3D LUT。导入时会检查 UTF-8 编码、`LUT_3D_SIZE`、数据行数量、域范围、数值有限性与 RGB 范围；不符合格式的文件不会保存到应用目录。当前支持尺寸 `2` 到 `65`，文件上限为 64 MB，不支持 1D LUT。

## 许可

项目代码和项目资源的许可状态见 [`LICENSE`](LICENSE)。Flutter、Dart、Android 及其他依赖的许可文本见 `THIRD_PARTY_LICENSES.txt` 和 `THIRD_PARTY_NOTICES.md`。Nikon 等商标归各自权利人所有，用户导入的照片和 LUT 由用户自行负责其使用权利。
