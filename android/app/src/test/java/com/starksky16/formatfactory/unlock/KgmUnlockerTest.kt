package com.starksky16.formatfactory.unlock

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

/**
 * KGM 合成样本往返验证：
 * 算法本身自逆（XOR + 自逆置换），用 transformForTest 把一段带 "fLaC" 头的数据
 * "加密"成 .kgm，再走正式解密路径，应还原出合法 flac。
 */
class KgmUnlockerTest {

    private fun buildSample(ext: String, isVpr: Boolean): File {
        val file = File.createTempFile("sample_", ".$ext")
        val key = byteArrayOf(
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 0, // 第 17 字节 = 0
        )
        // 40 字节 flac 头样 + 填充
        val plain = ByteArray(4096)
        val head = "fLaC".toByteArray()
        for (i in head.indices) plain[i] = head[i]
        for (i in head.size until plain.size) plain[i] = ((i * 7) % 251).toByte()

        RandomAccessFile(file, "rw").use { raf ->
            val header = ByteArray(0x3c)
            header[0x10] = 0x3c // headerLen = 60（小端写入最低字节）
            for (i in key.indices) header[0x1c + i] = key[i]
            raf.write(header)
            for (i in plain.indices) {
                var v = plain[i].toInt() and 0xff
                if (isVpr) {
                    v = v xor (KgmTables.VPRKEY[i % 17] and 0xff)
                }
                raf.writeByte(KgmUnlocker.encodeForTest(v, key, i) and 0xff)
            }
        }
        return file
    }

    @Test
    fun kgmRoundTrip_producesFlac() {
        val src = buildSample("kgm", false)
        val dest = File.createTempFile("out_", "")
        dest.delete()
        dest.mkdirs()
        try {
            val r = KgmUnlocker.unlock(src, dest, false)
            val out = File(r.outputPath)
            assertTrue(out.exists() && out.length() > 0)
            val head = out.inputStream().buffered().readNBytes(4)
            assertArrayEquals("fLaC".toByteArray(), head)
            assertTrue("flac" == r.ext)
        } finally {
            src.delete(); dest.deleteRecursively()
        }
    }
}
