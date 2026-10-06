package com.starksky16.formatfactory

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import com.starksky16.formatfactory.unlock.KgmUnlocker
import com.starksky16.formatfactory.unlock.KwmUnlocker
import com.starksky16.formatfactory.unlock.NcmUnlocker
import com.starksky16.formatfactory.unlock.QmcUnlocker

/// 原生存储通道，供 Dart 侧 StorageAccess 调用：
///  - pickOutputDir    ：打开系统 SAF 目录选择器并持久化授权
///  - copyToTree       ：把本地文件复制进用户选择的 SAF 目录
///  - copyToDownloads  ：把本地文件导入系统"下载"目录（MediaStore，Android 10+ 免权限）
/// 用 FlutterFragmentActivity（基于 Fragment/ComponentActivity），
/// 以获得 registerForActivityResult 能力。
class MainActivity : FlutterFragmentActivity(), MethodChannel.MethodCallHandler {

    private var pendingPick: MethodChannel.Result? = null

    private val openTree =
        registerForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri: Uri? ->
            val result = pendingPick
            pendingPick = null
            if (uri != null) {
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                } catch (_: Exception) {
                    // 个别 ROM 可能不区分读写 flag，忽略即可
                }
                result?.success(uri.toString())
            } else {
                result?.success(null) // 用户取消
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 存储通道（选目录 / 复制到 SAF 目录）
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.starksky16.formatfactory/storage",
        ).setMethodCallHandler(this)
        // 音乐脱壳通道（.ncm 等解密）—— 必须单独注册，否则 Dart 会报 MissingPluginException
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.starksky16.formatfactory/unlock",
        ).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // "所有文件访问"权威判定：Environment.isExternalStorageManager()。
            // Android 16 上 permission_handler 的 AppOps 查询不可靠（系统设置已
            // 授权但插件仍报未授权），必须用平台 API 判定。
            // API < 30 无此权限模型，直接返回 true。
            "isExternalStorageManager" -> {
                @Suppress("DEPRECATION")
                result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
                            Environment.isExternalStorageManager()
                )
            }
            // 系统版本权威判定源（Build.VERSION.SDK_INT）。Dart 侧 Platform.version
            // 返回的是 Dart 运行时版本（"3.x…"），拿 Android 版本必须走这里。
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            // 权限诊断：把整条判定链路一次性导出（返回文本行列表），
            // 供设置页一键复制、用户回贴定位 ROM 魔改问题。
            "diagnose" -> result.success(buildList {
                add("sdkInt=${Build.VERSION.SDK_INT}")
                fun perm(name: String) {
                    val granted = checkSelfPermission(name) ==
                            android.content.pm.PackageManager.PERMISSION_GRANTED
                    add("checkSelfPermission[$name]=${if (granted) "GRANTED" else "DENIED"}")
                }
                perm(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                perm(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    add("isExternalStorageManager=${Environment.isExternalStorageManager()}")
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    add("isExternalStorageLegacy=${Environment.isExternalStorageLegacy()}")
                }
                // AppOps 层（华为系 ROM 有在此造假/漏登记的历史）。
                // ⚠️ 必须接 Throwable：checkOpNoThrow(String,…) 是 API 29+ 重载，
                // Android 9 上调用抛 NoSuchMethodError（Error 不是 Exception），
                // 若只接 Exception 会把整个诊断带崩（实测教训）。
                val appOps = getSystemService(APP_OPS_SERVICE) as android.app.AppOpsManager
                val uid = android.os.Process.myUid()
                val packageName = packageName
                fun op(modeOf: (android.app.AppOpsManager) -> Any?, label: String) {
                    try {
                        add("$label=${modeOf(appOps)}")
                    } catch (e: Throwable) {
                        add("$label=异常:${e.javaClass.simpleName}:${e.message}")
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    op({ it.checkOpNoThrow(
                        android.app.AppOpsManager.OPSTR_READ_EXTERNAL_STORAGE, uid, packageName
                    ) }, "appops.read")
                } else {
                    // Android 9：字符串版不存在，走 int 版（公开 API，反射调用）
                    op({
                        val m = appOps.javaClass.getMethod(
                            "checkOpNoThrow",
                            Int::class.javaPrimitiveType,
                            Int::class.javaPrimitiveType,
                            String::class.java,
                        )
                        m.invoke(appOps, 43, uid, packageName) // 43 = OP_READ_EXTERNAL_STORAGE
                    }, "appops.read(int)")
                }
                // 文件系统实测：根目录 / 下载目录 / 应用专属目录
                fun probe(path: String) {
                    val f = File(path)
                    add("probe[$path] exists=${f.exists()} canRead=${f.canRead()}")
                    try {
                        val n = f.listFiles()?.size ?: -1
                        add("  list=$n")
                    } catch (e: Exception) {
                        add("  list异常=${e.javaClass.simpleName}:${e.message}")
                    }
                }
                probe("/storage/emulated/0/")
                probe("/storage/emulated/0/Download")
                probe(getExternalFilesDir(null)?.absolutePath ?: "/data/unknown")
            })
            "pickOutputDir" -> {
                pendingPick = result
                openTree.launch(null)
            }
            "copyToTree" -> {
                val treeUri = call.argument<String>("treeUri")
                val fileName = call.argument<String>("fileName")
                val srcPath = call.argument<String>("srcPath")
                if (treeUri == null || fileName == null || srcPath == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                try {
                    // 显式赋给非空 val，便于编译器安全使用
                    val dir = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
                        ?: throw IllegalStateException("所选目录已不可访问，请重新选择")
                    var target: DocumentFile? = dir.findFile(fileName)
                    if (target == null) {
                        target = dir.createFile("application/octet-stream", fileName)
                            ?: throw IllegalStateException("无法在所选目录创建文件")
                    }
                    val out = contentResolver.openOutputStream(target.uri)
                        ?: throw IllegalStateException("无法打开输出流")
                    out.use { os ->
                        FileInputStream(File(srcPath)).use { ins -> ins.copyTo(os) }
                    }
                    result.success(target.uri.toString())
                } catch (e: Exception) {
                    result.error("copy_failed", e.message, null)
                }
            }
            // ===== B 站缓存 SAF 副本导入 =====
            // Android 13+ 系统严格封锁其他应用的 Android/data（MANAGE 也读不了、
            // SAF 也进不去），直读路径失效。fallback：用户用系统文件管理器把
            // B 站缓存目录复制到普通位置后，从这里选副本目录 → 整树镜像到
            // 应用工作区 → Dart 侧用现成的 BiliCache.scan 扫描镜像。
            "importTree" -> {
                val treeUri = call.argument<String>("treeUri")
                val destDir = call.argument<String>("destDir")
                if (treeUri == null || destDir == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                runAsync(result, errorCode = "import_failed") {
                    val root = DocumentFile.fromTreeUri(this, Uri.parse(treeUri))
                        ?: throw IllegalStateException("所选目录已不可访问，请重新选择")
                    val dest = File(destDir)
                    // 重新导入时清掉上次镜像，避免残留旧文件混进扫描结果
                    if (dest.exists()) dest.deleteRecursively()
                    if (!dest.mkdirs()) throw IllegalStateException("无法创建工作目录")
                    var files = 0
                    var bytes = 0L
                    fun walk(src: DocumentFile, rel: String) {
                        val outDir = File(dest, rel)
                        if (!outDir.exists() && !outDir.mkdirs()) {
                            throw IllegalStateException("无法创建目录：${outDir.path}")
                        }
                        for (child in src.listFiles()) {
                            val name = child.name ?: continue
                            if (child.isDirectory) {
                                walk(child, if (rel.isEmpty()) name else "$rel/$name")
                            } else {
                                val out = File(outDir, name)
                                contentResolver.openInputStream(child.uri)?.use { ins ->
                                    out.outputStream().use { os -> ins.copyTo(os) }
                                } ?: throw IllegalStateException("无法读取文件：$name")
                                files++
                                bytes += out.length()
                            }
                        }
                    }
                    walk(root, "")
                    mapOf(
                        "files" to files,
                        "bytes" to bytes,
                        "mirrorDir" to dest.absolutePath,
                    )
                }
            }
            "copyToDownloads" -> {
                val relativeDir = call.argument<String>("relativeDir")
                val fileName = call.argument<String>("fileName")
                val srcPath = call.argument<String>("srcPath")
                if (relativeDir == null || fileName == null || srcPath == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                // 注意：Dart 侧是 invokeMethod<String>，这里必须直接返回 String，
                // 返回 Map 会被平台通道按 String 强转失败（表现为"成功也报失败"）。
                runAsync(result, errorCode = "copy_failed") {
                    copyIntoDownloads(relativeDir, fileName, srcPath)
                }
            }
            // ===== 音乐脱壳（.ncm / .qmc / .kgm 等）=====
            "unlockNcm" -> {
                val src = call.argument<String>("src")
                val destDir = call.argument<String>("destDir")
                if (src == null || destDir == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                // 解密是大文件 IO，放到后台线程，完成后切回主线程回调
                runAsync(result) {
                    val r = NcmUnlocker.unlock(File(src), File(destDir))
                    mapOf("path" to r.outputPath, "ext" to r.ext)
                }
            }
            "unlockQmc" -> {
                val src = call.argument<String>("src")
                val destDir = call.argument<String>("destDir")
                val format = call.argument<String>("format")
                if (src == null || destDir == null || format == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                runAsync(result) {
                    val r = QmcUnlocker.unlock(File(src), File(destDir), format)
                    mapOf("path" to r.outputPath, "ext" to r.ext)
                }
            }
            "unlockKgm" -> {
                val src = call.argument<String>("src")
                val destDir = call.argument<String>("destDir")
                val format = call.argument<String>("format")
                if (src == null || destDir == null || format == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                runAsync(result) {
                    val isVpr = format == "vpr"
                    val r = KgmUnlocker.unlock(File(src), File(destDir), isVpr)
                    mapOf("path" to r.outputPath, "ext" to r.ext)
                }
            }
            "unlockKwm" -> {
                val src = call.argument<String>("src")
                val destDir = call.argument<String>("destDir")
                if (src == null || destDir == null) {
                    result.error("bad_args", "缺少参数", null)
                    return
                }
                runAsync(result) {
                    val r = KwmUnlocker.unlock(File(src), File(destDir))
                    mapOf("path" to r.outputPath, "ext" to r.ext)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 把本地文件导入系统"下载"目录（MediaStore），返回新文件的 uri 字符串。
     * 分 API 级别实现：Android 10+ 用 MediaStore.Downloads（**无需任何存储权限**）；
     * Android 9 及以下用 MediaStore.Files + 绝对路径（仍需经典存储权限，
     * Dart 侧会先申请，拿不到就失败）。
     */
    private fun copyIntoDownloads(
        relativeDir: String,
        fileName: String,
        srcPath: String,
    ): String = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        copyIntoDownloadsQ(relativeDir, fileName, srcPath)
    } else {
        copyIntoDownloadsLegacy(relativeDir, fileName, srcPath)
    }

    /** Android 10+：MediaStore.Downloads + RELATIVE_PATH，不需要任何存储权限。 */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun copyIntoDownloadsQ(
        relativeDir: String,
        fileName: String,
        srcPath: String,
    ): String {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(fileName))
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection =
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = contentResolver.insert(collection, values)
            ?: throw IllegalStateException("无法在系统下载目录创建文件")
        try {
            writeFileInto(uri, srcPath)
            // 写完再取消 pending，避免文件管理器读到半截文件；
            // 取消 pending 失败就把条目删掉，否则会留下一个永远看不见的 pending 文件
            val done = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            if (contentResolver.update(uri, done, null, null) <= 0) {
                throw IllegalStateException("无法提交文件到系统下载目录")
            }
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null) // 失败不留空壳/半截文件
            throw e
        }
        return uri.toString()
    }

    /** Android 9 及以下：MediaStore.Files + DATA 绝对路径。 */
    @Suppress("DEPRECATION")
    private fun copyIntoDownloadsLegacy(
        relativeDir: String,
        fileName: String,
        srcPath: String,
    ): String {
        val dir = File(Environment.getExternalStorageDirectory(), relativeDir)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("无法创建目录：${dir.path}")
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(fileName))
            put(MediaStore.MediaColumns.DATA, File(dir, fileName).path)
        }
        val uri = contentResolver.insert(
            MediaStore.Files.getContentUri("external"),
            values,
        ) ?: throw IllegalStateException("无法在系统下载目录创建文件（可能没有存储权限）")
        try {
            writeFileInto(uri, srcPath)
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null) // 失败不留空壳文件
            throw e
        }
        return uri.toString()
    }

    /** 把 [srcPath] 的内容写进 [uri]；失败由调用方删除刚插入的条目。 */
    private fun writeFileInto(uri: Uri, srcPath: String) {
        val out = contentResolver.openOutputStream(uri)
            ?: throw IllegalStateException("无法打开输出流")
        out.use { os ->
            FileInputStream(File(srcPath)).use { ins -> ins.copyTo(os) }
        }
    }

    /** 按扩展名猜 MIME，猜不到就用 octet-stream（让文件管理器能正确归类）。 */
    private fun mimeOf(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    /**
     * 后台线程执行耗时 IO，完成后切回主线程返回结果。
     * 返回值类型必须与 Dart 侧的接收方式一致（脱壳用 invokeMapMethod、
     * 导入下载目录用 invokeMethod<String>），否则平台通道强转会抛异常、被 Dart 吞成失败。
     */
    private fun <T> runAsync(
        result: MethodChannel.Result,
        errorCode: String = "unlock_failed",
        job: () -> T,
    ) {
        Thread {
            try {
                val r = job()
                runOnUiThread { result.success(r) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error(
                        errorCode,
                        e.message ?: "操作失败",
                        null,
                    )
                }
            }
        }.start()
    }
}
