package com.github.dvbeckwitt.videre

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalMusicMovesTest {
    @Test fun nativePlaybackIdsUseTheSameUriDigestAndIdentityOverridesAsDart() {
        val digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        val track = row("abc")
        assertEquals("device:$digest", track.playbackId)
        assertEquals(track.playbackId, row("renamed").inheritsIdentity(track).playbackId)
        assertEquals("device:${"a".repeat(64)}", track.copy(identityKey = "a".repeat(64)).playbackId)
    }

    @Test fun duplicateNamesStaySeparateAndNoCandidateIsLinkedAutomatically() {
        val original = row("original")
        val first = row("first")
        val second = row("second")
        val unrelated = row("unrelated").copy(metadata = original.metadata?.copy(title = "Other recording"))
        val current = listOf(first, second, unrelated)
        val moves = LocalMusicMoves().observe(listOf(original), current)
        val review = moves.channelValue(current)
        assertEquals(emptyMap<String, String>(), review["aliases"])
        assertEquals(mapOf(original.visibilityKey to original.playbackId), review["missingPlaylistIds"])
        val missing = (review["missing"] as List<*>).single() as Map<*, *>
        assertEquals(original.playbackId, missing["id"])
        assertEquals(listOf(first, second).map { mapOf("id" to it.playbackId, "reason" to "revision") },
            missing["candidates"])

        val confirmed = moves.confirm(original.playbackId, second)!!
        val linked = confirmed.channelValue(current)
        assertEquals(mapOf(original.playbackId to second.playbackId), linked["aliases"])
        assertEquals(mapOf(original.visibilityKey to second.playbackId), linked["playlistAliases"])
        assertNull(confirmed.confirm(original.playbackId, first))
        val otherMissing = row("other-missing")
        val next = confirmed.observe(current + otherMissing, current)
        assertNull(next.confirm(otherMissing.playbackId, second))
        assertTrue(next.missing.containsKey(otherMissing.playbackId))
    }

    @Test fun changedRevisionRequiresCorroboratingTagsAndPositiveSize() {
        val original = row("old")
        val copied = row("new").copy(fileName = "renamed.flac", modifiedMs = 2L)
        val moves = LocalMusicMoves().observe(listOf(original), listOf(copied))
        assertEquals("tags", moves.candidateReason(original, copied))
        assertNull(moves.candidateReason(original, copied.copy(metadata = original.metadata?.copy(artist = null))))
        assertNull(moves.candidateReason(original, copied.copy(sizeBytes = null)))
        assertNull(moves.candidateReason(original, copied.copy(visibilityProof = null)))
        val unknown = row("unreadable").copy(metadata = null, sizeBytes = null)
        val review = moves.observe(listOf(unknown), listOf(copied)).channelValue(listOf(copied))
        val missing = (review["missing"] as List<*>).map { it as Map<*, *> }
        assertEquals(emptyList<Any?>(), missing.first { it["id"] == unknown.playbackId }["candidates"])
    }

    @Test fun aSecondMoveRestoresEveryEarlierIdentityAndReservesTheOriginalPath() {
        val a = row("original")
        val b = row("next")
        val c = row("final")
        val first = LocalMusicMoves().observe(listOf(a), listOf(b)).confirm(a.playbackId, b)!!
        val oldPathReplacement = first.protectIdentity(a.copy(visibilityProof = "replacement"), null) { "replacement" }
        assertFalse(oldPathReplacement.playbackId == a.playbackId)
        val unavailable = first.observe(listOf(b), listOf(c, oldPathReplacement))
        assertEquals(emptyMap<String, String>(), unavailable.channelValue(listOf(c))["aliases"])
        assertEquals(mapOf(a.playbackId to b.playbackId), unavailable.channelValue(listOf(c))["missingAliases"])
        val repaired = unavailable.confirm(b.playbackId, c)!!
        val latest = repaired.channelValue(listOf(c))
        assertEquals(mapOf(a.playbackId to c.playbackId, b.playbackId to c.playbackId), latest["aliases"])
        assertEquals(emptyMap<String, String>(), latest["missingAliases"])
        assertEquals(mapOf(a.visibilityKey to c.playbackId, b.visibilityKey to c.playbackId), latest["playlistAliases"])
    }

    @Test fun aClaimedTargetMustStillHaveItsApprovedProofOrAVerifiedRename() {
        val original = row("old")
        val target = row("new")
        val repaired = LocalMusicMoves().observe(listOf(original), listOf(target)).confirm(original.playbackId, target)!!
        val temporarilyUnknown = target.copy(visibilityProof = null)
        assertEquals(target.playbackId, repaired.protectIdentity(temporarilyUnknown, target) { error("New ID") }.playbackId)
        val unverified = repaired.channelValue(listOf(temporarilyUnknown))
        assertEquals(emptyMap<String, String>(), unverified["aliases"])
        val missing = (unverified["missing"] as List<*>).single() as Map<*, *>
        assertEquals(original.playbackId, missing["id"])
        assertEquals(emptyList<Any>(), missing["candidates"])
        val replacement = target.copy(visibilityProof = "replacement")
        val identified = repaired.protectIdentity(replacement, temporarilyUnknown) { "replacement" }
        assertFalse(identified.playbackId == target.playbackId)
        val unavailable = repaired.observe(listOf(temporarilyUnknown), listOf(identified))
        assertEquals(mapOf(original.playbackId to target.playbackId), unavailable.channelValue(listOf(identified))["missingAliases"])
        val renamed = row("in-app rename").inheritsIdentity(target)
        val verified = repaired.verifiedRename(target, renamed)
        assertEquals(mapOf(original.playbackId to renamed.playbackId), verified.channelValue(listOf(renamed))["aliases"])
    }

    @Test fun onlyVerifiedReattachmentMayRecoverAnUnclaimedMissingId() {
        val previous = row("id").copy(identityKey = "salt")
        val absent = LocalMusicMoves().observe(listOf(previous), emptyList())
        val returned = absent.protectIdentity(row("id"), null) { error("New ID") }
        assertEquals(previous.playbackId, returned.playbackId)
        assertTrue(absent.observe(emptyList(), listOf(returned)).missing.isEmpty())
        val reused = absent.protectIdentity(row("id").copy(visibilityProof = "replacement"), null) { error("New ID") }
        assertFalse(reused.playbackId == previous.playbackId)
        assertTrue(absent.observe(emptyList(), listOf(reused)).missing.containsKey(previous.playbackId))
    }

    private fun row(uri: String) = LocalMusicRow(
        uri = uri,
        fileName = "Same Name.flac",
        addedMs = 1L,
        modifiedMs = 1L,
        sizeBytes = 1500L,
        firstSeen = false,
        canRename = true,
        parentDocumentId = null,
        parentKey = null,
        metadata = LocalMusicMetadata("Same title", "Artist", "Album", 3_000L),
        visibilityProof = "proof:$uri",
    )
}
