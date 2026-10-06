package com.starksky16.formatfactory.unlock

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * 酷我 .kwm v1 脱壳 JVM 验证（计划 T12）。
 * 算法金标准：unlock-music um/cli algo/kwm/kwm.go（MIT），来源见 android/tools/ref/README.md。
 * 无真实厂商样本，采用"手工构造样本 + 掩码独立推演"验证。
 */
class KwmUnlockerTest {

    private val magic = byteArrayOf(
        0x79, 0x65, 0x65, 0x6C, 0x69, 0x6F, 0x6E, 0x2D,
        0x6B, 0x75, 0x77, 0x6F, 0x2D, 0x74, 0x6D, 0x65
    )

    /** 手工推演掩码：key=1234567890123456789（u64 LE）→ 十进制循环填充 32 字节 ⊕ 常量。 */
    private fun expectedMask(): ByteArray {
        val root = "1234567890123456789" // u64 1234567890123456789 的十进制
        val keyStr = (0 until 32).map { root[it % root.length] }.joinToString("")
        val predefined = "MoOtOiTvINGwd2E6n0E1i7L5t2IoOoNk"
        return ByteArray(32) { (predefined[it].code xor keyStr[it].code).toByte() }
    }

    private fun u64le(v: Long): ByteArray = ByteArray(8) { i -> (v ushr (8 * i)).toByte() }

    /** 组装一个合法的 KWM v1 合成样本：头 0x400 + 密文（明文 ⊕ 掩码循环）。 */
    private fun buildV1Sample(plain: ByteArray): ByteArray {
        val header = ByteArray(0x400)
        magic.copyInto(header)
        header[0x10] = 1 // v1 版本字节
        u64le(1234567890123456789L).copyInto(header, 0x18)
        // 0x30..0x38 码率/格式字段（Go 实现会解析，本实现以解密头探测为准）
        "320mp3".toByteArray().copyInto(header, 0x30)
        val mask = expectedMask()
        val cipher = ByteArray(plain.size) { i ->
            (plain[i].toInt() xor mask[i and 0x1F].toInt()).toByte()
        }
        return header + cipher
    }

    private val plainAudio: ByteArray = ByteArrayOutputStream().apply {
        write(byteArrayOf(0x49, 0x44, 0x33, 0x04)) // "ID3\4" → mp3
        write(ByteArray(300) { (it % 251).toByte() })
    }.toByteArray()

    @Test
    fun decryptsV1RoundTrip() {
        val dir = File.createTempFile("kwm_", "").apply { delete(); mkdirs() }
        dir.deleteOnExit()
        val src = File(dir, "song.kwm")
        src.writeBytes(buildV1Sample(plainAudio))

        val result = KwmUnlocker.unlock(src, dir)

        assertEquals("mp3", result.ext)
        val out = File(result.outputPath)
        assertTrue("输出文件不存在", out.exists())
        assertArrayEquals("解密结果应与明文逐字节一致", plainAudio, out.readBytes())
    }

    @Test
    fun rejectsV2WithClearError() {
        val dir = File.createTempFile("kwm_v2_", "").apply { delete(); mkdirs() }
        dir.deleteOnExit()
        val header = ByteArray(0x400)
        magic.copyInto(header)
        header[0x10] = 2 // v2 版本字节
        u64le(42).copyInto(header, 0x18)
        val src = File(dir, "v2.kwm")
        src.writeBytes(header + ByteArray(64))

        val ex = assertThrows(IllegalStateException::class.java) {
            KwmUnlocker.unlock(src, dir)
        }
        assertTrue("错误信息应说明 v2 暂不支持：${ex.message}", ex.message!!.contains("v2"))
        assertTrue(
            "失败不得残留输出文件",
            dir.listFiles()!!.none { it.name != "v2.kwm" },
        )
    }

    @Test
    fun rejectsBadMagic() {
        val dir = File.createTempFile("kwm_bad_", "").apply { delete(); mkdirs() }
        dir.deleteOnExit()
        val header = ByteArray(0x400)
        "not-kwm-magic!!!!!!".toByteArray().copyInto(header)
        val src = File(dir, "bad.kwm")
        src.writeBytes(header + ByteArray(16))

        assertThrows(IllegalStateException::class.java) { KwmUnlocker.unlock(src, dir) }
    }

    @Test
    fun rejectsTooSmallFile() {
        val dir = File.createTempFile("kwm_small_", "").apply { delete(); mkdirs() }
        dir.deleteOnExit()
        val src = File(dir, "tiny.kwm")
        src.writeBytes(ByteArray(16))

        assertThrows(Exception::class.java) { KwmUnlocker.unlock(src, dir) }
    }
}
