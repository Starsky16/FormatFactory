package com.formatfactory.app.unlock

import java.io.File
import java.io.RandomAccessFile

/**
 * 酷狗 .kgm / .kgma / .vpr 脱壳（KGM V2 XOR 方案，纯本地、无需外部密钥文件）。
 *
 * 移植自 kugou-audio-unlock(MIT, 见 android/tools/ref/kgm-py)，算法：
 *   fileKey   = header[0x1c..0x2c] + 0x00       (17 字节)
 *   headerLen = uint32 LE at header[0x10]
 *   音频数据从 headerLen 起
 *   out[i]    = T( maskV2(i) ^ enc[i] ^ fileKey[i % 17] )，T(x)=x^((x&0xF)<<4)
 *   maskV2(i) = tableV2[i%272] ^ maskV1(i>>4)
 *   .vpr 额外：out[i] ^= vprKey[i%17]
 *
 * 说明：.kgg 需要酷狗客户端的 KGMusicV3.db(SQLCipher)，手机端无法离线获取，不支持。
 */
class KgmUnlocker {
    companion object {
        data class Result(val outputPath: String, val ext: String)

        private fun xorLowerHalf(x: Int) = x xor ((x and 0x0F) shl 4)

        private fun maskV1(offsetIn: Int): Int {
            var value = 0
            var offset = offsetIn
            while (offset >= 0x11) {
                value = value xor KgmTables.TABLE1[offset % KgmTables.TABLE_SIZE]
                offset = offset ushr 4
                value = value xor KgmTables.TABLE2[offset % KgmTables.TABLE_SIZE]
                offset = offset ushr 4
            }
            return value
        }

        private fun maskV2(offset: Int): Int =
            KgmTables.TABLEV2[offset % KgmTables.TABLE_SIZE] xor maskV1(offset ushr 4)

        private fun decryptByte(enc: Int, fileKey: ByteArray, offset: Int): Int =
            xorLowerHalf(maskV2(offset) xor (enc and 0xff) xor (fileKey[offset % 17].toInt() and 0xff))

        /**
         * 测试钩子：生成器侧"加密"。Kugou 加密 = T(明文) ^ mask ^ key，
         * 这样 decryptByte 才能还原（T 是自逆线性置换）。
         */
        internal fun encodeForTest(plain: Int, fileKey: ByteArray, offset: Int): Int =
            xorLowerHalf(plain and 0xff) xor
                maskV2(offset) xor
                (fileKey[offset % 17].toInt() and 0xff)

        internal fun uniqueOut(destDir: File, base: String, ext: String): String {
            var name = "$base.$ext"
            var n = 2
            while (File(destDir, name).exists()) {
                name = "${base}_$n.$ext"
                n++
            }
            return name
        }

        /**
         * 解密 .kgm/.kgma（[isVpr]=false）或 .vpr（[isVpr]=true）。
         * 返回真实音频扩展名。
         */
        @Throws(Exception::class)
        fun unlock(src: File, destDir: File, isVpr: Boolean): Result {
            require(src.isFile) { "源文件不存在：${src.path}" }
            if (!destDir.exists()) destDir.mkdirs()

            RandomAccessFile(src, "r").use { raf ->
                val header = ByteArray(0x3c)
                val got = raf.read(header)
                if (got < 0x3c) throw IllegalStateException("文件太小，不是 KGM 容器")
                val fileKey = ByteArray(17)
                for (i in 0 until 16) fileKey[i] = header[0x1c + i]
                fileKey[16] = 0
                val headerLen =
                    (header[0x10].toInt() and 0xff) or
                        ((header[0x11].toInt() and 0xff) shl 8) or
                        ((header[0x12].toInt() and 0xff) shl 16) or
                        ((header[0x13].toInt() and 0xff) shl 24)
                require(headerLen in 0x3c..(1 shl 20)) { "KGM 头长度异常：$headerLen" }
                raf.seek(headerLen.toLong())

                var out: RandomAccessFile? = null
                var outPath: String? = null
                val buf = ByteArray(1 shl 16)
                var offset = 0
                try {
                    while (true) {
                        val n = raf.read(buf)
                        if (n <= 0) break
                        for (i in 0 until n) {
                            val v = decryptByte(buf[i].toInt(), fileKey, offset + i)
                            buf[i] = (if (isVpr) v xor (KgmTables.VPRKEY[(offset + i) % 17].toInt() and 0xff) else v).toByte()
                        }
                        if (out == null) {
                            val head = buf.copyOf(4)
                            val fmt = AudioFormatDetect.detect(head)
                                ?: throw IllegalStateException("无法识别解密后的音频格式")
                            val outFile = File(destDir, uniqueOut(destDir, src.nameWithoutExtension, fmt))
                            out = RandomAccessFile(outFile, "rw")
                            out.setLength(0)
                            outPath = outFile.absolutePath
                        }
                        out.write(buf, 0, n)
                        offset += n
                    }
                } catch (t: Throwable) {
                    // 失败收尾：删掉已创建的半成品（Dart 侧拿不到文件名，删不到）
                    PartialOutputCleanup.remove(out, outPath)
                    throw t
                } finally {
                    out?.close()
                }
                val real = outPath ?: throw IllegalStateException("KGM 解密输出为空")
                val fmt = AudioFormatDetect.detect(File(real).readBytes().copyOf(8))
                    ?: throw IllegalStateException("无法识别解密后的音频格式")
                return Result(real, fmt)
            }
        }
    }
}
