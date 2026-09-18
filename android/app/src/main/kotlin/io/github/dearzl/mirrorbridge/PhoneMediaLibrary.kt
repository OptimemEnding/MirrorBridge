package io.github.dearzl.mirrorbridge

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.*
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.*
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Size
import androidx.core.content.FileProvider
import io.flutter.plugin.common.*
import java.io.*
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// Owns phone-library access, references and mutations; camera transport never
// infers photo identity or performs gallery bookkeeping.
class PhoneMediaLibrary(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val log: (String) -> Unit,
) {
    private companion object {
        const val MAX_LUT_BYTES = 64 * 1024 * 1024
    }

    private val handler = Handler(Looper.getMainLooper())
    private val imageExecutor = Executors.newSingleThreadExecutor()

    private val recordDetails =
        object : LinkedHashMap<String, Pair<String?, Map<String, String>>>(128, .75f, true) {
            override fun removeEldestEntry(
                eldest: MutableMap.MutableEntry<String, Pair<String?, Map<String, String>>>?
            ) = size > 512
        }
    private var pickerResult: MethodChannel.Result? = null
    private var pickerKind: String = "media"
    private var storagePermissionResult: MethodChannel.Result? = null
    private var mediaPermissionResult: MethodChannel.Result? = null
    @Volatile private var deleteConsent: ArrayBlockingQueue<Boolean>? = null
    @Volatile private var lookupConsent: ArrayBlockingQueue<Boolean>? = null
    val root: File
        get() =
            File(
                    activity.getExternalFilesDir(Environment.DIRECTORY_PICTURES)
                        ?: activity.filesDir,
                    "镜桥",
                )
                .apply { mkdirs() }

    init {
        clearCaches(includeEditor = true)
        // Older releases stored partial transfers beside persistent camera files.
        // Only incomplete transfers are disposable; complete media files remain untouched.
        root.listFiles()?.filter { it.isFile && it.name.endsWith(".part") }?.forEach {
            check(it.delete()) { "未完成下载清理失败：${it.name}" }
        }
    }

    @Synchronized fun <T> imageTransaction(block: () -> T): T = block()

    @Synchronized private fun clearCaches(includeEditor: Boolean = false) {
        recordDetails.clear()
        val roots = listOf(activity.cacheDir) + activity.externalCacheDirs.filterNotNull() +
            listOf(File(root, "preview_cache"), File(root, "preview_cache_expired"))
        for (directory in roots) {
            directory.listFiles()?.forEach { child ->
                if (!includeEditor && child.name == "editor_render") return@forEach
                check(child.deleteRecursively()) { "缓存清理失败：${child.name}" }
            }
        }
    }

    private fun releasePublishedCopy(path: String, reference: String): Boolean {
        val file = File(path).canonicalFile
        if (!file.exists()) return true
        val viewingDownload = file.parentFile?.let {
            it.parentFile?.canonicalPath == activity.cacheDir.canonicalPath && it.name.startsWith("sync_")
        } == true
        require(file.path.startsWith(root.canonicalPath + File.separator) || viewingDownload) { "不是本应用暂存文件" }
        val uri = Uri.parse(reference)
        // Compare exact bytes before dropping the private staging file.
        val sourceHash = file.inputStream().use { digestStream(it) }
        val publishedHash = activity.contentResolver.openInputStream(uri)?.use { digestStream(it) }
        check(sourceHash == publishedHash) { "相册副本校验失败，保留暂存文件" }
        check(file.delete()) { "无法删除已发布的暂存文件" }
        return true
    }

    private fun digestStream(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(128 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun fail(result: MethodChannel.Result, e: Throwable) {
        log("media: ${e.message}")
        result.error("MEDIA_LIBRARY", e.message ?: e.javaClass.simpleName, null)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "pick" ->
                pick(
                    call.argument<String>("kind") ?: "media",
                    call.argument<Boolean>("multiple") == true,
                    result,
                )
            "permissions" -> {
                if (
                    Build.VERSION.SDK_INT < 29 &&
                        activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                            PackageManager.PERMISSION_GRANTED
                ) {
                    if (storagePermissionResult != null)
                        result.error("PERMISSION_BUSY", "请处理权限窗口", null)
                    else {
                        storagePermissionResult = result
                        activity.requestPermissions(
                            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                            704,
                        )
                    }
                } else {
                    if (
                        Build.VERSION.SDK_INT >= 33 &&
                            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                                PackageManager.PERMISSION_GRANTED
                    )
                        activity.requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            702,
                        )
                    result.success(null)
                }
            }
            "mediaPermissions" -> requestMediaPermissions(result)
            "share" ->
                try {
                    share(
                        call.argument<List<String>>("sources")
                            ?: call.argument<List<String>>("paths")
                            ?: emptyList()
                    )
                    result.success(null)
                } catch (e: Throwable) {
                    fail(result, e)
                }
            "openVideo" ->
                try {
                    val source = call.argument<String>("source") ?: call.argument<String>("path")!!
                    val uri = shareUri(source)
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "video/*")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    )
                    result.success(null)
                } catch (e: Throwable) {
                    fail(result, e)
                }
            "clearCaches",
            "releasePublishedCopy",
            "publish",
            "mediaExists",
            "localMissing",
            "purgeLocal",
            "deleteLocal",
            "exif",
            "thumbnail",
            "editSource",
            "readImageBytes",
            "fullImageSource",
            "referenceState",
            "referencePath",
            "referenceStates",
            "listAlbum",
            "listRecorded" ->
                imageExecutor.execute {
                    try {
                        val value = execute(call)
                        handler.post { result.success(value) }
                    } catch (e: Throwable) {
                        handler.post { fail(result, e) }
                    }
                }
            else -> return false
        }
        return true
    }

    private fun execute(call: MethodCall): Any? =
        when (call.method) {
            "clearCaches" -> { clearCaches(); true }
            "releasePublishedCopy" -> releasePublishedCopy(call.argument<String>("path")!!, call.argument<String>("uri")!!)
            "publish" ->
                publish(
                    File(call.argument<String>("path")!!),
                    call.argument<String>("name")!!,
                    call.argument<String>("origin") ?: "cameraSync",
                )
            "mediaExists" -> {
                val uri = Uri.parse(call.argument<String>("uri")!!)
                activity.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
            }
            "localMissing" -> uriMissing(Uri.parse(call.argument<String>("uri")!!))
            "purgeLocal" -> {
                for (key in listOf("path", "thumbnail")) {
                    val path = call.argument<String>(key)
                    if (!path.isNullOrEmpty()) {
                        val file = File(path).canonicalFile
                        if (
                            file.path.startsWith(root.canonicalPath + File.separator) ||
                                file.path.startsWith(
                                    activity.cacheDir.canonicalPath + File.separator
                                )
                        ) {
                            if (file.exists()) check(file.delete()) { "清理本地文件失败" }
                        }
                    }
                }
                prunePublications()
                true
            }
            "deleteLocal" -> {
                val uris =
                    linkedSetOf(call.argument<String>("uri"), call.argument<String>("sourceUri"))
                        .filterNotNull()
                        .filter { it.isNotEmpty() }
                for (uri in uris.distinctBy { mediaKey(Uri.parse(it)) }) deleteUri(Uri.parse(uri))
                val path = call.argument<String>("path")
                if (!path.isNullOrEmpty()) {
                    val file = File(path).canonicalFile
                    check(file.path.startsWith(root.canonicalPath + File.separator)) {
                        "不属于本应用媒体目录"
                    }
                    if (file.exists()) check(file.delete()) { "删除文件失败" }
                }
                val thumbnail = call.argument<String>("thumbnail")
                if (!thumbnail.isNullOrEmpty()) {
                    val file = File(thumbnail).canonicalFile
                    if (
                        file.path.startsWith(activity.cacheDir.canonicalPath + File.separator) &&
                            file.exists()
                    )
                        file.delete()
                }
                prunePublications()
                true
            }
            "exif" -> exif(call.argument<String>("source") ?: call.argument<String>("path")!!)
            "thumbnail" ->
                thumbnail(call.argument<String>("source") ?: call.argument<String>("path")!!)
            "readImageBytes" -> {
                val source = call.argument<String>("source")!!
                require(source.startsWith("content://")) { "Expected media reference" }
                sourceInput(source).use { it.readBytes() }
            }
            "fullImageSource" -> {
                val source = call.argument<String>("source")!!
                val name = if (source.startsWith("content://")) displayName(Uri.parse(source)) else File(source).name
                val viewDirectory = call.argument<String>("viewDirectory")
                if (viewDirectory != null) {
                    val directory = File(viewDirectory).canonicalFile
                    val allowed = File(activity.cacheDir, "image_view_sessions").canonicalPath + File.separator
                    require(directory.path.startsWith(allowed) && directory.isDirectory) { "Invalid viewing session" }
                    val raw = name.substringAfterLast('.', "").lowercase() in rawExtensions
                    // Read gallery references directly. RAW only writes its embedded JPEG preview.
                    if (raw) rawThumbnail(source, File(directory, "preview.jpg")) else source
                } else if (name.substringAfterLast('.', "").lowercase() in rawExtensions) thumbnail(source)
                else materialize(source).path
            }
            "editSource" -> imageTransaction {
                val previewFile = File(thumbnail(call.argument<String>("source") ?: call.argument<String>("path")!!) ?: error("RAW 文件中未找到可用 JPEG"))
                val directory = File(activity.cacheDir, "editor_render").apply { mkdirs() }
                previewFile.copyTo(File.createTempFile("raw_", ".jpg", directory), overwrite = true).path
            }
            "referenceStates" -> (call.argument<List<String>>("uris") ?: emptyList()).map { referenceState(Uri.parse(it)) }
            "referencePath" -> referencePath(Uri.parse(call.argument<String>("uri")!!))
            "referenceState" -> referenceState(Uri.parse(call.argument<String>("uri")!!))
            "listAlbum", "listRecorded" -> emptyList<Map<String, Any?>>()
            else -> error("未知媒体操作 ${call.method}")
        }

    private fun requestMediaPermissions(result: MethodChannel.Result) {
        val required =
            if (Build.VERSION.SDK_INT >= 33) {
                arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            } else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        val missing = required.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        if (mediaPermissionResult != null) {
            result.error("PERMISSION_BUSY", "请处理媒体访问权限窗口", null)
            return
        }
        mediaPermissionResult = result
        activity.requestPermissions(missing.toTypedArray(), 706)
    }

    private val rawExtensions =
        setOf("nef", "nrw", "dng", "arw", "cr2", "cr3", "raf", "rw2", "orf", "pef")
    private val videoExtensions = setOf("mp4", "mov", "m4v", "avi", "mkv", "webm")
    private val imageExtensions =
        rawExtensions + setOf("jpg", "jpeg", "png", "heic", "heif", "webp", "avif")

    private fun mime(name: String): String =
        when (name.substringAfterLast('.').lowercase()) {
            "nef",
            "nrw" -> "image/x-nikon-nef"
            "dng" -> "image/x-adobe-dng"
            "mp4",
            "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "png" -> "image/png"
            "heic",
            "heif" -> "image/heic"
            "webp" -> "image/webp"
            else -> "image/jpeg"
        }

    private fun publish(file: File, name: String, origin: String): String {
        check(file.isFile && file.length() > 0) { "没有可发布的完整文件" }
        if (Build.VERSION.SDK_INT < 29) {
            val dir =
                File(
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_PICTURES
                        ),
                        "镜桥",
                    )
                    .apply { mkdirs() }
            val target = File(dir, "${System.currentTimeMillis()}_$name")
            file.copyTo(target)
            val completed = java.util.concurrent.CountDownLatch(1)
            var scanned: Uri? = null
            MediaScannerConnection.scanFile(activity, arrayOf(target.path), arrayOf(mime(name))) {
                _,
                uri ->
                scanned = uri
                completed.countDown()
            }
            check(completed.await(15, TimeUnit.SECONDS) && scanned != null) { "系统相册索引未完成" }
            rememberOrigin(scanned!!, origin)
            return scanned.toString()
        }
        val publicationKey = digestText("${file.canonicalPath}:${System.nanoTime()}:$origin")
        val ledger = activity.getSharedPreferences("media_publications", Context.MODE_PRIVATE)
        val collection =
            if (mime(name).startsWith("video"))
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val values =
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime(name))
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    Environment.DIRECTORY_DCIM + "/镜桥",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        val resolver = activity.contentResolver
        val uri = resolver.insert(collection, values) ?: error("无法创建相册项目")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                file.inputStream().use { input -> input.copyTo(out, 128 * 1024) }
            } ?: error("无法写入相册")
            check(resolver.openFileDescriptor(uri, "r")?.use { it.statSize } == file.length()) { "系统相册文件大小校验失败" }
            // Record the media origin before publishing the item to MediaStore.
            rememberOrigin(uri, origin)
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) },
                null,
                null,
            )
            check(ledger.edit().putString(publicationKey, uri.toString()).commit()) { "无法保存相册发布记录" }
            return uri.toString()
        } catch (e: Throwable) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    private fun prunePublications() {
        val ledger = activity.getSharedPreferences("media_publications", Context.MODE_PRIVATE)
        val edit = ledger.edit()
        for ((key, value) in ledger.all) {
            if (value !is String) continue
            try {
                val missing =
                    activity.contentResolver
                        .query(Uri.parse(value), arrayOf("_id"), null, null, null)
                        ?.use { !it.moveToFirst() } ?: false
                if (missing) edit.remove(key)
            } catch (_: SecurityException) {
                /* Permission loss does not prove deletion. */
            }
        }
        edit.apply()
    }

    private fun uriMissing(uri: Uri): Boolean =
        try {
            activity.contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { !it.moveToFirst() } ?: true
        } catch (_: FileNotFoundException) {
            true
        }

    private fun requestDeleteConsent(pending: PendingIntent): Boolean {
        check(deleteConsent == null) { "已有媒体删除确认窗口" }
        val response = ArrayBlockingQueue<Boolean>(1)
        deleteConsent = response
        handler.post {
            try {
                activity.startIntentSenderForResult(pending.intentSender, 707, null, 0, 0, 0)
            } catch (e: Throwable) {
                response.offer(false)
                log("delete consent launch failed: ${e.message}")
            }
        }
        val approved = response.poll(60, TimeUnit.SECONDS) == true
        deleteConsent = null
        return approved
    }

    private fun canonicalUri(uri: Uri): Uri {
        val parts = uri.pathSegments
        // Android's local photo picker exposes a read-only facade. Its numeric
        // local-media ID is the MediaStore row; cloud-provider IDs are unrelated.
        if (uri.authority == MediaStore.AUTHORITY && parts.size >= 5 &&
            parts.first() in setOf("picker", "picker_get_content") &&
            parts[2] in setOf("com.android.providers.media.photopicker", "com.google.android.providers.media.module", "com.android.providers.media.module") &&
            parts[parts.size - 2] == "media") {
            parts.last().toLongOrNull()?.let { id ->
                val collection = if (activity.contentResolver.getType(uri)?.startsWith("video/") == true)
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                return ContentUris.withAppendedId(collection, id)
            }
        }
        if (uri.authority == "com.android.providers.media.documents" &&
            DocumentsContract.isDocumentUri(activity, uri)) {
            val document = DocumentsContract.getDocumentId(uri).split(':')
            val id = document.getOrNull(1)?.toLongOrNull()
            val collection = when (document.firstOrNull()) {
                "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                else -> null
            }
            if (id != null && collection != null) return ContentUris.withAppendedId(collection, id)
        }
        if (Build.VERSION.SDK_INT >= 29) {
            runCatching { MediaStore.getMediaUri(activity, uri) }.getOrNull()?.let {
                if (it.authority == MediaStore.AUTHORITY && it.pathSegments.firstOrNull() !in setOf("picker", "picker_get_content")) return it
            }
        }
        return uri
    }

    private fun requestLookupPermission(uri: Uri): Boolean {
        val permissions = if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(if (activity.contentResolver.getType(uri)?.startsWith("video/") == true)
                Manifest.permission.READ_MEDIA_VIDEO else Manifest.permission.READ_MEDIA_IMAGES)
        } else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        if (permissions.all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) return true
        val response = ArrayBlockingQueue<Boolean>(1)
        check(lookupConsent == null) { "请先处理当前媒体权限请求" }
        lookupConsent = response
        handler.post {
            runCatching { activity.requestPermissions(permissions, 708) }
                .onFailure { response.offer(false) }
        }
        return try { response.poll(60, TimeUnit.SECONDS) == true }
        finally { lookupConsent = null }
    }

    // Resolve a vendor gallery's read-only reference only through an exact
    // filesystem path supplied by that reference. Never guess from a filename.
    private fun resolveMediaPath(uri: Uri): String? {
        val reported = runCatching {
            activity.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)?.use {
                val column = it.getColumnIndex(MediaStore.MediaColumns.DATA)
                if (column >= 0 && it.moveToFirst()) it.getString(column) else null
            }
        }.getOrNull()
        if (!reported.isNullOrEmpty() && File(reported).isAbsolute) return reported
        if (uri.authority == "com.android.externalstorage.documents" && DocumentsContract.isDocumentUri(activity, uri)) {
            val document = DocumentsContract.getDocumentId(uri).split(':', limit = 2)
            if (document.size == 2 && document[0] == "primary")
                return File(Environment.getExternalStorageDirectory(), document[1]).path
            if (document.size == 2 && document[0].matches(Regex("[0-9a-fA-F]{4}-[0-9a-fA-F]{4}")))
                return "/storage/${document[0]}/${document[1]}"
        }
        if (uri.authority in setOf("com.miui.gallery.open", "com.miui.gallery.provider") &&
            uri.path?.startsWith("/raw/") == true) return uri.path!!.removePrefix("/raw")
        return null
    }

    internal fun referencePath(uri: Uri): String {
        resolveMediaPath(uri)?.let { return it }
        val location = referenceState(uri)["location"] as? String ?: ""
        return if (location.isNotEmpty()) location.trimEnd('/') + "/" + displayName(uri) else uri.toString()
    }

    private fun resolvePathUri(uri: Uri, path: String): Uri? {
        val canonical = File(path).canonicalFile
        val primary = Environment.getExternalStorageDirectory().canonicalPath
        val removable = Regex("^/storage/([0-9a-fA-F]{4}-[0-9a-fA-F]{4})/(.+)$").matchEntire(canonical.path)
        val volume: String
        val relative: String
        if (canonical.path.startsWith(primary + File.separator)) {
            volume = if (Build.VERSION.SDK_INT >= 29) MediaStore.VOLUME_EXTERNAL_PRIMARY else "external"
            relative = canonical.path.removePrefix(primary + File.separator).replace(File.separatorChar, '/')
        } else if (removable != null && Build.VERSION.SDK_INT >= 29) {
            volume = removable.groupValues[1].lowercase()
            relative = removable.groupValues[2]
        } else return null
        val resolver = activity.contentResolver
        val collection = MediaStore.Files.getContentUri(volume)
        val size = runCatching { sourceSize(uri) }.getOrDefault(-1L)
        val selection: String
        val args: Array<String>
        if (Build.VERSION.SDK_INT >= 29) {
            selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
            args = arrayOf(relative.substringBeforeLast('/', "") .let { if (it.isEmpty()) "" else "$it/" }, canonical.name)
        } else {
            selection = "${MediaStore.MediaColumns.DATA} = ?"
            args = arrayOf(canonical.path)
        }
        fun lookup(): Uri? = resolver.query(collection,
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.SIZE, MediaStore.Files.FileColumns.MEDIA_TYPE),
            selection, args, null)?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val id = cursor.getLong(0)
                val actualSize = cursor.getLong(1)
                val type = cursor.getInt(2)
                if (cursor.moveToNext() || (size >= 0 && size != actualSize)) return@use null
                val target = when(type) {
                    MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> MediaStore.Images.Media.getContentUri(volume)
                    MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> MediaStore.Video.Media.getContentUri(volume)
                    else -> collection
                }
                ContentUris.withAppendedId(target, id)
            }
        val found = try { lookup() } catch (_: SecurityException) { null }
        if (found != null) return found
        if (!requestLookupPermission(uri)) return null
        return lookup()
    }

    internal fun mediaKey(uri: Uri): String =
        "local-${digestText(canonicalUri(uri).toString().replace("/external_primary/", "/external/")).take(24)}"

    private fun rememberOrigin(uri: Uri, origin: String) {
        check(
            activity
                .getSharedPreferences("media_origins", Context.MODE_PRIVATE)
                .edit()
                .putString(mediaKey(uri), origin)
                .commit()
        ) {
            "无法保存媒体来源"
        }
    }

    internal fun deleteUri(uri: Uri) {
        val resolver = activity.contentResolver
        if (uriMissing(uri)) return
        var target = canonicalUri(uri)
        fun missing(value: Uri): Boolean = try { uriMissing(value) } catch (_: SecurityException) { false }
        if (target != uri && missing(target)) target = uri
        var deleted = false
        var rejected: Throwable? = null
        fun remove(value: Uri): Boolean =
            if (DocumentsContract.isDocumentUri(activity, value)) DocumentsContract.deleteDocument(resolver, value)
            else resolver.delete(value, null, null) > 0
        try {
            deleted = remove(target)
        } catch (e: SecurityException) {
            if (Build.VERSION.SDK_INT >= 29 && e is android.app.RecoverableSecurityException) {
                check(requestDeleteConsent(e.userAction.actionIntent)) { "用户取消删除手机原媒体" }
                deleted = remove(target)
            } else rejected = e
        } catch (e: UnsupportedOperationException) {
            rejected = e
        }
        if (!deleted && !missing(target)) {
            if (target.authority != MediaStore.AUTHORITY) {
                val path = resolveMediaPath(uri)
                val resolved = path?.let { resolvePathUri(uri, it) }
                if (resolved != null) {
                    target = resolved
                    try { deleted = remove(target) }
                    catch (e: SecurityException) {
                        if (Build.VERSION.SDK_INT >= 29 && e is android.app.RecoverableSecurityException) {
                            check(requestDeleteConsent(e.userAction.actionIntent)) { "用户取消删除手机原媒体" }
                            deleted = remove(target)
                        } else rejected = e
                    } catch (e: UnsupportedOperationException) { rejected = e }
                }
            }
            if (!deleted && !missing(target)) {
                if (Build.VERSION.SDK_INT >= 30 && target.authority == MediaStore.AUTHORITY &&
                    target.pathSegments.firstOrNull() !in setOf("picker", "picker_get_content")) {
                    check(requestDeleteConsent(MediaStore.createDeleteRequest(resolver, listOf(target)))) { "用户取消删除手机原媒体" }
                } else {
                    if (rejected is SecurityException) throw rejected as SecurityException
                    throw IllegalStateException("无法取得此媒体文件的删除权限，请在系统相册或文件所在应用中删除；应用记录已保留", rejected)
                }
            }
        }
        // Some picker facades retain a stale row after deletion; verify the
        // resolved MediaStore row, not merely the picker facade's query result.
        check(missing(target)) { "手机原媒体未被删除" }
        runCatching { resolver.releasePersistableUriPermission(uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
        activity.getSharedPreferences("media_origins", Context.MODE_PRIVATE).edit().remove(mediaKey(uri)).apply()
    }

    private fun sourceInput(source: String): InputStream =
        if (source.startsWith("content://")) {
            activity.contentResolver.openInputStream(Uri.parse(source)) ?: error("无法读取引用媒体")
        } else File(source).inputStream()

    private fun digestText(value: String): String =
        MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") {
            "%02x".format(it)
        }

    internal fun referenceState(uri: Uri): Map<String, Any?> {
        return try {
            if (uriMissing(uri)) return mapOf("available" to false)
            val size = activity.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize }
                ?: return mapOf("available" to false)
            val location = runCatching {
                val mediaUri = canonicalUri(uri)
                val column = if (Build.VERSION.SDK_INT >= 29) MediaStore.MediaColumns.RELATIVE_PATH
                    else MediaStore.MediaColumns.DATA
                activity.contentResolver.query(mediaUri, arrayOf(column), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0).orEmpty() else ""
                }.orEmpty()
            }.getOrDefault("")
            mapOf("available" to true, "bytes" to size, "location" to location)
        } catch (_: FileNotFoundException) {
            mapOf("available" to false)
        } catch (_: SecurityException) {
            mapOf("available" to false)
        }
    }

    private fun displayName(uri: Uri): String {
        var name = "media"
        activity.contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use {
                if (it.moveToFirst()) name = it.getString(0) ?: name
            }
        return name
    }

    private fun sourceSize(uri: Uri): Long {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) {
                val size = it.getLong(0)
                if (size >= 0) return size
            }
        }
        return runCatching {
                activity.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
            }
            .getOrDefault(-1L)
    }

    fun materialize(source: String): File {
        if (!source.startsWith("content://")) return File(source)
        val uri = Uri.parse(source)
        val name = displayName(uri).replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")
        val out = File.createTempFile("reference_", "_$name", activity.cacheDir)
        sourceInput(source).use { input -> out.outputStream().use { input.copyTo(it, 256 * 1024) } }
        return out
    }

    private fun cleanExifValue(value: String?): String? =
        value
            ?.replace("\u0000", "")
            ?.trim { it <= ' ' }
            ?.takeIf { it.isNotBlank() }

    internal fun readExif(e: ExifInterface): Map<String, String> =
        ExifInterface::class
            .java
            .fields
            .asSequence()
            .filter { it.name.startsWith("TAG_") && it.type == String::class.java }
            .mapNotNull { field -> runCatching { field.get(null) as String }.getOrNull() }
            .distinct()
            .filterNot { it.contains("xmp", ignoreCase = true) }
            .mapNotNull { key ->
                runCatching { cleanExifValue(e.getAttribute(key)) }
                    .getOrNull()
                    ?.let { key to it }
            }
            .toMap()

    private fun sourcePrefix(source: String, limit: Int = 4 * 1024 * 1024): ByteArray =
        sourceInput(source).use { input ->
            val output = ByteArrayOutputStream(minOf(limit, 256 * 1024))
            val buffer = ByteArray(64 * 1024)
            var remaining = limit
            while (remaining > 0) {
                val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                if (count <= 0) break
                output.write(buffer, 0, count)
                remaining -= count
            }
            output.toByteArray()
        }

    /**
     * AndroidX ExifInterface rejects some Nikon ASCII tags when the camera pads
     * the field with NUL bytes. Read the standard TIFF/EXIF entries directly as
     * a fallback so photo details remain available without touching the source.
     */
    internal fun parseExifFallback(bytes: ByteArray): Map<String, String> {
        if (bytes.size < 8) return emptyMap()
        fun be16(offset: Int): Int? {
            if (offset < 0 || offset + 1 >= bytes.size) return null
            return ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)
        }
        fun tiffStart(): Int? {
            fun tiffHeaderAt(offset: Int): Boolean {
                if (offset < 0 || offset + 3 >= bytes.size) return false
                val little = bytes[offset] == 0x49.toByte() && bytes[offset + 1] == 0x49.toByte() &&
                    bytes[offset + 2] == 0x2a.toByte() && bytes[offset + 3] == 0x00.toByte()
                val big = bytes[offset] == 0x4d.toByte() && bytes[offset + 1] == 0x4d.toByte() &&
                    bytes[offset + 2] == 0x00.toByte() && bytes[offset + 3] == 0x2a.toByte()
                return little || big
            }
            if (tiffHeaderAt(0)) return 0
            if (bytes[0] != 0xff.toByte() || bytes[1] != 0xd8.toByte()) return null
            var offset = 2
            while (offset + 4 <= bytes.size) {
                if (bytes[offset] != 0xff.toByte()) { offset++; continue }
                val marker = bytes[offset + 1].toInt() and 0xff
                if (marker == 0xda || marker == 0xd9) break
                if (marker == 0xd8 || marker in 0xd0..0xd7) { offset += 2; continue }
                val length = be16(offset + 2) ?: break
                if (length < 2) break
                val payload = offset + 4
                if (marker == 0xe1 && payload + 6 <= bytes.size &&
                    bytes[payload] == 'E'.code.toByte() && bytes[payload + 1] == 'x'.code.toByte() &&
                    bytes[payload + 2] == 'i'.code.toByte() && bytes[payload + 3] == 'f'.code.toByte() &&
                    bytes[payload + 4] == 0.toByte() && bytes[payload + 5] == 0.toByte() &&
                    tiffHeaderAt(payload + 6)) return payload + 6
                val next = offset.toLong() + 2L + length
                if (next <= offset || next > bytes.size) break
                offset = next.toInt()
            }
            return null
        }

        val base = tiffStart() ?: return emptyMap()
        val little = bytes[base] == 0x49.toByte()
        fun u16(offset: Int): Int? {
            if (offset < 0 || offset + 1 >= bytes.size) return null
            val a = bytes[offset].toInt() and 0xff
            val b = bytes[offset + 1].toInt() and 0xff
            return if (little) a or (b shl 8) else (a shl 8) or b
        }
        fun u32(offset: Int): Long? {
            if (offset < 0 || offset + 3 >= bytes.size) return null
            val values = LongArray(4) { bytes[offset + it].toLong() and 0xff }
            return if (little) values[0] or (values[1] shl 8) or (values[2] shl 16) or (values[3] shl 24)
            else (values[0] shl 24) or (values[1] shl 16) or (values[2] shl 8) or values[3]
        }
        fun s32(offset: Int): Long? = u32(offset)?.let { if (it and 0x80000000L != 0L) it - 0x100000000L else it }
        if (u16(base + 2) != 42) return emptyMap()

        val typeSize = mapOf(1 to 1, 2 to 1, 3 to 2, 4 to 4, 5 to 8, 7 to 1, 9 to 4, 10 to 8)
        fun valueOffset(entry: Int, type: Int, count: Long): Int? {
            val size = typeSize[type] ?: return null
            val total = count * size
            val offset = if (total <= 4) entry + 8L else base.toLong() + (u32(entry + 8) ?: return null)
            if (offset < 0 || offset >= bytes.size) return null
            return offset.toInt()
        }
        fun value(entry: Int, type: Int, count: Long): String? {
            val offset = valueOffset(entry, type, count) ?: return null
            return when (type) {
                2 -> {
                    val length = minOf(count.toInt().coerceAtLeast(0), bytes.size - offset)
                    cleanExifValue(String(bytes, offset, length, Charsets.US_ASCII))
                }
                3 -> u16(offset)?.toString()
                4 -> u32(offset)?.toString()
                5 -> {
                    val numerator = u32(offset) ?: return null
                    val denominator = u32(offset + 4) ?: return null
                    if (denominator == 0L) null else "$numerator/$denominator"
                }
                9 -> s32(offset)?.toString()
                10 -> {
                    val numerator = s32(offset) ?: return null
                    val denominator = s32(offset + 4) ?: return null
                    if (denominator == 0L) null else "$numerator/$denominator"
                }
                else -> null
            }
        }

        val names = mapOf(
            0x0100 to "ImageWidth",
            0x0101 to "ImageLength",
            0x010f to "Make",
            0x0110 to "Model",
            0x0132 to "DateTime",
            0x829a to "ExposureTime",
            0x829d to "FNumber",
            0x8827 to "PhotographicSensitivity",
            0x9003 to "DateTimeOriginal",
            0x920a to "FocalLength",
            0xa002 to "PixelXDimension",
            0xa003 to "PixelYDimension",
            0xa434 to "LensModel",
            // Some Nikon files store the lens model in MakerNote-style IFDs
            // that are reachable through the same traversal. Keeping this tag
            // here allows the existing recursive EXIF reader to preserve it
            // when present instead of dropping it during normalization.
        )
        val result = linkedMapOf<String, String>()
        val pending = java.util.ArrayDeque<Int>()
        val visited = mutableSetOf<Int>()
        val first = u32(base + 4)?.let { base.toLong() + it }?.takeIf { it in 0 until bytes.size }?.toInt()
            ?: return emptyMap()
        pending.add(first)
        while (pending.isNotEmpty() && visited.size < 12) {
            val ifd = pending.removeFirst()
            if (!visited.add(ifd)) continue
            val count = u16(ifd) ?: continue
            if (count > 2048) continue
            for (index in 0 until count) {
                val entry = ifd + 2 + index * 12
                if (entry < 0 || entry + 11 >= bytes.size) break
                val tag = u16(entry) ?: continue
                val type = u16(entry + 2) ?: continue
                val itemCount = u32(entry + 4) ?: continue
                if (tag == 0x8769 || tag == 0x8825 || tag == 0xa005) {
                    val child = u32(entry + 8)?.let { base.toLong() + it }
                    if (child != null && child in 0 until bytes.size) pending.add(child.toInt())
                }
                val name = names[tag] ?: continue
                cleanExifValue(value(entry, type, itemCount))?.let { result.putIfAbsent(name, it) }
            }
            val nextOffset = ifd + 2 + count * 12
            val next = u32(nextOffset)?.let { base.toLong() + it }
            if (next != null && next != base.toLong() && next in 0 until bytes.size) pending.add(next.toInt())
        }
        result["PhotographicSensitivity"]?.let { result.putIfAbsent("ISOSpeedRatings", it) }
        return result
    }

    private fun fallbackExif(source: String): Map<String, String> =
        runCatching { parseExifFallback(sourcePrefix(source)) }.getOrDefault(emptyMap())

    private fun imageDimensions(source: String): Pair<Int, Int>? = runCatching {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        if (source.startsWith("content://")) sourceInput(source).use { BitmapFactory.decodeStream(it, null, options) }
        else BitmapFactory.decodeFile(source, options)
        if (options.outWidth > 0 && options.outHeight > 0) options.outWidth to options.outHeight else null
    }.getOrNull()

    fun exif(source: String): Map<String, String> =
        try {
            val primary = runCatching {
                if (source.startsWith("content://")) {
                    activity.contentResolver.openFileDescriptor(Uri.parse(source), "r")?.use {
                        readExif(ExifInterface(it.fileDescriptor))
                    } ?: emptyMap()
                } else readExif(ExifInterface(source))
            }.getOrDefault(emptyMap())
            val merged = LinkedHashMap(primary)
            fallbackExif(source).forEach { (key, value) ->
                if (merged[key].isNullOrBlank()) merged[key] = value
            }
            if (merged["ImageWidth"].isNullOrBlank() || merged["ImageLength"].isNullOrBlank()) {
                imageDimensions(source)?.let { (width, height) ->
                    if (merged["ImageWidth"].isNullOrBlank()) merged["ImageWidth"] = width.toString()
                    if (merged["ImageLength"].isNullOrBlank()) merged["ImageLength"] = height.toString()
                }
            }
            merged
        } catch (_: Exception) {
            emptyMap()
        }

    private fun rawThumbnail(file: File, dest: File): String? = rawThumbnail(file.path, dest)

    private fun sourceSizeOrFile(source: String): Long {
        val size = if (source.startsWith("content://")) sourceSize(Uri.parse(source)) else File(source).length()
        return if (size > 0) size else 64L * 1024 * 1024
    }

    private fun rawThumbnail(source: String, dest: File): String? {
        // Prefer the full embedded JPEG over EXIF's tiny thumbnail for RAW editing.
        val bytes =
            sourceInput(source).use { input ->
                val b = ByteArray(minOf(sourceSizeOrFile(source), 64L * 1024 * 1024).toInt())
                var n = 0
                while (n < b.size) {
                    val got = input.read(b, n, b.size - n)
                    if (got < 0) break
                    n += got
                }
                b.copyOf(n)
            }
        var best: ByteArray? = null
        val starts = java.util.ArrayDeque<Int>()
        for (i in 0 until bytes.size - 1) {
            if (bytes[i] == 0xff.toByte() && bytes[i + 1] == 0xd8.toByte()) starts.push(i)
            if (starts.isNotEmpty() && bytes[i] == 0xff.toByte() && bytes[i + 1] == 0xd9.toByte()) {
                val b = bytes.copyOfRange(starts.pop(), i + 2)
                val opt = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(b, 0, b.size, opt)
                if (opt.outWidth > 0 && b.size > (best?.size ?: 0)) best = b
            }
        }
        best?.let {
            dest.writeBytes(it)
            return dest.path
        }
        return null
    }

    private fun sampledBitmap(source: String, maxDimension: Int = 1600): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        sourceInput(source).use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxDimension * 2) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return sourceInput(source).use { BitmapFactory.decodeStream(it, null, options) }
    }

    private fun thumbnail(source: String): String? {
        val file = if (source.startsWith("content://")) null else File(source)
        val name = file?.name ?: displayName(Uri.parse(source))
        val type =
            if (source.startsWith("content://"))
                activity.contentResolver.getType(Uri.parse(source)) ?: mime(name)
            else mime(name)
        val size = if (file != null) file.length() else sourceSize(Uri.parse(source))
        val dest =
            File(
                activity.cacheDir,
                "preview_v5_${digestText(source).take(24)}_${file?.lastModified() ?: 0}_$size.jpg",
            )
        if (dest.exists()) return dest.path
        if (
            type.startsWith("video") ||
                name.substringAfterLast('.', "").lowercase() in videoExtensions
        )
            return try {
                val retriever = android.media.MediaMetadataRetriever()
                try {
                    if (source.startsWith("content://"))
                        retriever.setDataSource(activity, Uri.parse(source))
                    else retriever.setDataSource(source)
                    retriever.getFrameAtTime(0)?.let { bitmap ->
                        dest.outputStream().use {
                            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it)
                        }
                        bitmap.recycle()
                        dest.path
                    }
                } finally {
                    retriever.release()
                }
            } catch (_: Exception) {
                null
            }
        if (name.substringAfterLast('.', "").lowercase() in rawExtensions) {
            return rawThumbnail(source, dest)
        }
        if (file != null) return file.path
        return try {
            val bitmap =
                (if (Build.VERSION.SDK_INT >= 29) runCatching {
                    activity.contentResolver.loadThumbnail(Uri.parse(source), Size(1600, 1600), null)
                }.getOrNull() else null) ?: sampledBitmap(source)
            bitmap?.let {
                dest.outputStream().use { out -> it.compress(Bitmap.CompressFormat.JPEG, 90, out) }
                it.recycle()
                dest.path
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun thumbnail(file: File): String? = thumbnail(file.path)

    internal fun mediaRecord(
        uri: Uri,
        dateMs: Long = 0L,
        includeDetails: Boolean = true,
    ): Map<String, Any?> {
        val name = displayName(uri)
        val type = activity.contentResolver.getType(uri) ?: mime(name)
        val reportedBytes = sourceSize(uri)
        val bytes =
            if (reportedBytes >= 0) reportedBytes
            else
                sourceInput(uri.toString()).use { input ->
                    val buffer = ByteArray(256 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                    }
                    total
                }
        val extension = name.substringAfterLast('.', "").lowercase()
        val kind =
            if (type.startsWith("video") || extension in videoExtensions) "video"
            else if (extension in rawExtensions) "raw" else "jpg"
        val source = uri.toString()
        val detailsKey = "$source:$bytes"
        val details =
            if (!includeDetails) Pair<String?, Map<String, String>>(null, emptyMap())
            else
                synchronized(recordDetails) {
                    recordDetails[detailsKey]
                        ?: Pair(
                                thumbnail(source),
                                if (kind == "video") emptyMap<String, String>() else exif(source),
                            )
                            .also { recordDetails[detailsKey] = it }
                }
        return mapOf(
            "mediaId" to mediaKey(uri),
            "origin" to
                activity
                    .getSharedPreferences("media_origins", Context.MODE_PRIVATE)
                    .getString(mediaKey(uri), null),
            "uri" to source,
            "name" to name,
            "kind" to kind,
            "mime" to type,
            "bytes" to bytes,
            "dateMs" to if (dateMs > 0) dateMs else System.currentTimeMillis(),
            "thumbnail" to details.first,
            "location" to referenceState(uri)["location"],
            "referencePath" to referencePath(uri),
            "exif" to details.second,
        )
    }

    private fun shareUri(source: String): Uri =
        if (source.startsWith("content://")) Uri.parse(source)
        else FileProvider.getUriForFile(activity, activity.packageName + ".files", File(source))

    private fun share(sources: List<String>) {
        require(sources.isNotEmpty())
        val uris = ArrayList(sources.map(::shareUri))
        val intent =
            Intent(Intent.ACTION_SEND_MULTIPLE)
                .setType("*/*")
                .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.clipData =
            ClipData.newRawUri("镜桥", uris.first()).apply {
                uris.drop(1).forEach { addItem(ClipData.Item(it)) }
            }
        activity.startActivity(Intent.createChooser(intent, "分享媒体"))
    }

    internal fun pick(kind: String, multiple: Boolean, result: MethodChannel.Result) {
        if (pickerResult != null) {
            result.error("PICK_BUSY", "文件选择器已打开", null)
            return
        }
        pickerResult = result
        pickerKind = kind
        try {
            val intent =
                Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    )
            if (kind == "cube") intent.type = "*/*"
            else {
                intent.type = "*/*"
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            }
            activity.startActivityForResult(intent, 703)
        } catch (e: Throwable) {
            pickerResult = null
            fail(result, e)
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request == 707) {
            deleteConsent?.offer(code == Activity.RESULT_OK)
            return true
        }
        if (request != 703) return false
        val result = pickerResult ?: return true
        pickerResult = null
        val completedKind = pickerKind
        if (code != Activity.RESULT_OK || (data?.data == null && data?.clipData == null)) {
            result.success(null)
            return true
        }
        imageExecutor.execute {
            try {
                val uris = linkedSetOf<Uri>()
                data?.clipData?.let { clip ->
                    for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
                }
                data?.data?.let(uris::add)
                if (completedKind == "cube") {
                    val uri = uris.first()
                    val name = displayName(uri)
                    require(name.substringAfterLast('.', "").equals("cube", ignoreCase = true)) {
                        "LUT 文件必须使用 .cube 扩展名"
                    }
                    val bytes = sourceInput(uri.toString()).use { input ->
                        input.readBytes().also {
                            require(it.isNotEmpty() && it.size <= MAX_LUT_BYTES) {
                                "LUT 文件为空或超过 64 MB"
                            }
                        }
                    }
                    val text = Charsets.UTF_8.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)
                        .decode(ByteBuffer.wrap(bytes))
                        .toString()
                    CubeLut.parse(text)
                    val directory = File(activity.filesDir, "custom-luts").apply { mkdirs() }
                    val out =
                        File(
                            directory,
                            "${System.currentTimeMillis()}_${name.replace(Regex("[^\\p{L}\\p{N}._ -]"), "_")}",
                        )
                    out.outputStream().use { it.write(bytes) }
                    handler.post { result.success(out.path) }
                } else {
                    val flags =
                        data
                            ?.flags
                            ?.and(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                            ) ?: Intent.FLAG_GRANT_READ_URI_PERMISSION
                    val records = uris.mapNotNull { uri ->
                        runCatching {
                            activity.contentResolver.takePersistableUriPermission(uri, flags)
                        }
                        val type = activity.contentResolver.getType(uri).orEmpty()
                        val extension = displayName(uri).substringAfterLast('.', "").lowercase()
                        if (
                            completedKind == "image" &&
                                (type.startsWith("video/") || extension in videoExtensions)
                        )
                            null
                        else if (
                            !type.startsWith("image/") &&
                                !type.startsWith("video/") &&
                                extension !in imageExtensions &&
                                extension !in videoExtensions
                        )
                            null
                        else {
                            check(
                                activity.contentResolver.persistedUriPermissions.any {
                                    it.uri == uri && it.isReadPermission
                                }
                            ) {
                                "此文件提供方不支持持久引用，请从系统相册或本机文件选择媒体"
                            }
                            mediaRecord(uri, includeDetails = false)
                        }
                    }
                    handler.post { result.success(records) }
                }
            } catch (e: Throwable) {
                handler.post { fail(result, e) }
            }
        }
        return true
    }

    fun onRequestPermissionsResult(request: Int, results: IntArray): Boolean {
        if (request == 708) {
            lookupConsent?.offer(results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED })
            return true
        }
        if (request == 706) {
            mediaPermissionResult?.success(
                results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED }
            )
            mediaPermissionResult = null
            return true
        }
        if (request != 704) return false
        if (results.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            storagePermissionResult?.success(null)
        else storagePermissionResult?.error("STORAGE_PERMISSION", "保存到系统相册需要存储权限", null)
        storagePermissionResult = null
        return true
    }

    fun dispose() {
        deleteConsent?.offer(false)
        lookupConsent?.offer(false)
        pickerResult?.error("CLOSED", "页面已关闭", null)
        pickerResult = null
        imageExecutor.shutdown()
    }
}
