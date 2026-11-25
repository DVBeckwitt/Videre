package com.github.dvbeckwitt.videre.proxy

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SharedMusicDownloadDeviceTest {
    @Test fun movingTheExportPreservesItsContentsAndReleasesTheDownloadsEntry() {
        assumeTrue(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        check(context.packageName != "com.github.dvbeckwitt.videre")
        val resolver = context.contentResolver
        val bytes = instrumentation.context.assets.open("socks_audio.m4a").use { it.readBytes() }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "videre-test-${UUID.randomUUID()}.m4a")
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/mp4")
            put(MediaStore.MediaColumns.RELATIVE_PATH, SharedMusicDownload.DIRECTORY)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = checkNotNull(resolver.insert(Uri.parse(SharedMusicDownload.COLLECTION), values))
        var removed = false
        var failure: Throwable? = null
        try {
            checkNotNull(resolver.openOutputStream(uri)).close()
            assertEquals(0L, SharedMusicDownload.documentSize(context, uri))
            checkNotNull(resolver.openOutputStream(uri)).use { it.write(bytes) }
            assertEquals(bytes.size.toLong(), SharedMusicDownload.documentSize(context, uri))
            assertThrows(LocalDownloadUnavailable::class.java) {
                DownloadDocumentIntegrity.probe(context, uri.toString(), SharedMusicDownload.COLLECTION, "default", "fixture")
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            assertEquals(1, resolver.update(uri, values, null, null))
            assertTrue(SharedMusicDownload.exportExists(context, uri))
            assertEquals(bytes.size.toLong(), SharedMusicDownload.documentSize(context, uri))
            val identity = DownloadDocumentIntegrity.probe(
                context, uri.toString(), SharedMusicDownload.COLLECTION, "default", "fixture")
            assertEquals(bytes.size.toLong(), identity.byteLength)

            values.clear()
            values.put(MediaStore.MediaColumns.RELATIVE_PATH, "Music/")
            assertEquals(1, resolver.update(uri, values, null, null))
            assertFalse(SharedMusicDownload.exportExists(context, uri))
            assertNull(SharedMusicDownload.documentSize(context, uri))
            assertThrows(SecurityException::class.java) { SharedMusicDownload.pending(context, uri) }
            assertThrows(LocalDownloadUnavailable::class.java) {
                DownloadDocumentIntegrity.probe(context, uri.toString(), SharedMusicDownload.COLLECTION, "default", "fixture")
            }
            SharedMusicDownload.deleteAtDestination(context, uri)
            assertArrayEquals(bytes, checkNotNull(resolver.openInputStream(uri)).use { it.readBytes() })

            values.put(MediaStore.MediaColumns.RELATIVE_PATH, SharedMusicDownload.DIRECTORY)
            assertEquals(1, resolver.update(uri, values, null, null))
            SharedMusicDownload.deleteAtDestination(context, uri)
            assertFalse(SharedMusicDownload.exportExists(context, uri))
            assertEquals(0L, SharedMusicDownload.documentSize(context, uri))
            removed = true
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            if (!removed) {
                try {
                    resolver.delete(uri, null, null)
                } catch (cleanup: Exception) {
                    if (failure == null) throw cleanup
                    failure.addSuppressed(cleanup)
                }
            }
        }
    }
}
