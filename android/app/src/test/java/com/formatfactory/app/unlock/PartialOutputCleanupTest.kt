package com.formatfactory.app.unlock

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

/**
 * 脱壳失败时的半成品收尾（计划 §10.5 遗留 1 / §11.4 合并项）：
 * 解锁中途失败必须关流并删掉已创建的输出文件，绝不留下损坏产物。
 */
class PartialOutputCleanupTest {

    @Test
    fun deletesPartialOutputAndClosesStream() {
        val dir = File.createTempFile("cleanup_", "").apply { delete(); mkdirs() }
        dir.deleteOnExit()
        val f = File(dir, "song.mp3")
        RandomAccessFile(f, "rw").use { it.write(byteArrayOf(1, 2, 3)) }

        val raf = RandomAccessFile(f, "rw")
        PartialOutputCleanup.remove(raf, f.absolutePath)

        assertFalse("半成品文件必须被删除", f.exists())
        assertTrue("流应已关闭（关闭后写入应失败）", runCatching {
            raf.write(0)
            false
        }.getOrElse { true })
    }

    @Test
    fun nullSafe() {
        PartialOutputCleanup.remove(null, null)
    }

    @Test
    fun toleratesMissingFile() {
        PartialOutputCleanup.remove(null, "/nonexistent/path/song.mp3")
    }
}
