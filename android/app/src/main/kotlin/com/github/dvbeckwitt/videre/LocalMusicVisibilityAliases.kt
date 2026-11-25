package com.github.dvbeckwitt.videre

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONException
import java.io.File
import java.io.IOException
import java.math.BigInteger
import java.security.MessageDigest

internal data class LocalMusicVisibilityAlias(
    val key: String,
    val providerProof: String,
    val fileProof: String,
)

/** Only inspected rename targets and reused former keys need a descriptor check. */
internal class LocalMusicVisibilityAliases(private val entries: List<LocalMusicVisibilityAlias>) {
    private val byKey = entries.associateBy { it.key }
    private val byProviderProof = entries.groupBy { it.providerProof }

    fun resolve(row: LocalMusicRow, readFileProof: () -> String?): LocalMusicRow {
        val proof = row.visibilityProof ?: return row
        val candidates = byProviderProof[proof]
        if (candidates == null && proof !in byKey) return row
        val file = readFileProof()
            ?: return row.copy(visibilityProof = null, visibilityAlias = null)
        val existing = candidates?.singleOrNull { it.fileProof == file }?.key
        // The provider may reuse a URI and revision for a different file. Never
        // give that file an identity reserved for an earlier rename.
        val key = existing ?: localMusicVisibilityFingerprint("rename-proof-reuse", proof, file)
        return row.copy(visibilityAlias = key.takeUnless { it == proof })
    }

    fun replacing(entry: LocalMusicVisibilityAlias): List<LocalMusicVisibilityAlias> =
        entries.filterNot { it.key == entry.key } + entry
}

/** Kept outside the selection cache. Contains no paths, titles, grants or session IDs. */
internal class LocalMusicVisibilityAliasArchive(file: File) {
    private val storage = AtomicFile(file)

    fun read(): LocalMusicVisibilityAliases {
        val entries = try {
            val array = JSONArray(storage.readFully().toString(Charsets.UTF_8))
            List(array.length()) { position ->
                val row = array.getJSONArray(position)
                LocalMusicVisibilityAlias(row.getString(0), row.getString(1), row.getString(2))
            }
        } catch (_: IOException) {
            emptyList()
        } catch (_: JSONException) {
            emptyList()
        }
        return LocalMusicVisibilityAliases(entries)
    }

    fun retain(entry: LocalMusicVisibilityAlias) {
        val rows = read().replacing(entry)
        val bytes = JSONArray(rows.map { JSONArray(listOf(it.key, it.providerProof, it.fileProof)) })
            .toString().toByteArray(Charsets.UTF_8)
        val output = storage.startWrite()
        try {
            output.write(bytes)
            storage.finishWrite(output)
        } catch (failure: IOException) {
            storage.failWrite(output)
            throw failure
        }
    }
}

internal fun localMusicVisibilityFingerprint(vararg parts: String): String {
    val input = parts.joinToString("") { "${it.length}:$it" }
    return BigInteger(1, MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8)))
        .toString(16).padStart(64, '0')
}
