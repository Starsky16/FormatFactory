# 贡献指南

感谢你愿意参与 **格式工厂 · Format Factory (Android)**。

## 分支约定
- `main`：只存放**已验证通过**的代码
- `dev`：所有日常开发都在这里进行
- 合并到 `main` 前必须通过：`flutter analyze`、`flutter test`、`flutter build apk --release --split-per-abi`（涉及原生解密改动另需 `android/gradlew :app:testDebugUnitTest`）

## 开发环境
- Flutter stable（本仓库要求 Dart ≥3.13）
- Android SDK（minSdk 24）
- 常用命令：
  ```bash
  flutter pub get
  flutter analyze
  flutter test
  flutter build apk --release --split-per-abi
  ```

## 项目结构
```
lib/
├── models.dart             领域模型（任务/设置/媒体信息）
├── formats.dart            格式预设结构与参数翻译助手
├── formats_data.dart       汇总入口
├── formats_video_data.dart 视频格式清单（想加视频格式改这里）
├── formats_audio_data.dart 音频格式清单
├── formats_image_data.dart 图片格式清单
├── services/               FFmpeg 引擎、FFprobe、输出目录、解锁通道、B站缓存解析、前台通知
├── state/                  Riverpod：任务队列 / 设置 / 历史
└── ui/                     首页 / 转换 / 音乐脱壳 / B站缓存 / 任务 / 历史 / 设置 / 文件浏览器

android/app/src/main/kotlin/.../unlock/   脱壳算法（Ncm/Qmc/Kgm，纯 Kotlin）
android/app/src/test/.../unlock/          JVM 单元测试（含真实 .ncm 样本与往返样本）
```

## 想加一种格式？
- **转码格式**：改 `lib/formats_*_data.dart`——复制一条 `FormatPreset` 改三处：`name/extension`（显示名与扩展名）、`fields`（设置页参数下拉框）、`buildArgs`（FFmpeg 参数，均有中文注释）
- **脱壳格式**：Android `com.starksky16.formatfactory.unlock.*`，照 Ncm/Qmc/Kgm 的实现 + JVM 单元测试

## 想换主题色？
改 `lib/theme.dart` 里的 `seedColor` 一个值，整套 Material 3 配色自动生成。

## 提交信息风格
建议遵循 `type(scope): 描述`（如 `feat(unlock-QMC): …` / `fix(browser): …`）。

## 发布（维护者）
1. 递增 `pubspec.yaml` 的 `version: X.Y.Z+N`（`+N` 是 versionCode，**每次发版必须递增**）
2. 提交到 `dev` → 合并到 `main`（`main` 只放已验证代码）
3. 打 **annotated** tag 并推送：`git tag -a vX.Y.Z -m "<本次更新说明>" && git push origin vX.Y.Z`——CI 会自动构建 3 个 split APK 并创建 Release，**tag 注释会成为 Release 正文里的「本次更新」**（写多行用 `git tag -a vX.Y.Z -F <说明文件>`；若用 lightweight tag `git tag vX.Y.Z`，正文里就只有安装说明）
4. 正式签名：CI 由仓库 secrets 提供（`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS`）；
   本地构建读取 `android/key.properties`（已 gitignore，不进版本库），文件不存在时自动退回 debug 签名

## 说明
本项目绝大多数代码由 AI 生成，作者负责保证其行为与功能测试正常；请同样以"可验证、可测试"为标准提交改动。
