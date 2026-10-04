package com.formatfactory.app.unlock

import java.io.File

/**
 * QQ音乐 .qmc 系列脱壳（qmc0/qmc2/qmc3/qmcflac/qmcogg/mgg/mflac…）。
 *
 * 移植自开源项目 ncm2mp3-js（LingBrian，MIT，见 android/tools/ref/qmc-js），
 * 算法要点：
 *  - qmc1：固定 64 字节 KEY_TABLE 的 XOR
 *  - qmc2：需要 ekey —— 从文件尾 QTag(内嵌) 或 V1(尾部放 key) 自动取得；
 *    经 EncV2 双层 TEA / 或 TEA(body) 派生真实密钥后，
 *    密钥 ≤300 字节走 Map 密文、>300 走 RC4 密文。
 *  - musicex / 无内嵌密钥的文件无法离线解密，会给出明确错误。
 *
 * 输出扩展名按解密后文件头自动识别（flac/mp3/wav/ogg/m4a）。
 */
class QmcUnlocker {
    companion object {
        // ---- QMC1 固定掩码表 ----
        private val KEY_TABLE = intArrayOf(
            0xc3, 0x4a, 0xd6, 0xca, 0x90, 0x67, 0xf7, 0x52, 0xd8, 0xa1, 0x66, 0x62, 0x9f, 0x5b, 0x09, 0x00,
            0xc3, 0x5e, 0x95, 0x23, 0x9f, 0x13, 0x11, 0x7e, 0xd8, 0x92, 0x3f, 0xbc, 0x90, 0xbb, 0x74, 0x0e,
            0xc3, 0x47, 0x74, 0x3d, 0x90, 0xaa, 0x3f, 0x51, 0xd8, 0xf4, 0x11, 0x84, 0x9f, 0xde, 0x95, 0x1d,
            0xc3, 0xc6, 0x09, 0xd5, 0x9f, 0xfa, 0x66, 0xf9, 0xd8, 0xf0, 0xf7, 0xa0, 0x90, 0xa1, 0xd6, 0xf3,
        )

        private const val ENCV2_PREFIX = "QQMusic EncV2,Key:"
        private val ENCV2_STAGE1_KEY = "386ZJY!@#*\$%^&)(".toByteArray()
        private val ENCV2_STAGE2_KEY = "**#!(\$#%&^a1cZ,T".toByteArray()

        private const val FIRST_SEGMENT_SIZE = 0x80
        private const val OTHER_SEGMENT_SIZE = 0x1400

        private const val TEA_DELTA = 0x9e3779b9L
        private const val TEA_ROUNDS = 16
        private const val SALT_LEN = 2
        private const val ZERO_LEN = 7
        private const val FIXED_PADDING_LEN = 1 + SALT_LEN + ZERO_LEN

        data class Result(val outputPath: String, val ext: String)

        // ---- 位运算助手（全部按 32 位无符号语义）----
        private const val M32 = 0xFFFFFFFFL

        private fun add32(a: Long, b: Long) = (a + b) and M32
        private fun sub32(a: Long, b: Long) = (a - b) and M32
        private fun mul32(a: Long, b: Long) = (a * b) and M32

        private fun readU32BE(b: ByteArray, off: Int): Long =
            ((b[off].toInt() and 0xff).toLong() shl 24) or
                ((b[off + 1].toInt() and 0xff).toLong() shl 16) or
                ((b[off + 2].toInt() and 0xff).toLong() shl 8) or
                (b[off + 3].toInt() and 0xff).toLong()

        private fun readU32LE(b: ByteArray, off: Int): Long =
            (b[off].toInt() and 0xff).toLong() or
                ((b[off + 1].toInt() and 0xff).toLong() shl 8) or
                ((b[off + 2].toInt() and 0xff).toLong() shl 16) or
                ((b[off + 3].toInt() and 0xff).toLong() shl 24)

        private fun readU16LE(b: ByteArray, off: Int): Int =
            (b[off].toInt() and 0xff) or ((b[off + 1].toInt() and 0xff) shl 8)

        // ---- TEA ----
        private fun ecbSingleRound(value: Long, sum: Long, k1: Long, k2: Long): Long {
            val left = add32((value shl 4) and M32, k1)
            val right = add32(value ushr 5, k2)
            return (left xor add32(value, sum) xor right) and M32
        }

        private fun teaDecryptBlock(v0In: Long, v1In: Long, k: LongArray): LongArray {
            var y = v0In and M32
            var z = v1In and M32
            var sum = mul32(TEA_DELTA, TEA_ROUNDS.toLong())
            repeat(TEA_ROUNDS) {
                z = sub32(z, ecbSingleRound(y, sum, k[2], k[3]))
                y = sub32(y, ecbSingleRound(z, sum, k[0], k[1]))
                sum = sub32(sum, TEA_DELTA)
            }
            return longArrayOf(y, z)
        }

        private fun teaDecrypt(ciphertext: ByteArray, keyBytes: ByteArray): ByteArray? {
            val k = parseTeaKey(keyBytes) ?: return null
            val inputLen = ciphertext.size
            if (inputLen < FIXED_PADDING_LEN || inputLen % 8 != 0) return null
            val plain = ByteArray(inputLen)
            var iv1Hi = 0L
            var iv1Lo = 0L
            var iv2Hi = 0L
            var iv2Lo = 0L
            var i = 0
            while (i < inputLen) {
                val cbHi = readU32BE(ciphertext, i)
                val cbLo = readU32BE(ciphertext, i + 4)
                val xHi = cbHi xor iv2Hi
                val xLo = cbLo xor iv2Lo
                val db = teaDecryptBlock(xHi, xLo, k)
                val pbHi = (db[0] xor iv1Hi) and M32
                val pbLo = (db[1] xor iv1Lo) and M32
                writeU32BE(plain, i, pbHi)
                writeU32BE(plain, i + 4, pbLo)
                iv1Hi = cbHi
                iv1Lo = cbLo
                iv2Hi = db[0]
                iv2Lo = db[1]
                i += 8
            }
            val padSize = plain[0].toInt() and 0x07
            val startLoc = 1 + padSize + SALT_LEN
            val endLoc = inputLen - ZERO_LEN
            for (idx in endLoc until inputLen) {
                if (plain[idx].toInt() != 0) return null
            }
            return plain.copyOfRange(startLoc, endLoc)
        }

        private fun writeU32BE(b: ByteArray, off: Int, v: Long) {
            b[off] = ((v ushr 24) and 0xff).toByte()
            b[off + 1] = ((v ushr 16) and 0xff).toByte()
            b[off + 2] = ((v ushr 8) and 0xff).toByte()
            b[off + 3] = (v and 0xff).toByte()
        }

        private fun parseTeaKey(key: ByteArray): LongArray? {
            if (key.size < 16) return null
            return longArrayOf(
                readU32BE(key, 0), readU32BE(key, 4),
                readU32BE(key, 8), readU32BE(key, 12),
            )
        }

        // ---- EncV2 密钥派生 ----
        private fun simpleMakeKey(seed: Int, size: Int): ByteArray {
            val r = ByteArray(size)
            for (i in 0 until size) {
                val v = Math.floor(Math.abs(100.0 * Math.tan(seed + i * 0.1))).toLong()
                r[i] = (v and 0xff).toByte()
            }
            return r
        }

        private fun deriveTeaKey(ekeyHeader: ByteArray): ByteArray {
            val sk = simpleMakeKey(106, 8)
            val tk = ByteArray(16)
            for (i in 0 until 16 step 2) {
                tk[i] = sk[i / 2]
                tk[i + 1] = ekeyHeader[i / 2]
            }
            return tk
        }

        private fun prefixEquals(a: ByteArray, prefix: ByteArray): Boolean {
            if (a.size < prefix.size) return false
            for (i in prefix.indices) if (a[i] != prefix[i]) return false
            return true
        }

        private fun parseEkey(ekeyStr: String): ByteArray =
            parseEncV1KeyBytes(B64.decode(ekeyStr.toByteArray(Charsets.US_ASCII)))

        /**
         * 解析 ekey 的"已解码字节"部分：
         * 若带 EncV2 前缀做双层 TEA；再做 8 字节 header + TEA(body) 的旧结构。
         */
        private fun parseEncV1KeyBytes(ekeyDecoded: ByteArray): ByteArray {
            if (ekeyDecoded.isEmpty()) throw IllegalStateException("密钥太短")
            var encV1Key = ekeyDecoded
            val prefix = ENCV2_PREFIX.toByteArray()
            if (prefixEquals(ekeyDecoded, prefix)) {
                val encV2Blob = ekeyDecoded.copyOfRange(prefix.size, ekeyDecoded.size)
                val stage1 = teaDecrypt(encV2Blob, ENCV2_STAGE1_KEY)
                    ?: throw IllegalStateException("EncV2 第一层解密失败")
                val stage2 = teaDecrypt(stage1, ENCV2_STAGE2_KEY)
                    ?: throw IllegalStateException("EncV2 第二层解密失败")
                // stage2 就是一段 base64 文本
                encV1Key = B64.decode(stage2)
            }
            if (encV1Key.size < 8) throw IllegalStateException("密钥太短")
            val header = encV1Key.copyOfRange(0, 8)
            val body = encV1Key.copyOfRange(8, encV1Key.size)
            if (body.isEmpty()) return header
            val teaKey = deriveTeaKey(header)
            val decryptedBody = teaDecrypt(body, teaKey)
            return if (decryptedBody != null) header + decryptedBody else encV1Key
        }

        // ---- QMC1 简单 XOR ----
        private fun qmc1GetMask(offset: Int): Int {
            var idx = (offset % 0x7fff) and 0x7f
            idx = if (idx > 0x3f) (0x80 - idx) and 0x3f else idx
            return KEY_TABLE[idx]
        }

        /** 测试钩子：QMC1 掩码字节。 */
        internal fun qmc1MaskForTest(offset: Int): Int = qmc1GetMask(offset)

        // ---- QMC2 Map 密文 ----
        private fun scrambleByIndex(value: Int, index: Int): Int {
            val rotation = (index + 4) and 7
            return (((value shl rotation) or (value ushr rotation)) and 0xff)
        }

        private fun mapL(key: ByteArray, offset: Int): Int {
            var off = offset
            if (off > 0x7fff) off %= 0x7fff
            val idx = ((off.toLong() * off + 71214) % key.size).toInt()
            return scrambleByIndex(key[idx].toInt() and 0xff, idx)
        }

        private fun qmc2MapDecrypt(key: ByteArray, buf: ByteArray, offset: Int) {
            for (i in buf.indices) {
                buf[i] = (buf[i].toInt() xor mapL(key, offset + i)).toByte()
            }
        }

        // ---- QMC2 RC4 密文 ----
        private fun rc4CalcHashBase(data: ByteArray): Long {
            var hash = 1u
            for (b in data) {
                val v = b.toUByte().toUInt()
                if (v == 0u) continue
                val next = hash * v
                if (next == 0u || next <= hash) break
                hash = next
            }
            return hash.toLong() and M32
        }

        private fun rc4InitSBox(key: ByteArray): IntArray {
            val n = key.size
            val s = IntArray(n)
            if (n > 256) {
                for (i in 0 until 256) s[i] = i
                for (i in 0 until n - 256) s[256 + i] = i % 256
            } else {
                for (i in 0 until n) s[i] = i
            }
            var j = 0
            for (i in 0 until n) {
                j = (j + s[i] + (key[i].toInt() and 0xff)) % n
                val t = s[i]; s[i] = s[j]; s[j] = t
            }
            return s
        }

        private fun rc4CalcSegmentKey(hash: Long, id: Long, seed: Int): Int {
            val divisor = (id + 1) * seed.toLong()
            if (divisor == 0L) return 0
            val key = hash.toDouble() / divisor * 100.0
            return if (key.isFinite()) Math.floor(key).toInt() else 0
        }

        /** 从 [s] 推进 j/k，返回生成字节。j,k 存于 [jk]。 */
        private fun rc4Derive(n: Int, s: IntArray, jk: IntArray): Int {
            jk[0] = (jk[0] + 1) % n
            jk[1] = (s[jk[0]] + jk[1]) % n
            val a = jk[0]; val b = jk[1]
            val t = s[a]; s[a] = s[b]; s[b] = t
            return s[(s[a] + s[b]) % n]
        }

        private fun rc4EncodeOtherSegment(
            rc4Key: ByteArray,
            hash: Long,
            sBox: IntArray,
            offset: Int,
            buf: ByteArray,
            start: Int,
            len: Int,
        ) {
            val segId = offset / OTHER_SEGMENT_SIZE
            var discard = rc4CalcSegmentKey(
                hash, segId.toLong(), rc4Key[segId and 0x1ff].toInt() and 0xff,
            ) and 0x1ff
            discard += offset % OTHER_SEGMENT_SIZE
            val n = rc4Key.size
            val s = sBox.copyOf()
            val jk = intArrayOf(0, 0)
            for (i in 0 until discard) rc4Derive(n, s, jk)
            for (i in 0 until len) {
                buf[start + i] = (buf[start + i].toInt() xor rc4Derive(n, s, jk)).toByte()
            }
        }

        /** RC4 解密一段连续数据（offset 是绝对偏移）。 */
        private fun rc4DecryptRange(
            rc4Key: ByteArray,
            hash: Long,
            sBox: IntArray,
            offset0: Int,
            buf: ByteArray,
        ) {
            var off = offset0
            var remaining = buf.size
            var pos = 0
            val n = rc4Key.size
            if (off < FIRST_SEGMENT_SIZE) {
                val len = minOf(remaining, FIRST_SEGMENT_SIZE - off)
                for (i in 0 until len) {
                    val seed = rc4Key[(off + i) % n].toInt() and 0xff
                    buf[pos + i] = (buf[pos + i].toInt() xor
                        (rc4Key[rc4CalcSegmentKey(hash, (off + i).toLong(), seed) % n].toInt() and 0xff)
                    ).toByte()
                }
                pos += len; remaining -= len; off += len
            }
            val toAlign = off % OTHER_SEGMENT_SIZE
            if (toAlign != 0) {
                val len = minOf(remaining, OTHER_SEGMENT_SIZE - toAlign)
                rc4EncodeOtherSegment(rc4Key, hash, sBox, off, buf, pos, len)
                pos += len; remaining -= len; off += len
            }
            while (remaining > OTHER_SEGMENT_SIZE) {
                rc4EncodeOtherSegment(rc4Key, hash, sBox, off, buf, pos, OTHER_SEGMENT_SIZE)
                pos += OTHER_SEGMENT_SIZE; remaining -= OTHER_SEGMENT_SIZE; off += OTHER_SEGMENT_SIZE
            }
            if (remaining > 0) {
                rc4EncodeOtherSegment(rc4Key, hash, sBox, off, buf, pos, remaining)
            }
        }

        // ---- 尾部检测 ----
        private const val FT_UNKNOWN = 0
        private const val FT_MUSICEX = 1
        private const val FT_QTAG = 2
        private const val FT_V1 = 3

        private class Footer(
            val type: Int,
            val keySize: Int = 0,
            val ekey: String? = null,
            val metaSizeBE: Int = 0,
        )

        private fun detectFooter(data: ByteArray): Footer {
            if (data.size < 8) return Footer(FT_UNKNOWN)
            val last4 = readU32LE(data, data.size - 4).toInt()
            if (data.size >= 16) {
                val tail = data.copyOfRange(data.size - 8, data.size)
                val musicex = byteArrayOf(
                    'm'.code.toByte(), 'u'.code.toByte(), 's'.code.toByte(), 'i'.code.toByte(),
                    'c'.code.toByte(), 'e'.code.toByte(), 'x'.code.toByte(), 0,
                )
                if (tail.contentEquals(musicex)) {
                    val version = readU32LE(data, data.size - 12).toInt()
                    val footerSize = readU32LE(data, data.size - 16).toInt()
                    val metaSize = footerSize - 16
                    if (version == 1 && metaSize > 0 && metaSize <= data.size - 16) {
                        return Footer(FT_MUSICEX)
                    }
                }
            }
            if (last4 == 0x67615451 && data.size >= 12) { // "QTag"
                val metaSizeBE = readU32BE(data, data.size - 8).toInt()
                val metaEnd = data.size - 8
                val metaStart = maxOf(0, metaEnd - metaSizeBE)
                val meta = data.copyOfRange(metaStart, metaEnd)
                val comma = meta.indexOf(','.code.toByte())
                if (comma != -1) {
                    val ekey = String(meta, 0, comma, Charsets.US_ASCII)
                    return Footer(FT_QTAG, ekey = ekey, metaSizeBE = metaSizeBE)
                }
            }
            if (last4 > 0 && last4 <= 0x400) return Footer(FT_V1, keySize = last4)
            return Footer(FT_UNKNOWN)
        }

        // ---- 主流程 ----
        private val QMC1_EXTS = setOf("qmc0", "qmc2", "qmc3", "qmcflac", "qmcogg")
        private val QMC2_EXTS = setOf("mgg", "mgg0", "mgg1", "mggl", "mflac", "mflac0", "mflach")

        internal fun uniqueOut(destDir: File, base: String, ext: String): String {
            var name = "$base.$ext"
            var n = 2
            while (File(destDir, name).exists()) {
                name = "${base}_$n.$ext"
                n++
            }
            return name
        }

        @Throws(Exception::class)
        fun unlock(src: File, destDir: File, extIn: String): Result {
            require(src.isFile) { "源文件不存在：${src.path}" }
            if (!destDir.exists()) destDir.mkdirs()

            val data = src.readBytes()
            val isQmc1 = QMC1_EXTS.contains(extIn)
            val isQmc2 = QMC2_EXTS.contains(extIn)
            if (!isQmc1 && !isQmc2) {
                throw IllegalStateException("不支持的 QMC 格式：.$extIn")
            }
            val footer = detectFooter(data)

            val decrypted: ByteArray
            if (isQmc1) {
                var decLen = data.size
                if (footer.type == FT_V1) decLen = data.size - 4 - footer.keySize
                decrypted = data.copyOfRange(0, decLen)
                for (i in decrypted.indices) {
                    decrypted[i] =
                        (decrypted[i].toInt() xor qmc1GetMask(i)).toByte()
                }
            } else {
                val audioLen: Int
                val qmcKey: ByteArray
                when (footer.type) {
                    FT_QTAG -> {
                        audioLen = data.size - 8 - footer.metaSizeBE
                        qmcKey = parseEkey(footer.ekey ?: "")
                    }
                    FT_V1 -> {
                        val keyStart = data.size - 4 - footer.keySize
                        audioLen = keyStart
                        qmcKey = parseEncV1KeyBytes(
                            data.copyOfRange(keyStart, data.size - 4),
                        )
                    }
                    else -> throw IllegalStateException(
                        "该文件未内嵌密钥（无 QTag/V1 尾部）且未提供 ekey，无法离线解密",
                    )
                }
                decrypted = data.copyOfRange(0, audioLen)
                if (qmcKey.size > 300) {
                    val hash = rc4CalcHashBase(qmcKey)
                    val sBox = rc4InitSBox(qmcKey)
                    rc4DecryptRange(qmcKey, hash, sBox, 0, decrypted)
                } else {
                    qmc2MapDecrypt(qmcKey, decrypted, 0)
                }
            }

            // 按解密后文件头识别真实格式并落盘
            val head = decrypted.copyOf(minOf(8, decrypted.size))
            val fmt = AudioFormatDetect.detect(head)
                ?: throw IllegalStateException("无法识别解密后的音频格式")
            val outFile = File(destDir, uniqueOut(destDir, src.nameWithoutExtension, fmt))
            try {
                outFile.writeBytes(decrypted)
            } catch (t: Throwable) {
                // 失败收尾：单次写盘中途失败也会留下半截文件
                outFile.delete()
                throw t
            }
            return Result(outFile.absolutePath, fmt)
        }
    }
}
