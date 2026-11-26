package com.github.dvbeckwitt.videre

import java.util.Locale

internal data class LocalMusicMoveLink(
    val targetId: String, val targetProof: String, val originalPlaylistProof: String?,
)

/** A reviewed link maps historical IDs to the current file without changing either ID. */
internal data class LocalMusicMoves(
    val missing: Map<String, LocalMusicRow> = emptyMap(),
    val links: Map<String, LocalMusicMoveLink> = emptyMap(),
) {
    private val claimed = links.values.associateBy { it.targetId }
    private val missingByUri = missing.values.groupBy { it.uri }

    fun protectIdentity(
        row: LocalMusicRow, previous: LocalMusicRow?, newKey: () -> String,
    ): LocalMusicRow {
        val restored = if (previous == null) {
            missingByUri[row.uri]?.singleOrNull { it.sameInstance(row) && it.playbackId !in links }
                ?.let(row::inheritsIdentity) ?: row
        } else row
        val id = restored.playbackId
        val historical = missing[id]
        val approvedProof = claimed[id]?.targetProof
        if (id in links ||
            historical != null && !historical.sameInstance(restored) ||
            approvedProof != null && restored.visibilityProof != null && approvedProof != restored.visibilityProof) {
            return restored.copy(identityUri = null, identityKey = newKey())
        }
        return restored
    }

    fun observe(previous: Collection<LocalMusicRow>, current: Collection<LocalMusicRow>): LocalMusicMoves {
        val live = current.mapTo(mutableSetOf()) { it.playbackId }
        val absent = missing.toMutableMap()
        for (row in previous) {
            val id = row.playbackId
            if (id !in live && id !in links) {
                absent.putIfAbsent(id, row.copy(visibilityProof = row.visibilityProof ?: claimed[id]?.targetProof))
            }
        }
        absent.keys.removeAll(live)
        return copy(missing = absent)
    }

    fun candidateReason(original: LocalMusicRow, target: LocalMusicRow): String? {
        if (target.playbackId in claimed || target.playbackId in links ||
            target.visibilityProof == null || original.uri == target.uri ||
            original.sizeBytes == null || original.sizeBytes <= 0L || original.sizeBytes != target.sizeBytes) {
            return null
        }
        val old = original.metadata
        val current = target.metadata
        val title = comparableTag(old?.title, current?.title)
        val artist = comparableTag(old?.artist, current?.artist)
        val album = comparableTag(old?.album, current?.album)
        val oldDuration = old?.durationMs?.takeIf { it > 0 }
        val newDuration = current?.durationMs?.takeIf { it > 0 }
        if (title == false || artist == false || album == false ||
            oldDuration != null && newDuration != null && oldDuration != newDuration) return null
        if (original.modifiedMs != null && original.modifiedMs > 0 && original.modifiedMs == target.modifiedMs) {
            return "revision"
        }
        return if (title == true && artist == true && oldDuration != null && oldDuration == newDuration) {
            "tags"
        } else null
    }

    fun confirm(missingId: String, candidate: LocalMusicRow): LocalMusicMoves? {
        val original = missing[missingId] ?: return null
        val proof = candidate.visibilityProof ?: return null
        if (missingId == candidate.playbackId || candidateReason(original, candidate) == null) return null
        return copy(
            missing = missing - missingId,
            links = links + (missingId to LocalMusicMoveLink(candidate.playbackId, proof, original.visibilityKey)),
        )
    }

    fun verifiedRename(previous: LocalMusicRow, updated: LocalMusicRow): LocalMusicMoves {
        val link = claimed[previous.playbackId] ?: return this
        val proof = updated.visibilityProof ?: return this
        if (updated.playbackId != link.targetId || previous.visibilityProof != link.targetProof) return this
        return copy(links = links.mapValues { (_, value) ->
            if (value == link) value.copy(targetProof = proof) else value
        })
    }

    fun channelValue(current: Collection<LocalMusicRow>): Map<String, Any> {
        val byId = if (links.isEmpty()) emptyMap() else current.associateBy { it.playbackId }
        val bySize = if (missing.isEmpty()) emptyMap() else current.groupBy { it.sizeBytes }
        val resolved = resolveLinks { id -> id in byId || id in missing }
        val aliases = resolved.filterValues { id ->
            val proof = byId[id]?.visibilityProof
            proof != null && proof == claimed[id]?.targetProof
        }
        val unverified = resolved.filterKeys { it !in aliases }.filterValues { it in byId }
        return mapOf(
            "missing" to (missing.values.map { row ->
                missingValue(row.playbackId, row, bySize[row.sizeBytes].orEmpty().mapNotNull { target ->
                    candidateReason(row, target)?.let { mapOf("id" to target.playbackId, "reason" to it) }
                })
            } + unverified.map { (id, target) -> missingValue(id, byId.getValue(target), emptyList()) }),
            "aliases" to aliases,
            "missingAliases" to resolved.filterValues { it in missing },
            "playlistAliases" to buildMap {
                for ((id, target) in aliases) links[id]?.originalPlaylistProof?.let { put(it, target) }
            },
            "missingPlaylistIds" to buildMap {
                for ((id, row) in missing) row.visibilityKey?.let { put(it, id) }
                for ((id, target) in resolved) {
                    val proof = links[id]?.originalPlaylistProof ?: continue
                    if (target in missing) put(proof, target)
                    else if (id in unverified) put(proof, id)
                }
            },
        )
    }

    private fun missingValue(id: String, row: LocalMusicRow, candidates: List<Map<String, String>>) = mapOf(
        "id" to id,
        "title" to (row.metadata?.title ?: LocalMusicCatalog.fallbackTitle(row.fileName)),
        "fileName" to row.fileName,
        "artist" to row.metadata?.artist,
        "album" to row.metadata?.album,
        "durationMs" to (row.metadata?.durationMs ?: 0L),
        "folder" to row.folderLocations.lastOrNull()?.label,
        "candidates" to candidates,
    )

    private fun resolveLinks(isTerminal: (String) -> Boolean): Map<String, String> {
        val resolved = mutableMapOf<String, String>()
        val visited = mutableSetOf<String>()
        for (id in links.keys) {
            val path = mutableListOf<String>()
            var cursor = id
            while (visited.add(cursor)) {
                val link = links[cursor] ?: break
                path.add(cursor)
                cursor = link.targetId
            }
            val target = resolved[cursor] ?: cursor.takeIf(isTerminal)
            if (target != null) for (old in path) resolved[old] = target
        }
        return resolved
    }

    private fun LocalMusicRow.sameInstance(other: LocalMusicRow): Boolean =
        visibilityProof != null && visibilityProof == other.visibilityProof

    private fun comparableTag(first: String?, second: String?): Boolean? {
        val left = localCollectionTag(first)?.lowercase(Locale.ROOT) ?: return null
        val right = localCollectionTag(second)?.lowercase(Locale.ROOT) ?: return null
        return left == right
    }
}
