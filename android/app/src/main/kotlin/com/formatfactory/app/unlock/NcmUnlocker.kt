package com.formatfactory.app.unlock

import java.io.File
import java.io.RandomAccessFile
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/**
 * 网易云 .ncm 脱壳（解密为原始 flac/mp3）。
 *
 * 算法移植自开源项目 taurusxin/ncmdump(MIT)，
 * 流程：
 *  1. 校验魔数 "CTENFDAM"
 *  2. 读取密钥段(与 0x64 异或) → AES-128-ECB(CoreKey) 解密 → 取 17 字节后作为子密钥
 *  3. 跳过 meta / 封面段
 *  4. RC4 式 KSA 构建 keyBox，逐字节异或输出音频流
 *  5. 按头字节识别输出 mp3(ID3) 或 flac(fLaC)
 *
 * 说明：本类不依赖 Android API，可在 JVM 单元测试里直接验证。
 */
class NcmUnlocker {
    companion object {
        // CoreKey（16 字节，用于 AES 解密 ncm 内嵌密钥）
        private val CORE_KEY: ByteArray =
            "hzHRAmso5kInbaxW".toByteArray(Charsets.US_ASCII)

        /** 解密后明文前 17 字节是固定前缀("neteasecloudmusic")，其后才是子密钥 */
        private const val PREFIX_LEN = 17
        private const val BUF_SIZE = 0x8000

        data class Result(val outputPath: String, val ext: String)

        @Throws(Exception::class)
        fun unlock(src: File, destDir: File): Result {
            require(src.isFile) { "源文件不存在：${src.path}" }
            if (!destDir.exists()) destDir.mkdirs()

            RandomAccessFile(src, "r").use { srcRaf ->
                // 1) 魔数
                val magic = ByteArray(8)
                srcRaf.readFully(magic)
                val expected = "CTENFDAM".toByteArray(Charsets.US_ASCII)
                if (!magic.contentEquals(expected)) {
                    throw IllegalStateException("不是有效的 NCM 文件（魔数不符）")
                }
                srcRaf.skipBytes(2)

                // 2) 密钥段
                val keyLen = readIntLE(srcRaf)
                require(keyLen in 1..1_048_576) { "NCM 密钥长度异常：$keyLen" }
                val keyData = ByteArray(keyLen)
                srcRaf.readFully(keyData)
                for (i in keyData.indices) {
                    keyData[i] = (keyData[i].toInt() xor 0x64).toByte()
                }
                val core = SecretKeySpec(CORE_KEY, "AES")
                val cipher = Cipher.getInstance("AES/ECB/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, core)
                val plainKey = cipher.doFinal(keyData)
                // C++ 参考实现：末块按 out[15] 的 pad 值剥掉 PKCS#7 填充
                val pad = plainKey[plainKey.size - 1].toInt() and 0xff
                val trimLen = if (pad in 1..16) plainKey.size - pad else plainKey.size
                require(trimLen > PREFIX_LEN) { "NCM 密钥解密结果过短" }
                val subKey = plainKey.copyOfRange(PREFIX_LEN, trimLen)

                // 3) 跳过 meta（含 22 字节前缀等，脱壳不需要写标签）
                val metaLen = readIntLE(srcRaf)
                if (metaLen > 0) srcRaf.skipBytes(metaLen)

                // 跳过 crc32 + 图片版本(5) + 封面长度与图片数据
                srcRaf.skipBytes(5)
                val coverFrameLen = readIntLE(srcRaf)
                val imgLen = readIntLE(srcRaf)
                if (imgLen > 0) srcRaf.skipBytes(imgLen)
                val rest = coverFrameLen - imgLen
                if (rest > 0) srcRaf.skipBytes(rest)

                // 4) keyBox（RC4 式 KSA）
                val box = IntArray(256)
                for (i in 0 until 256) box[i] = i
                var lastByte = 0
                var keyOffset = 0
                for (i in 0 until 256) {
                    val swap = box[i]
                    val c = (lastByte + (subKey[keyOffset].toInt() and 0xff) + swap) and 0xff
                    keyOffset++
                    if (keyOffset >= subKey.size) keyOffset = 0
                    box[i] = box[c]
                    box[c] = swap
                    lastByte = c
                }

                // 5) 解密音频流并写出
                var output: RandomAccessFile? = null
                var outputPath: String? = null
                var ext = ""
                val buf = ByteArray(BUF_SIZE)
                try {
                    while (true) {
                        val n = srcRaf.read(buf, 0, BUF_SIZE)
                        if (n <= 0) break
                        for (i in 0 until n) {
                            val j = (i + 1) and 0xff
                            val b = buf[i].toInt() and 0xff
                            buf[i] =
                                (b xor box[(box[j] + box[(box[j] + j) and 0xff]) and 0xff])
                                    .toByte()
                        }
                        if (output == null) {
                            // 按头字节识别真实格式
                            ext = when {
                                isMp3(buf) -> "mp3"
                                isFlac(buf) -> "flac"
                                else -> throw IllegalStateException("无法识别解密后的音频格式")
                            }
                            val outFile = File(destDir, uniqueName(destDir, src.nameWithoutExtension, ext))
                            output = RandomAccessFile(outFile, "rw")
                            output?.setLength(0)
                            outputPath = outFile.absolutePath
                        }
                        output?.write(buf, 0, n)
                    }
                } catch (t: Throwable) {
                    // 失败收尾：删掉已创建的半成品（Dart 侧拿不到文件名，删不到）
                    PartialOutputCleanup.remove(output, outputPath)
                    throw t
                } finally {
                    output?.close()
                }
                return Result(outputPath!!, ext)
            }
        }

        private fun isMp3(buf: ByteArray): Boolean =
            (buf[0].toInt() and 0xff) == 0x49 &&
                (buf[1].toInt() and 0xff) == 0x44 &&
                (buf[2].toInt() and 0xff) == 0x33

        private fun isFlac(buf: ByteArray): Boolean =
            buf[0] == 'f'.code.toByte() &&
                buf[1] == 'L'.code.toByte() &&
                buf[2] == 'a'.code.toByte() &&
                buf[3] == 'C'.code.toByte()

        internal fun uniqueName(destDir: File, base: String, ext: String): String {
            var name = "$base.$ext"
            var n = 2
            while (File(destDir, name).exists()) {
                name = "${base}_$n.$ext"
                n++
            }
            return name
        }

        private fun readIntLE(raf: RandomAccessFile): Int {
            val b = ByteArray(4)
            raf.readFully(b)
            return (b[0].toInt() and 0xff) or
                ((b[1].toInt() and 0xff) shl 8) or
                ((b[2].toInt() and 0xff) shl 16) or
                ((b[3].toInt() and 0xff) shl 24)
        }
    }
}
