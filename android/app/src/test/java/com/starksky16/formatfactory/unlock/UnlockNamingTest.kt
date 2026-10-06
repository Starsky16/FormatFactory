package com.starksky16.formatfactory.unlock

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * 脱壳输出命名规则（计划 §12.3 步骤 2）：
 * 优先沿用原名，重名时追加 _2、_3 序号，绝不覆盖已有文件。
 */
class UnlockNamingTest {

    private fun newDir(): File =
        File.createTempFile("unlock_naming_", "").apply {
            delete()
            mkdirs()
        }

    @Test
    fun keepsOriginalName_whenDirIsEmpty() {
        val dir = newDir()
        dir.deleteOnExit()
        assertEquals("song.mp3", NcmUnlocker.uniqueName(dir, "song", "mp3"))
        assertEquals("song.flac", QmcUnlocker.uniqueOut(dir, "song", "flac"))
        assertEquals("song.mp3", KgmUnlocker.uniqueOut(dir, "song", "mp3"))
    }

    @Test
    fun appendsSequence_whenNameTaken() {
        val dir = newDir()
        dir.deleteOnExit()
        File(dir, "song.mp3").writeBytes(byteArrayOf())
        File(dir, "song.flac").writeBytes(byteArrayOf())

        assertEquals("song_2.mp3", NcmUnlocker.uniqueName(dir, "song", "mp3"))
        assertEquals("song_2.flac", QmcUnlocker.uniqueOut(dir, "song", "flac"))
        assertEquals("song_2.mp3", KgmUnlocker.uniqueOut(dir, "song", "mp3"))
    }

    @Test
    fun keepsCounting_whenSequenceAlsoTaken() {
        val dir = newDir()
        dir.deleteOnExit()
        File(dir, "song.mp3").writeBytes(byteArrayOf())
        File(dir, "song_2.mp3").writeBytes(byteArrayOf())
        File(dir, "song.flac").writeBytes(byteArrayOf())
        File(dir, "song_2.flac").writeBytes(byteArrayOf())

        assertEquals("song_3.mp3", NcmUnlocker.uniqueName(dir, "song", "mp3"))
        assertEquals("song_3.flac", QmcUnlocker.uniqueOut(dir, "song", "flac"))
        assertEquals("song_3.mp3", KgmUnlocker.uniqueOut(dir, "song", "mp3"))
    }
}
