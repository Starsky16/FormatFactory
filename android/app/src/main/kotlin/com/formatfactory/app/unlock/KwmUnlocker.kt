package com.formatfactory.app.unlock

import java.io.File
import java.io.RandomAccessFile

/**
 * 酷我 .kwm 脱壳（纯离线）。
 *
 * 算法移植自 unlock-music `um/cli` 的 algo/kwm/kwm.go（MIT，Copyright 2020-2021 Unlock Music）。
 * 上游仓库已被 DMCA 下架（GitHub unlock-music/cli，2022-11），本文档仅保留算法规格，
 * 来源与旁证镜像核对记录见 android/tools/ref/README.md。
 *
 * 支持范围（用户知情拍板，见 workflow-sync plans/2026-10-04-format-factory-t12-kwm.md）：
 * - KWM v1：固定 0x400 头 + 32 字节循环 XOR，纯离线可解 → 支持
 * - KWM v2：加密谱系为 QMCv2/RC4+ekey（DMCA 点名算法），离线无密钥、需 root → **不做**，检测到即报错
 */
class KwmUnlocker {

    data class Result(val outputPath: String, val ext: String)

    companion object {
        private const val HEADER_SIZE = 0x400
        private const val MASK_SIZE = 0x20

        /** magic："yeelion-kuwo-tme" */
        private val MAGIC = byteArrayOf(
            0x79, 0x65, 0x65, 0x6C, 0x69, 0x6F, 0x6E, 0x2D,
            0x6B, 0x75, 0x77, 0x6F, 0x2D, 0x74, 0x6D, 0x65,
        )

        /** 金标准常量（kwm.go keyPreDefined） */
        private const val KEY_PRE_DEFINED = "MoOtOiTvINGwd2E6n0E1i7L5t2IoOoNk"

        @Throws(Exception::class)
        fun unlock(src: File, destDir: File): Result {
            require(src.isFile) { "源文件不存在：${src.path}" }
            if (!destDir.exists()) destDir.mkdirs()

            val raf = RandomAccessFile(src, "r")
            if (raf.length() < HEADER_SIZE) {
                raf.close()
                throw IllegalStateException("文件太小，不是 KWM 容器")
            }

            val header = ByteArray(HEADER_SIZE)
            raf.readFully(header)
            if (!MAGIC.contentEquals(header.copyOfRange(0, 16))) {
                raf.close()
                throw IllegalStateException("KWM 魔数不匹配，不是酷我加密文件")
            }
            // v1/v2 由头 0x10 处版本字节区分；v2 属 DMCA 点名谱系，明确拒绝
            if (header[0x10].toInt() == 2) {
                raf.close()
                throw IllegalStateException("KWM v2 暂不支持（需 root 提取设备密钥，本应用只做 v1 离线解密）")
            }

            // 掩码：头 0x18..0x20 的 u64（LE）→ 十进制字符串 → 循环填充/截断到 32 字节 ⊕ 常量
            val mask = generateMask(header.copyOfRange(0x18, 0x20))
            // 头 0x30..0x38 的"码率+格式"字段，作为格式探测的兜底
            val headerExt = parseHeaderExt(header)

            var out: RandomAccessFile? = null
            var outPath: String? = null
            val buf = ByteArray(1 shl 16)
            try {
                var maskPos = 0
                while (true) {
                    val n = raf.read(buf)
                    if (n <= 0) break
                    for (i in 0 until n) {
                        buf[i] = (buf[i].toInt() xor mask[maskPos and 0x1F].toInt()).toByte()
                        maskPos++
                    }
                    if (out == null) {
                        val fmt = AudioFormatDetect.detect(buf.copyOf(minOf(8, n)))
                            ?: headerExt
                            ?: throw IllegalStateException("无法识别解密后的音频格式")
                        val outFile =
                            File(destDir, NcmUnlocker.uniqueName(destDir, src.nameWithoutExtension, fmt)) // 复用同一套重名序号策略
                        out = RandomAccessFile(outFile, "rw")
                        out.setLength(0)
                        outPath = outFile.absolutePath
                    }
                    out.write(buf, 0, n)
                }
            } catch (t: Throwable) {
                // 失败收尾：删掉已创建的半成品（Dart 侧拿不到文件名，删不到）
                PartialOutputCleanup.remove(out, outPath)
                throw t
            } finally {
                out?.close()
            }

            outPath ?: throw IllegalStateException("KWM 解密输出为空")
            return Result(outPath, File(outPath).extension)
        }

        /** 生成 32 字节循环掩码（kwm.go generateMask）。 */
        internal fun generateMask(key: ByteArray): ByteArray {
            require(key.size == 8) { "KWM 密钥字段应为 8 字节" }
            // u64 小端 → 十进制字符串（Go: binary.LittleEndian.Uint64 + FormatUint）
            var v = 0UL
            for (i in 0 until 8) {
                v = v or ((key[i].toULong() and 0xFFUL) shl (8 * i))
            }
            val raw = v.toString()
            // 循环填充/截断到 32 字节（kwm.go padOrTruncate）
            val padded = CharArray(MASK_SIZE) { raw[it % raw.length] }
            return ByteArray(MASK_SIZE) {
                (KEY_PRE_DEFINED[it].code xor padded[it].code).toByte()
            }
        }

        /** 头 0x30..0x38："码率+格式"字段（如 "320mp3"），取格式部分；无则 null。 */
        private fun parseHeaderExt(header: ByteArray): String? {
            val field = header.copyOfRange(0x30, 0x38)
                .toString(Charsets.ISO_8859_1)
                .trimEnd('\u0000')
            val digitsEnd = field.indexOfFirst { !it.isDigit() }
            val ext = if (digitsEnd < 0) "" else field.substring(digitsEnd).lowercase()
            return ext.ifEmpty { null }
        }
    }
}
