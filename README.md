# 格式工厂 · Format Factory（Android）

[![CI](https://github.com/Starsky16/FormatFactory/actions/workflows/ci.yml/badge.svg)](https://github.com/Starsky16/FormatFactory/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/Starsky16/FormatFactory?label=Download)](https://github.com/Starsky16/FormatFactory/releases/latest)
[![License](https://img.shields.io/github/license/Starsky16/FormatFactory)](LICENSE)

一款 Android 上的"格式工厂"：把视频、音频、图片转换成你想要的格式；还能把网易云/QQ音乐/酷狗下载的**加密音乐还原成普通格式**、把 B 站客户端缓存的视频**无损合并成普通 MP4**。全部处理都在手机本地完成、**不联网也不上传**——**发布版**未申请 `INTERNET` 权限（`android/app/src/main/AndroidManifest.xml` 与本项目全部依赖的清单里均无该声明，可自行核查；`debug`/`profile` 开发构建按 Flutter 模板默认带此权限，与发布版无关）。

## 🤖 AI 辅助声明

本项目全数由 AI 生成，作者的唯一任务是保证其行为及功能测试正常；本 README 仅有本句为人类所写。

## 📲 下载与安装

安装包发布在 **GitHub Releases**：
👉 https://github.com/Starsky16/FormatFactory/releases/latest

| 安装包 | 适用设备 |
|---|---|
| `app-arm64-v8a-release.apk` | 2017 年后的主流手机（**推荐**） |
| `app-armeabi-v7a-release.apk` | 老款 32 位手机 |
| `app-x86_64-release.apk` | Android 模拟器 / x86 平板 |

- 系统要求：**Android 7.0（API 24）及以上**（FFmpeg 底层库要求，无法更低）
- 下载后直接点开 APK 安装；若提示"未知来源"，请在系统弹窗中允许本次安装

## ✨ 它能做什么

### 媒体格式转换
| 类别 | 输出格式 | 可调参数 |
|---|---|---|
| 视频 | MP4(H.264/H.265)、MKV、AVI、MOV、WebM、FLV、3GP、GIF、**仅换容器** | 分辨率、CRF 质量、视频/音频码率、帧率 |
| 音频 | MP3、AAC(M4A)、FLAC、WAV、OGG、Opus | 码率、采样率、声道 |
| 图片 | JPG、PNG、WebP、BMP、TIFF、GIF | 尺寸、质量 |

每类还有"**自定义**"选项，编码器/封装/码率等全部参数自由组合，每个参数下都有一行中文说明。

- **音频转换也收视频**：把视频放进"音频转换"就是**提取音轨**（如 MP4 → MP3），不用另找工具。
- **"仅换容器"（remux）**：不重新编码，只把原有音视频流原样装进新容器（如 MKV → MP4），
  40 分钟的视频几秒完成、画质音质零损失；要求源编码与目标容器兼容，且不保留字幕/封面。

### 音乐脱壳（加密音乐还原）
| 来源 | 扩展名 | 还原为 |
|---|---|---|
| 网易云 | `.ncm` | 原始 flac / mp3 |
| QQ 音乐 | `.qmc0/.qmc2/.qmc3/.qmcflac/.qmcogg`、`.mflac/.mflac0/.mflach/.mgg/.mgg0/.mgg1/.mggl` | 原始 flac / ogg / mp3 |
| 酷狗 | `.kgm/.kgma/.vpr` | 原始 flac / mp3 / wav / ogg |
| 酷我 | `.kwm`（仅 v1） | 原始 mp3 / flac 等 |

> 说明：QQ 音乐的 `.mflac/.mgg` 等需要文件**内嵌密钥**（新下载的多数带有 QTag/V1 尾部）才能离线解密；个别文件未带密钥会明确提示，无法离线处理。
> 酷我 `.kwm` 仅支持 v1（纯离线解密）；v2 需要设备密钥（root），本应用不支持，检测到会明确报错。

### B站缓存转视频（无损合并）
手机 B 站客户端缓存下来的视频是 DASH 分片（`video.m4s` + `audio.m4s`），单独拿出来既不能播放也不好分享。
首页"**B站缓存转视频**"→ 选到缓存目录 → 自动列出缓存里的视频（标题、时长、清晰度、是否下载完）→ 勾选要导出的 → 一键合并为普通 MP4。

| 特性 | 说明 |
|---|---|
| 不转码 | 只做封装合并（`-c copy`），画质音质零损失，40 分钟视频几秒完成 |
| 编码兼容 | H.264 / HEVC 视频 + AAC 音频均可；只有音频的缓存也能单独导出 |
| 结构兼容 | 新版 `c_<cid>/<清晰度>/video.m4s` 与老版 `0.blv/1.blv` 都识别 |
| 去重 | 同一视频缓存了多个清晰度时，只保留清晰度最高的那份 |

> 缓存目录通常在 `Android/data/tv.danmaku.bili/download`（部分版本在 `Android/data/com.bilibili.app.in/download`），系统文件选择器看不到它 → 先用"文件管理权限"方式进入（见下方常见问题）。
>
> 注：普通视频缓存已按真实样本逐项核对；**番剧缓存**（`ep` 目录形态）暂无样本验证，仅实现了深度回退兼容（dev `e19a6fe`），如遇识别异常欢迎提 issue 附目录树。

### 其它贴心设计
- **批量**：一次选多个文件，队列逐个处理，实时进度、可取消/重试/查看原因
- **后台不中断**：切后台、锁屏也继续转，通知栏显示"转换中 45%（1/3）"，可一键关闭通知
- **转码历史**：本地保存每次任务，可再次转换、分享、删除
- **输出默认看得见**：默认存到手机"下载"目录的 `Download/FormatExport/`（系统文件管理器里直接能看到，卸载应用也不会丢）；
  也可以分别改成"应用专属目录"或你自选的目录，没有存储权限时自动经系统"下载"（MediaStore）落盘
- **读取文件方式可选**：系统文件选择器（免权限）或"文件管理权限" + 内置文件浏览器（支持搜索、书签、直达主存储、全选）
- **选目录方式可选**：自定义输出目录既可用系统目录选择器（免权限），也可用内置文件浏览器（能进系统选择器打不开的 `Android/data`）

## 🚀 快速上手

1. 打开首页点"**视频/音频/图片转换**"→ 选文件（可多选）→ 选目标格式和参数 → 开始转换；进度在底部"任务"页实时显示。
2. 首页"**音乐脱壳**"→ 选加密音乐 → 加入任务队列，解出的原始音频自动保存。
3. 首页"**B站缓存转视频**"→ 选到 B 站客户端的缓存目录 → 勾选要导出的视频 → 开始合并，几秒后得到可任意播放/分享的 MP4。
4. "**设置**"页可调整输出位置（默认目录 / 应用专属目录 / 自选目录）、自定义目录的选择方式、读取文件方式、转码通知开关、并行任务数（1~4，1 为串行；视频软编建议 1~2）。

## ❓ 常见问题

**Q：转换/脱壳后的文件在哪里？**
默认在手机"下载"目录的 `Download/FormatExport/` 下，按 `video` / `audio` / `image` 分子目录，
用系统文件管理器进"下载"就能看到，卸载应用也不会被删。若没给应用"所有文件访问"权限，
应用会自动改走系统"下载"（MediaStore）落盘，位置完全一样。
也可以在"**设置 → 输出位置**"改成"应用专属目录"
（`Android/data/com.starksky16.formatfactory/files/FormatFactory/`，无需权限但卸载即删）或你自选的目录；
任务完成后点"分享"还能另存到相册 / 发给其它应用。

**Q：为什么从 Android 7.0 才开始支持？**
FFmpeg 转码库要求 API ≥ 24，且 5.0/6.0 设备占比不足 1%，跑视频转码体验也很差。

**Q：为什么有些加密音乐提示解不了？**
`.ncm`/`.kgm/.kgma/.vpr` 均可离线解；QQ 音乐 `.mflac/.mgg` 需要文件自带密钥（多数新版带 QTag/V1）。没有密钥的文件只能交给对应客户端处理，App 无法凭空解密。

**Q：B 站缓存目录选不到 / 列表是空的？**
B 站缓存放在 `Android/data/tv.danmaku.bili/download`（部分版本为 `Android/data/com.bilibili.app.in/download`），Android 11+ 的系统文件选择器看不到 `Android/data`。
请到"**设置 → 读取文件方式**"改成"**文件管理权限**"，按提示开启"所有文件访问权限"，再回首页进"B站缓存转视频"，用内置文件浏览器进到该 `download` 目录（根目录有"主存储"快捷入口）。列表为空一般就是选到了空的上级目录。

**Q：后台转码会一直常驻吗？**
只在有任务时启动前台服务，队列完成后自动结束；可在设置里关闭"转码通知"。

## ⚖️ 合规与许可证

- 本应用内置 FFmpeg **full-gpl**（含 x264/x265），故本项目以 **GPL-3.0** 开源，代码见本仓库。
- 音乐脱壳仅建议用于**你本人拥有合法使用权的本地缓存文件**，请遵守平台服务条款与你所在地区的法律；本项目不提供任何绕过付费/版权保护的逻辑。
- B站缓存转视频同样只做**本地封装合并**：不联网、不下载视频、不破解任何会员/加密内容，请仅用于导出你本人缓存下来、有权使用的视频。

---
## 🛠 开发者 / 贡献者

想参与开发、自己构建或了解内部结构，请看 **[CONTRIBUTING.md](CONTRIBUTING.md)**（分支约定、开发环境与验证命令、项目结构、怎么加一种转码格式、提交信息风格）；安全问题请按 [SECURITY.md](SECURITY.md) 处理。

**技术栈**：Flutter 3.x · Material 3 · Riverpod · FFmpeg（`ffmpeg_kit_flutter_new`）· SQLite ｜ minSdk 24 / targetSdk 36

**致谢**
[FFmpeg](https://ffmpeg.org/) · [ffmpeg_kit_flutter_new](https://pub.dev/packages/ffmpeg_kit_flutter_new) · [Flutter](https://flutter.dev/) · 脱壳算法参考 [ncmdump](https://github.com/taurusxin/ncmdump) / [ncm2mp3-js](https://github.com/LingBrian/ncm2mp3-js) / [kugou-audio-unlock](https://github.com/onavcn/kugou-audio-unlock)（MIT）

