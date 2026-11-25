package com.github.dvbeckwitt.videre.proxy

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Private synthetic files only; the target must never be the installed user's application. */
@RunWith(AndroidJUnit4::class)
class DownloadedRenditionDeviceTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val profile = "rendition-${UUID.randomUUID()}"
    private val content = "test-media"
    private val remote = "https://instance.example/api/manifest/dash/id/test-media"
    private val bytes = ByteArray(64 * 1024) { (it % 241).toByte() }
    private val digest get() = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private lateinit var owner: File
    private lateinit var media: File
    private var savedPolicy: Map<String, Any>? = null
    private var fixtureDocument: File? = null
    private var fixtureTree: Uri? = null

    @Before fun createOwnedFixture() {
        check(context.packageName != "com.github.dvbeckwitt.videre")
        owner = File(context.applicationInfo.dataDir, "app_flutter/downloads/profiles/$profile")
        check(owner.mkdirs() || owner.isDirectory)
        media = File(owner, "$content.webm")
        media.writeBytes(bytes)
        ProxyDataSource.initialize(context)
        savedPolicy = ProxyDataSource.configuration()
        ProxyDataSource.configure(ProxyPolicy().toMap())
        PlaybackMediaCache.initialize(context)
    }

    @After fun removeOwnedFixture() {
        PlaybackMediaCache.invalidate()
        savedPolicy?.let(ProxyDataSource::configure)
        fixtureTree?.let { tree ->
            try { context.contentResolver.releasePersistableUriPermission(tree,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            catch (_: SecurityException) { }
        }
        fixtureDocument?.delete()
        if (::owner.isInitialized) {
            check(owner.canonicalPath.startsWith(File(context.applicationInfo.dataDir,
                "app_flutter/downloads/profiles").canonicalPath + File.separator))
            owner.deleteRecursively()
        }
    }

    private fun descriptor(uri: String = Uri.fromFile(media).toString(), hash: String = digest,
                           folder: String? = null): Map<String, Any> = mapOf(
        "uri" to uri, "remoteUri" to remote, "byteLength" to bytes.size.toLong(), "sha256" to hash,
    ) + if (folder == null) emptyMap() else mapOf("folderUri" to folder)

    private fun identity(owner: String = profile): Map<String, Any> = mapOf("version" to 1,
        "profileId" to owner, "accountId" to "test-account", "origin" to "https://instance.example",
        "contentId" to content, "sessionId" to "fixture", "resources" to listOf(
            mapOf("url" to remote, "key" to "manifest", "persistent" to false, "manifest" to true)))

    private class ForbiddenUpstream : DataSource.Factory {
        val opens = AtomicInteger()
        override fun createDataSource(): DataSource = object : DataSource {
            override fun open(dataSpec: DataSpec): Long { opens.incrementAndGet(); throw AssertionError("Unexpected network read") }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int = throw AssertionError()
            override fun getUri(): Uri? = null
            override fun addTransferListener(listener: TransferListener) { }
            override fun close() { }
        }
    }

    private fun read(factory: DataSource.Factory, uri: String = Uri.fromFile(media).toString(),
                     position: Long = 0, length: Long? = null): ByteArray {
        val source = factory.createDataSource()
        try {
            source.open(DataSpec.Builder().setUri(uri).setPosition(position).apply {
                if (length != null) setLength(length)
            }.build())
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(4096)
            while (true) {
                val count = source.read(buffer, 0, buffer.size)
                if (count == C.RESULT_END_OF_INPUT) return output.toByteArray()
                output.write(buffer, 0, count)
            }
        } finally { source.close() }
    }

    @Test fun verifiedWholeRenditionAndSeeksNeverReadOrPopulateNetworkCache() {
        val upstream = ForbiddenUpstream()
        val uri = Uri.fromFile(media).toString()
        val before = PlaybackMediaCache.status()["usedBytes"]
        val factory = PlaybackMediaCache.factory(context, upstream, uri, identity() + ("download" to descriptor()))
        assertArrayEquals(bytes, read(factory))
        assertArrayEquals(bytes.copyOfRange(3072, 8192), read(factory, position = 3072, length = 5120))
        assertEquals(0, upstream.opens.get())
        assertEquals(before, PlaybackMediaCache.status()["usedBytes"])
    }

    @Test fun rangeReopensHashOnceAndRejectChangedFileWithSameLength() {
        val uri = Uri.fromFile(media).toString()
        val rendition = DownloadedRendition(context, PlaybackCacheIdentity.parse(identity(), remote),
            DownloadedRenditionDescriptor.parse(descriptor(), uri)!!)
        val factory = DataSource.Factory { rendition.source { } }
        assertArrayEquals(bytes.copyOfRange(0, 4096), read(factory, length = 4096))
        assertArrayEquals(bytes.copyOfRange(8192, 12288), read(factory, position = 8192, length = 4096))
        assertEquals(1, rendition.verificationCount)
        media.writeBytes(bytes.reversedArray())
        assertThrows(LocalDownloadUnavailable::class.java) { read(factory) }
        assertEquals(1, rendition.verificationCount)
    }

    @Test fun storageIdentityDistinguishesByteIdenticalCopiesAndRejectsMissingOrWrongOwner() {
        val uri = Uri.fromFile(media).toString()
        val before = DownloadDocumentIntegrity.probe(context, uri, null, profile, content)
        assertEquals(before, DownloadDocumentIntegrity.probe(context, uri, null, profile, content))
        assertEquals(bytes.size.toLong(), before.byteLength)
        assertThrows(LocalDownloadUnavailable::class.java) {
            DownloadDocumentIntegrity.probe(context, uri, null, "other-profile", content)
        }
        val copyId = "another-media"
        val copy = File(owner, "$copyId.webm").also { it.writeBytes(bytes) }
        val separate = DownloadDocumentIntegrity.probe(context, Uri.fromFile(copy).toString(), null, profile, copyId)
        assertNotEquals(before.identity, separate.identity)
        check(media.delete())
        assertThrows(LocalDownloadUnavailable::class.java) {
            DownloadDocumentIntegrity.probe(context, uri, null, profile, content)
        }
        check(copy.renameTo(media))
        val replacement = DownloadDocumentIntegrity.probe(context, uri, null, profile, content)
        assertEquals(before.byteLength, replacement.byteLength)
        assertNotEquals(before.identity, replacement.identity)
    }

    @Test fun playbackAdmissionRejectsACompletedFileChangedBeforeTheMetadataProbe() {
        val uri = Uri.fromFile(media).toString()
        assertEquals(bytes.size.toLong(),
            DownloadDocumentIntegrity.probe(context, uri, null, profile, content, digest).byteLength)
        media.writeBytes(bytes.reversedArray())
        assertEquals(bytes.size.toLong(),
            DownloadDocumentIntegrity.probe(context, uri, null, profile, content).byteLength)
        assertThrows(LocalDownloadUnavailable::class.java) {
            DownloadDocumentIntegrity.probe(context, uri, null, profile, content, digest)
        }
    }

    @Test fun wrongDigestOrOwnerRejectsWithoutNetworkFallbackOrByteAliasing() {
        val uri = Uri.fromFile(media).toString()
        val upstream = ForbiddenUpstream()
        for (values in listOf(identity() + ("download" to descriptor(hash = "0".repeat(64))),
            identity("other-profile") + ("download" to descriptor()))) {
            val factory = PlaybackMediaCache.factory(context, upstream, uri, values)
            assertThrows(LocalDownloadUnavailable::class.java) { read(factory) }
        }
        assertEquals(0, upstream.opens.get())
    }

    @Test fun localSourceStillRequiresAdmittedOriginalInstance() {
        val uri = Uri.fromFile(media).toString()
        val invalid = descriptor() + ("remoteUri" to "https://www.youtube.com/watch?v=test-media")
        assertThrows(SelectedOriginBlocked::class.java) {
            PlaybackMediaCache.factory(context, ForbiddenUpstream(), uri, identity() + ("download" to invalid))
        }
    }

    @Test fun localSelectionNeedsNoRemoteResourceOrMetadata() {
        val uri = Uri.fromFile(media).toString()
        val values = identity() + mapOf("resources" to emptyList<Map<String, Any>>(),
            "download" to (descriptor() - "remoteUri"))
        val upstream = ForbiddenUpstream()
        assertArrayEquals(bytes, read(PlaybackMediaCache.factory(context, upstream, uri, values)))
        assertEquals(0, upstream.opens.get())
        assertThrows(IllegalArgumentException::class.java) {
            PlaybackMediaCache.factory(context, upstream, uri, values + ("origin" to "https://www.youtube.com"))
        }
    }

    @Test fun contextInvalidationAndDeletionRejectOpenLocalReaders() {
        val uri = Uri.fromFile(media).toString()
        fun factory() = PlaybackMediaCache.factory(context, ForbiddenUpstream(), uri,
            identity() + ("download" to descriptor()))
        val source = factory().createDataSource()
        source.open(DataSpec.Builder().setUri(uri).build())
        PlaybackMediaCache.invalidate()
        assertThrows(IOException::class.java) { source.read(ByteArray(32), 0, 32) }
        source.close()

        val deleted = factory().createDataSource()
        deleted.open(DataSpec.Builder().setUri(uri).build())
        media.delete()
        assertThrows(LocalDownloadUnavailable::class.java) { deleted.read(ByteArray(32), 0, 32) }
        deleted.close()
    }

    @Test fun documentWithoutOwnedPersistedTreeGrantRejectsLocally() {
        val folder = "content://com.android.externalstorage.documents/tree/primary%3ADownload"
        val uri = "$folder/document/primary%3ADownload%2Fmissing-videre-fixture.webm"
        val values = identity() + ("download" to descriptor(uri, folder = folder))
        val upstream = ForbiddenUpstream()
        val factory = PlaybackMediaCache.factory(context, upstream, uri, values)
        assertThrows(LocalDownloadUnavailable::class.java) { read(factory, uri) }
        assertEquals(0, upstream.opens.get())
    }

    @Test fun persistedDocumentProofUsesSameReadHandleAndRevokedGrantStopsPlayback() {
        val root = File(context.filesDir, "rendition-provider").also { it.mkdirs() }
        val document = File(root, "$profile.webm").also { it.writeBytes(bytes) }
        fixtureDocument = document
        val authority = "${context.packageName}.saved-downloads"
        val tree = DocumentsContract.buildTreeDocumentUri(authority, "root")
        fixtureTree = tree
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, document.name)
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        context.grantUriPermission(context.packageName, tree,
            flags or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        context.contentResolver.takePersistableUriPermission(tree, flags)
        val proof = DownloadDocumentIntegrity.inspect(context, uri.toString(), tree.toString())
        assertEquals(bytes.size.toLong(), proof["byteLength"])
        assertEquals(digest, proof["sha256"])
        val stamp = DownloadDocumentIntegrity.probe(context, uri.toString(), tree.toString(), profile, content)
        assertEquals(bytes.size.toLong(), stamp.byteLength)
        val alias = DownloadDocumentIntegrity.probeIndexedDocument(context, uri, android.os.CancellationSignal())
        assertEquals(stamp, alias)
        val upstream = ForbiddenUpstream()
        val factory = PlaybackMediaCache.factory(context, upstream, uri.toString(), identity() +
            ("download" to (descriptor(uri.toString(), folder = tree.toString()) - "remoteUri")))
        assertArrayEquals(bytes.copyOfRange(8192, 16384), read(factory, uri.toString(), 8192, 8192))
        val active = factory.createDataSource()
        active.open(DataSpec.Builder().setUri(uri).build())
        try {
            context.contentResolver.releasePersistableUriPermission(tree, flags)
            assertThrows(LocalDownloadUnavailable::class.java) {
                DownloadDocumentIntegrity.probe(context, uri.toString(), tree.toString(), profile, content)
            }
            assertThrows(LocalDownloadUnavailable::class.java) { active.read(ByteArray(32), 0, 32) }
            assertThrows(LocalDownloadUnavailable::class.java) { read(factory, uri.toString()) }
            assertEquals(0, upstream.opens.get())
        } finally { active.close() }
    }
}
