package com.formatfactory.app.unlock

import java.io.File
import java.io.RandomAccessFile

/**
 * 脱壳失败时的收尾：关流并删除已创建的半成品输出。
 * 流式解密（NCM/KGM）中途 IO 失败会留下写了一半的音频文件，
 * 必须删掉，避免用户拿到损坏产物；Dart 侧只知道输出目录、删不到具体文件。
 */
internal object PartialOutputCleanup {
    fun remove(raf: RandomAccessFile?, outputPath: String?) {
        try {
            raf?.close()
        } catch (_: Exception) {
            // 关闭失败不阻断删除
        }
        if (outputPath != null) File(outputPath).delete()
    }
}
