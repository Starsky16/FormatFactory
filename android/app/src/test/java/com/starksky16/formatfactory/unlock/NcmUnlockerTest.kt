package com.starksky16.formatfactory.unlock

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 用 taurusxin/ncmdump 仓库自带的真实 ncm 样本做本地 JVM 验证：
 * 解密结果必须能以 "fLaC" 或 "ID3"(mp3) 开头，否则说明算法移植有误。
 */
class NcmUnlockerTest {

    @Test
    fun unlockRealSample_outputsFlacOrMp3() {
        val res = javaClass.classLoader!!.getResource("ncm_sample.ncm")
        assertNotNull("缺少测试样本 android/app/src/test/resources/ncm_sample.ncm", res)
        val src = File(res!!.toURI())

        val dest = File.createTempFile("ncm_test_", "")
        dest.delete()
        dest.mkdirs()
        try {
            val result = NcmUnlocker.unlock(src, dest)
            val out = File(result.outputPath)
            assertTrue("输出文件不存在", out.exists())
            assertTrue("输出文件为空", out.length() > 0)

            val head = out.inputStream().buffered().readNBytes(4)
            val isMp3 = head.size >= 3 &&
                head[0] == 0x49.toByte() &&
                head[1] == 0x44.toByte() &&
                head[2] == 0x33.toByte()
            val isFlac = head.contentEquals("fLaC".toByteArray())
            assertTrue("解密输出头既不是 ID3 也不是 fLaC：${head.toList()}，实际扩展名=${result.ext}", isMp3 || isFlac)
        } finally {
            dest.deleteRecursively()
        }
    }
}
