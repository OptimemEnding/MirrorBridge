package io.github.dearzl.mirrorbridge

import android.app.Activity
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.os.Environment
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MediaLibraryTest {
    private lateinit var activity: Activity
    private lateinit var library: PhoneMediaLibrary
    private lateinit var provider: FixtureProvider
    private val messenger =
        object : BinaryMessenger {
            override fun send(channel: String, message: ByteBuffer?) {}

            override fun send(
                channel: String,
                message: ByteBuffer?,
                callback: BinaryMessenger.BinaryReply?,
            ) {
                callback?.reply(null)
            }

            override fun setMessageHandler(
                channel: String,
                handler: BinaryMessenger.BinaryMessageHandler?,
            ) {}
        }

    @Before
    fun setup() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        provider = FixtureProvider()
        provider.attachInfo(
            activity,
            android.content.pm.ProviderInfo().apply {
                authority = "fixture"
                exported = true
            },
        )
        ShadowContentResolver.registerProviderInternal("fixture", provider)
        library = PhoneMediaLibrary(activity, messenger) {}
    }

    @Test
    fun viewingRawExtractionStaysInSessionAndLeavesSourceUntouched() {
        val jpeg = photo("embedded.jpg").readBytes()
        val raw = File(activity.filesDir, "camera.NEF").apply { writeBytes(byteArrayOf(0,1,2,3) + jpeg) }
        val session = File(activity.cacheDir, "image_view_sessions/view_fixture").apply { mkdirs() }
        val execute = PhoneMediaLibrary::class.java.getDeclaredMethod("execute", io.flutter.plugin.common.MethodCall::class.java).apply { isAccessible = true }
        val path = execute.invoke(library, io.flutter.plugin.common.MethodCall("fullImageSource", mapOf("source" to raw.path, "viewDirectory" to session.path))) as String
        assertEquals(File(session, "preview.jpg").canonicalPath, File(path).canonicalPath)
        assertNotNull(BitmapFactory.decodeFile(path))
        assertArrayEquals(byteArrayOf(0,1,2,3) + jpeg, raw.readBytes())
        session.deleteRecursively()
        assertTrue(raw.exists())
        assertFalse(File(path).exists())
    }

    @Test
    fun viewingLocalJpegUsesExistingFileAndRejectsUnownedOutputDirectory() {
        val local = photo("local-view.jpg")
        val session = File(activity.cacheDir, "image_view_sessions/view_local").apply { mkdirs() }
        val execute = PhoneMediaLibrary::class.java.getDeclaredMethod("execute", io.flutter.plugin.common.MethodCall::class.java).apply { isAccessible = true }
        val path = execute.invoke(library, io.flutter.plugin.common.MethodCall("fullImageSource", mapOf("source" to local.path, "viewDirectory" to session.path))) as String
        assertEquals(local.path, path)
        assertTrue(session.listFiles()!!.isEmpty())
        try {
            execute.invoke(library, io.flutter.plugin.common.MethodCall("fullImageSource", mapOf("source" to local.path, "viewDirectory" to activity.filesDir.path)))
            fail("unowned directory must be rejected")
        } catch (e: java.lang.reflect.InvocationTargetException) {
            assertTrue(e.targetException is IllegalArgumentException)
        }
    }

    private fun operation(name: String, args: Map<String, Any?> = emptyMap()): Any? {
        val execute = PhoneMediaLibrary::class.java.getDeclaredMethod("execute", io.flutter.plugin.common.MethodCall::class.java).apply { isAccessible = true }
        return execute.invoke(library, io.flutter.plugin.common.MethodCall(name, args))
    }

    @Test
    fun cacheCleanupDeletesEveryCacheEntryButKeepsCameraFileAndSettings() {
        val sourceFile = File(library.root, "saved.NEF").apply { writeBytes(byteArrayOf(1,2,3)) }
        val settings = File(activity.filesDir, "settings.json").apply { writeText("keep") }
        File(activity.cacheDir, "thumb.jpg").writeText("thumb")
        File(activity.cacheDir, "image_view_sessions/nested").apply { mkdirs() }
        File(activity.cacheDir, "image_view_sessions/nested/partial.part").writeText("partial")
        activity.externalCacheDir?.let { it.mkdirs(); File(it, "old.jpg").writeText("old") }
        operation("clearCaches")
        assertTrue(activity.cacheDir.listFiles()!!.isEmpty())
        assertTrue(activity.externalCacheDir?.listFiles()?.isEmpty() != false)
        assertArrayEquals(byteArrayOf(1,2,3), sourceFile.readBytes())
        assertEquals("keep", settings.readText())
    }

    @Test
    fun publishedCopyRequiresExactBytesAndNeverDeletesGallerySource() {
        val temporary = File(library.root, "download.NEF").apply { writeBytes(byteArrayOf(1,2,3,4)) }
        val gallery = File(activity.filesDir, "gallery.NEF").apply { writeBytes(byteArrayOf(1,2,3,5)) }
        val uri = Uri.parse("content://fixture/published")
        provider.files[uri.toString()] = gallery
        try {
            operation("releasePublishedCopy", mapOf("path" to temporary.path, "uri" to uri.toString()))
            fail("same-sized different bytes must be rejected")
        } catch (e: java.lang.reflect.InvocationTargetException) { assertTrue(e.targetException is IllegalStateException) }
        assertTrue(temporary.exists())
        gallery.writeBytes(temporary.readBytes())
        assertEquals(true, operation("releasePublishedCopy", mapOf("path" to temporary.path, "uri" to uri.toString())))
        assertFalse(temporary.exists())
        assertArrayEquals(byteArrayOf(1,2,3,4), gallery.readBytes())
    }

    @Test
    fun galleryJpegReadsWithoutCreatingDiskCopy() {
        val sourceFile = photo("gallery-view.jpg")
        val uri = "content://fixture/gallery-view"
        provider.files[uri] = sourceFile
        val before = sourceFile.readBytes()
        val session = File(activity.cacheDir, "image_view_sessions/view_gallery").apply { mkdirs() }
        assertEquals(uri, operation("fullImageSource", mapOf("source" to uri, "viewDirectory" to session.path)))
        assertArrayEquals(before, operation("readImageBytes", mapOf("source" to uri)) as ByteArray)
        assertTrue(session.listFiles()!!.isEmpty())
        assertArrayEquals(before, sourceFile.readBytes())
    }

    @Test
    fun galleryRawOnlyWritesEmbeddedJpegAndDoesNotCopyCameraFile() {
        val jpeg = photo("embedded-gallery.jpg").readBytes()
        val sourceFile = File(activity.filesDir, "gallery-view.NEF").apply { writeBytes(byteArrayOf(0,1,2,3) + jpeg) }
        val uri = "content://fixture/gallery-raw"
        provider.files[uri] = sourceFile
        val before = sourceFile.readBytes()
        val session = File(activity.cacheDir, "image_view_sessions/view_raw").apply { mkdirs() }
        val path = operation("fullImageSource", mapOf("source" to uri, "viewDirectory" to session.path)) as String
        assertEquals(listOf("preview.jpg"), session.listFiles()!!.map { it.name })
        assertNotNull(BitmapFactory.decodeFile(path))
        assertArrayEquals(before, sourceFile.readBytes())
    }

    @Test
    fun startupRemovesLegacyPartialAndAbandonedSessionButPreservesCompleteCameraFile() {
        val partial = File(library.root, "old.JPG.part").apply { writeText("unfinished") }
        val sourceFile = File(library.root, "old.JPG").apply { writeText("sourceFile") }
        val abandoned = File(activity.cacheDir, "sync_abandoned/source.JPG").apply { parentFile!!.mkdirs(); writeText("temporary") }
        library.dispose()
        library = PhoneMediaLibrary(activity, messenger) {}
        assertFalse(partial.exists())
        assertFalse(abandoned.exists())
        assertEquals("sourceFile", sourceFile.readText())
    }

    @Test
    fun verifiedPublicationReleasesCacheSessionFile() {
        val sourceFile = photo("published-gallery.jpg")
        val uri = "content://fixture/published-cache"
        provider.files[uri] = sourceFile
        val temporary = File(activity.cacheDir, "sync_fixture/source.JPG").apply { parentFile!!.mkdirs(); writeBytes(sourceFile.readBytes()) }
        assertEquals(true, operation("releasePublishedCopy", mapOf("path" to temporary.path, "uri" to uri)))
        assertFalse(temporary.exists())
        assertTrue(sourceFile.exists())
    }

    @Test
    fun shutterNeverUsesScientificNotationAndCaptionControlsChangeRendering() {
        assertEquals("1/8000s", BorderCaptionRenderer.shutter("1.25E-4"))
        assertEquals("1/125s", BorderCaptionRenderer.shutter("0.008"))
        assertEquals("1/1.3s", BorderCaptionRenderer.shutter("0.8"))
        assertEquals("1/2.5s", BorderCaptionRenderer.shutter("0.4"))
        assertEquals("1/3s", BorderCaptionRenderer.shutter("0.333333"))
        assertEquals("1/1.6s", BorderCaptionRenderer.shutter("0.6"))
        assertEquals("1/3s", BorderCaptionRenderer.shutter("0.3"))
        assertEquals("1/6s", BorderCaptionRenderer.shutter("0.166667"))
        assertEquals("1/13s", BorderCaptionRenderer.shutter("0.076923"))
        for (denominator in listOf("1.3", "1.6", "2", "2.5", "3", "4", "5", "6",
            "8", "10", "13", "15", "20", "25", "30", "40", "50", "60", "80", "100",
            "125", "160", "200", "250", "320", "400", "500", "640", "800", "1000",
            "1250", "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000")) {
            assertEquals("1/${denominator}s", BorderCaptionRenderer.shutter((1 / denominator.toDouble()).toString()))
        }
        assertEquals("1/250s", BorderCaptionRenderer.shutter("1/250"))
        assertEquals("2.5s", BorderCaptionRenderer.shutter("2.333333333"))
        val source = photo("controls.jpg")
        val meta = mapOf("Model" to "Nikon Z8", "ExposureTime" to "1.25E-4")
        val first = File(activity.cacheDir, "top-caption.jpg")
        val second = File(activity.cacheDir, "bottom-caption.jpg")
        BorderCaptionRenderer.append(source, first, "clean_white", meta, 0f, 0f, .5f, "left")
        BorderCaptionRenderer.append(source, second, "clean_white", meta, 1f, 1f, 1.5f, "right")
        assertFalse(first.readBytes().contentEquals(second.readBytes()))
        for (file in listOf(first, second)) {
            val image = BitmapFactory.decodeFile(file.path)
            assertEquals(320, image.width)
            assertEquals(200, image.height)
            image.recycle()
        }
    }

    @Test
    fun realisticCaptionPreviewHasOneFrameAndFormattedExposure() {
        val photo = BitmapFactory.decodeFile("../../assets/demo.png")!!
        val canvasImage = Bitmap.createBitmap(1200, 1020, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(canvasImage)
        canvas.drawColor(android.graphics.Color.WHITE)
        canvas.drawBitmap(photo, null, android.graphics.Rect(48, 48, 1152, 820), null)
        val base = File(activity.cacheDir, "single-frame.jpg")
        base.outputStream().use { canvasImage.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        photo.recycle(); canvasImage.recycle()
        val out = File("build/exif-layout-preview.jpg").apply { parentFile!!.mkdirs() }
        BorderCaptionRenderer.append(base, out, "clean_white", mapOf(
            "Model" to "Nikon Z 8", "ExposureTime" to "1.25E-4", "FNumber" to "2.8",
            "PhotographicSensitivity" to "100", "DateTimeOriginal" to "2026:09:12 10:30:00"), .5f, .98f, 1.2f)
        val rendered = BitmapFactory.decodeFile(out.path)
        assertEquals(1200, rendered.width); assertEquals(1020, rendered.height)
        rendered.recycle()
    }

    @After
    fun cleanup() {
        library.dispose()
    }

    class FixtureProvider : ContentProvider() {
        val files = mutableMapOf<String, File>()
        var rejectDeletion = false
        var rejectFacadeDeletion = false
        val deletedUris = mutableListOf<String>()

        override fun onCreate() = true

        override fun getType(uri: Uri): String = "image/jpeg"

        override fun query(
            uri: Uri,
            projection: Array<out String>?,
            selection: String?,
            args: Array<out String>?,
            order: String?,
        ): Cursor {
            if (uri.path?.endsWith("/file") == true) println("LOOKUP uri=$uri args=${args?.toList()} files=${files.mapValues { it.value.path }}")
            val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
            return MatrixCursor(columns).apply {
                val direct = files[uri.toString()]
                val entries = if (direct != null) listOf(uri.toString() to direct)
                    else if (uri.path?.endsWith("/file") == true && args != null)
                        files.entries.filter { (_, f) -> f.exists() && f.name == args.last() &&
                            f.parentFile!!.path.replace(File.separatorChar, '/').endsWith(args.first().trimEnd('/')) }.map { it.key to it.value }
                    else emptyList()
                for ((key, file) in entries.filter { it.second.exists() }) {
                    addRow(columns.map {
                        when(it) {
                            OpenableColumns.DISPLAY_NAME -> file.name
                            MediaStore.MediaColumns.DATA -> file.path
                            MediaStore.MediaColumns._ID -> Uri.parse(key).lastPathSegment!!.toLong()
                            MediaStore.Files.FileColumns.MEDIA_TYPE -> MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
                            else -> file.length()
                        }
                    }.toTypedArray())
                }
            }
        }

        override fun openFile(uri: Uri, mode: String) =
            ParcelFileDescriptor.open(
                files.getValue(uri.toString()),
                ParcelFileDescriptor.MODE_READ_ONLY,
            )

        override fun insert(uri: Uri, values: ContentValues?): Uri? = null

        override fun update(
            uri: Uri,
            values: ContentValues?,
            selection: String?,
            args: Array<out String>?,
        ) = 0

        override fun delete(uri: Uri, selection: String?, args: Array<out String>?): Int {
            if (rejectDeletion) throw SecurityException("fixture rejected deletion")
            if (rejectFacadeDeletion && (uri.path?.startsWith("/picker/") == true || uri.authority != "media"))
                throw UnsupportedOperationException("Delete not supported")
            deletedUris.add(uri.toString())
            return if (files.remove(uri.toString())?.delete() == true) 1 else 0
        }
    }

    private fun photo(name: String): File {
        val file = File(activity.cacheDir, name)
        val bitmap = Bitmap.createBitmap(320, 200, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.rgb(60, 100, 150))
        file.outputStream().use { bitmap.compress(if (name.endsWith(".png")) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 100, it) }
        bitmap.recycle()
        return file
    }

    @Test
    fun providerWithoutThumbnailSupportFallsBackToDecodableStream() {
        val file = photo("fallback.png")
        val uri = Uri.parse("content://fixture/fallback")
        provider.files[uri.toString()] = file
        val record = library.mediaRecord(uri)
        val thumbnail = record["thumbnail"] as String
        assertNotNull(BitmapFactory.decodeFile(thumbnail))
        assertEquals(file.length(), record["bytes"])
        assertFalse(record.containsKey("hash"))
    }

    @Test
    fun removedReferenceIsUnavailableWithoutReadingContent() {
        val file = photo("known.jpg")
        val uri = Uri.parse("content://fixture/known")
        provider.files[uri.toString()] = file
        assertEquals(true, library.referenceState(uri)["available"])
        file.delete()
        assertEquals(false, library.referenceState(uri)["available"])
    }

    @Test
    fun referenceDeleteRemovesTheActualProviderFile() {
        val file = photo("sourceFile.jpg")
        val uri = Uri.parse("content://fixture/delete")
        provider.files[uri.toString()] = file
        library.deleteUri(uri)
        assertFalse(file.exists())
        assertFalse(provider.files.containsKey(uri.toString()))
    }

    @Test
    fun deniedDeleteKeepsTheSourceBytes() {
        val file = photo("kept.jpg")
        val before = file.readBytes()
        val uri = Uri.parse("content://fixture/denied")
        provider.files[uri.toString()] = file
        provider.rejectDeletion = true
        assertThrows(SecurityException::class.java) { library.deleteUri(uri) }
        assertArrayEquals(before, file.readBytes())
    }

    private fun mediaProvider(): FixtureProvider {
        val media = FixtureProvider()
        media.attachInfo(activity, android.content.pm.ProviderInfo().apply { authority = "media"; exported = true })
        ShadowContentResolver.registerProviderInternal("media", media)
        return media
    }

    @Test
    fun localPhotoPickerDeletionTargetsResolvedMediaStoreRow() {
        val media = mediaProvider()
        val file = photo("picker.jpg")
        val picker = Uri.parse("content://media/picker/0/com.android.providers.media.photopicker/media/42")
        val mediaUri = Uri.parse("content://media/external/images/media/42")
        media.files[picker.toString()] = file
        media.files[mediaUri.toString()] = file
        media.rejectFacadeDeletion = true
        library.deleteUri(picker)
        assertFalse(file.exists())
        assertEquals(listOf(mediaUri.toString()), media.deletedUris)
    }

    @Test
    fun readOnlyGalleryDeletionResolvesExactPathAndSize() {
        val media = mediaProvider()
        val folder = File(Environment.getExternalStorageDirectory(), "DCIM/Camera").apply { mkdirs() }
        val file = photo("gallery.jpg").copyTo(File(folder, "gallery.jpg"), overwrite = true)
        val gallery = Uri.parse("content://fixture/read-only-gallery")
        val mediaUri = Uri.parse("content://media/external_primary/images/media/52")
        provider.files[gallery.toString()] = file
        provider.rejectFacadeDeletion = true
        media.files[mediaUri.toString()] = file
        println("REFERENCE path=${library.referencePath(gallery)} primary=${Environment.getExternalStorageDirectory().canonicalPath}")
        library.deleteUri(gallery)
        assertFalse(file.exists())
        assertEquals(listOf(mediaUri.toString()), media.deletedUris)
    }

    @Test
    fun cloudPickerNumericIdMustNotDeleteUnrelatedLocalRow() {
        val media = mediaProvider()
        val cloud = photo("cloud.jpg")
        val local = photo("unrelated.jpg")
        val picker = Uri.parse("content://media/picker/0/example.cloud.provider/media/42")
        media.files[picker.toString()] = cloud
        media.files["content://media/external/images/media/42"] = local
        media.rejectFacadeDeletion = true
        assertThrows(IllegalStateException::class.java) { library.deleteUri(picker) }
        assertTrue(cloud.exists())
        assertTrue(local.exists())
        assertTrue(media.deletedUris.isEmpty())
    }

    @Test
    fun rawRecordRetainsExtensionBytesAndUriWithoutAlbumCopy() {
        val file = photo("DSC_0001.NEF")
        val uri = Uri.parse("content://fixture/raw")
        provider.files[uri.toString()] = file
        val before = library.root.listFiles()!!.map { it.name }.toSet()
        val record = library.mediaRecord(uri)
        assertEquals("raw", record["kind"])
        assertEquals("DSC_0001.NEF", record["name"])
        assertEquals(file.length(), record["bytes"])
        assertEquals(uri.toString(), record["uri"])
        assertEquals(before, library.root.listFiles()!!.map { it.name }.toSet())
        assertTrue(activity.cacheDir.listFiles()!!.none { it.name.startsWith("reference_") })
    }

    @Test
    fun pickerEnablesMultipleImagesVideosAndMislabelledRawFiles() {
        library.pick(
            "media",
            true,
            object : MethodChannel.Result {
                override fun success(result: Any?) {}

                override fun error(code: String, message: String?, details: Any?) {}

                override fun notImplemented() {}
            },
        )
        val intent = shadowOf(activity).nextStartedActivityForResult.intent
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
        assertTrue(intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertEquals("*/*", intent.type)
        assertNull(intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES))
        assertTrue(intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0)
    }

    @Test
    fun xmpIsExcludedAndLongExifValuesRemainComplete() {
        val file = photo("exif.jpg")
        val longComment = "long sourceFile comment ".repeat(20)
        val exif = ExifInterface(file.path)
        exif.setAttribute(ExifInterface.TAG_USER_COMMENT, longComment)
        exif.setAttribute(ExifInterface.TAG_XMP, "<x:xmpmeta>xml data</x:xmpmeta>")
        exif.saveAttributes()
        val values = library.exif(file.path)
        assertTrue(values.keys.none { it.contains("xmp", true) })
        assertEquals(longComment.trimEnd(), values[ExifInterface.TAG_USER_COMMENT]?.trimEnd())
    }

    @Test
    fun captionWrapsEveryCharacterAcrossAllWidthsAndThemes() {
        val metadata =
            mapOf(
                "Model" to "Nikon Z 8 ".repeat(18),
                "ExposureTime" to "1/32000",
                "FNumber" to "1.2",
                "PhotographicSensitivity" to "102400",
                "DateTimeOriginal" to "2026:09:11 23:59:59",
                "LensModel" to "must not appear",
                "Xmp" to "must not appear",
            )
        for (width in listOf(96, 320, 1080, 6000)) for (dark in listOf(false, true)) {
            val measured = BorderCaptionRenderer.measure(width, metadata, dark)
            assertEquals(5, BorderCaptionRenderer.fields(metadata).size)
            assertFalse(measured.text.contains("must not appear"))
            assertEquals(
                measured.text.length,
                measured.layout.getLineEnd(measured.layout.lineCount - 1),
            )
            for (line in 0 until measured.layout.lineCount) {
                assertEquals(0, measured.layout.getEllipsisCount(line))
                assertTrue(
                    measured.layout.getLineBottom(line) <= measured.height - measured.padding
                )
                assertTrue(measured.layout.getLineWidth(line) <= measured.layout.width + 1)
            }
        }
    }

    @Test
    fun renderedCaptionKeepsCameraFileCanvasDimensions() {
        val file = photo("caption-source.jpg")
        val metadata =
            mapOf(
                "Model" to "Nikon Z 8 full camera name with a long suffix",
                "ExposureTime" to "1/8000",
                "FNumber" to "2.8",
                "ISOSpeedRatings" to "25600",
                "DateTimeOriginal" to "2026:09:11 23:59:59",
            )
        val output = File(activity.cacheDir, "caption-output.jpg")
        BorderCaptionRenderer.append(file, output, "clean_white", metadata)
        val bitmap = BitmapFactory.decodeFile(output.path)
        assertEquals(320, bitmap.width)
        assertEquals(200, bitmap.height)
        bitmap.recycle()
        // This standalone image is retained by Gradle for visual QA.
        val destination = File("build/caption-verification.jpg")
        destination.parentFile!!.mkdirs()
        output.copyTo(destination, overwrite = true)
    }
}

