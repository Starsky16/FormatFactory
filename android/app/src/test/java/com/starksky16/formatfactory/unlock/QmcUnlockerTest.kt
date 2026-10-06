package com.starksky16.formatfactory.unlock

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

/**
 * QMC1 合成样本往返验证：用同一掩码把带 "OggS" 头的数据"加密"成 .qmcogg，
 * 再走正式解密应还原出 Ogg（ogg）。
 */
class QmcUnlockerTest {

    private fun buildSample(): File {
        val file = File.createTempFile("sample_", ".qmcogg")
        val plain = ByteArray(4096)
        val head = "OggS".toByteArray()
        for (i in head.indices) plain[i] = head[i]
        for (i in head.size until plain.size) plain[i] = ((i * 13) % 251).toByte()

        RandomAccessFile(file, "rw").use { raf ->
            val enc = ByteArray(plain.size)
            for (i in plain.indices) {
                enc[i] = (plain[i].toInt() xor QmcUnlocker.qmc1MaskForTest(i)).toByte()
            }
            raf.write(enc)
        }
        return file
    }

    @Test
    fun qmc1RoundTrip_producesOgg() {
        val src = buildSample()
        val dest = File.createTempFile("out_", "")
        dest.delete()
        dest.mkdirs()
        try {
            val r = QmcUnlocker.unlock(src, dest, "qmcogg")
            val out = File(r.outputPath)
            assertTrue(out.exists() && out.length() > 0)
            val head = out.inputStream().buffered().readNBytes(4)
            assertArrayEquals("OggS".toByteArray(), head)
            assertTrue("ogg" == r.ext)
        } finally {
            src.delete(); dest.deleteRecursively()
        }
    }
}
