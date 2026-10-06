package com.starksky16.formatfactory.unlock

/**
 * 音频格式探测：按文件头字节识别脱壳后的真实格式。
 */
object AudioFormatDetect {
    /** head 至少 4 字节。返回 'flac'/'mp3'/'wav'/'ogg'/'m4a'，未知返回 null。 */
    fun detect(head: ByteArray): String? {
        val n = minOf(8, head.size)
        if (n < 2) return null
        val c = head.copyOf(n)
        if (c.size >= 4) {
            val head4 = c.copyOfRange(0, 4)
            if (head4.contentEquals("fLaC".toByteArray())) return "flac"
            if (head4.contentEquals("RIFF".toByteArray())) return "wav"
            if (head4.contentEquals("OggS".toByteArray())) return "ogg"
            if (head4.contentEquals("M4A ".toByteArray())) return "m4a"
        }
        if (c.size >= 8) {
            val sub = c.copyOfRange(4, 8)
            if (sub.contentEquals("ftyp".toByteArray())) return "m4a"
        }
        if (c.size >= 3 &&
            c[0].toInt() == 0x49 && c[1].toInt() == 0x44 && c[2].toInt() == 0x33
        ) return "mp3"
        if (c.size >= 2 &&
            c[0].toInt() == 0xFF && (c[1].toInt() and 0xE0) == 0xE0
        ) return "mp3"
        return null
    }
}

/** 小型 Base64（标准字母表），输入输出都是字节；JVM/Android 通用，便于单测。 */
internal object B64 {
    private const val ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    fun decode(input: ByteArray): ByteArray {
        val out = ArrayList<Byte>()
        var buffer = 0
        var bits = 0
        for (c in input) {
            val ci = c.toInt()
            if (ci == '\r'.code || ci == '\n'.code || ci == ' '.code) continue
            if (ci == '='.code) continue
            val v = ALPHABET.indexOf(ci.toChar())
            if (v < 0) continue
            buffer = (buffer shl 6) or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.add(((buffer ushr bits) and 0xFF).toByte())
            }
        }
        return out.toByteArray()
    }
}
