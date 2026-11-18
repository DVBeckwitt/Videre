package com.github.dvbeckwitt.videre.proxy

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

/** An isolated real SAF provider for grant/integrity tests, packaged only in the test APK. */
class RenditionFixtureDocumentsProvider : DocumentsProvider() {
    override fun onCreate(): Boolean {
        check(requireNotNull(context).packageName != "com.github.dvbeckwitt.videre")
        return true
    }

    private fun directory(): File = File(requireNotNull(context).filesDir, "rendition-provider").also { it.mkdirs() }

    private fun file(id: String): File {
        if (id == "root") return directory()
        if (!Regex("[A-Za-z0-9_-]{1,128}\\.webm").matches(id)) throw FileNotFoundException()
        return File(directory(), id)
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val columns = projection ?: arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE, Root.COLUMN_FLAGS)
        return MatrixCursor(columns).apply {
            addRow(columns.map { when (it) {
                Root.COLUMN_ROOT_ID -> "fixture"
                Root.COLUMN_DOCUMENT_ID -> "root"
                Root.COLUMN_TITLE -> "Download test fixture"
                Root.COLUMN_FLAGS -> Root.FLAG_LOCAL_ONLY
                else -> null
            } })
        }
    }

    private fun row(cursor: MatrixCursor, id: String) {
        val file = file(id)
        if (!file.exists()) throw FileNotFoundException()
        cursor.addRow(cursor.columnNames.map { when (it) {
            Document.COLUMN_DOCUMENT_ID -> id
            Document.COLUMN_DISPLAY_NAME -> file.name
            Document.COLUMN_MIME_TYPE -> if (id == "root") Document.MIME_TYPE_DIR else "audio/webm"
            Document.COLUMN_SIZE -> file.length()
            Document.COLUMN_LAST_MODIFIED -> file.lastModified()
            Document.COLUMN_FLAGS -> 0
            else -> null
        } })
    }

    private fun columns(projection: Array<out String>?): Array<out String> = projection ?: arrayOf(
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
        Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS)

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(columns(projection)).also { row(it, documentId) }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        if (parentDocumentId != "root") throw FileNotFoundException()
        return MatrixCursor(columns(projection)).apply {
            directory().listFiles()?.filter { it.isFile }?.forEach { row(this, it.name) }
        }
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean =
        parentDocumentId == "root" && documentId != "root" && file(documentId).isFile

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException()
        return ParcelFileDescriptor.open(file(documentId), ParcelFileDescriptor.MODE_READ_ONLY)
    }
}
