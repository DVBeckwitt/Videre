@file:Suppress("DEPRECATION")

package com.github.dvbeckwitt.videre

import android.content.ContentResolver
import android.content.ContentUris
import android.os.Build
import android.os.CancellationSignal
import android.provider.MediaStore
import android.provider.MediaStore.Audio.Media as Audio
import android.provider.MediaStore.Audio.Playlists
import android.provider.MediaStore.Audio.Playlists.Members

internal fun readIndexedMusicPlaylists(
    resolver: ContentResolver,
    signal: CancellationSignal,
): List<Map<String, Any>>? {
    val playlists = resolver.query(
        Playlists.EXTERNAL_CONTENT_URI, arrayOf(Playlists._ID, Playlists.NAME),
        null, null, Playlists.DEFAULT_SORT_ORDER, signal,
    )?.use { cursor ->
        val idColumn = cursor.getColumnIndexOrThrow(Playlists._ID)
        val nameColumn = cursor.getColumnIndexOrThrow(Playlists.NAME)
        buildList<Pair<Long, String>> {
            while (cursor.moveToNext()) {
                signal.throwIfCanceled()
                val id = cursor.getLong(idColumn)
                if (id <= 0) continue
                val name = localCollectionTag(cursor.getString(nameColumn)) ?: continue
                add(id to name)
            }
        }
    } ?: return null

    return playlists.mapNotNull { (id, name) ->
        signal.throwIfCanceled()
        val members = try {
            readPlaylistMembers(resolver, id, signal)
        } catch (_: SecurityException) {
            null
        } catch (_: IllegalArgumentException) {
            // A playlist can disappear while the compatibility index is being read.
            null
        } ?: return@mapNotNull null
        mapOf("id" to id, "name" to name, "memberUris" to members)
    }
}

private fun readPlaylistMembers(
    resolver: ContentResolver,
    playlistId: Long,
    signal: CancellationSignal,
): List<String>? {
    val hasVolumes = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    val columns = if (hasVolumes) arrayOf(Members.AUDIO_ID, MediaStore.MediaColumns.VOLUME_NAME)
        else arrayOf(Members.AUDIO_ID)
    return resolver.query(
        Members.getContentUri(MediaStore.VOLUME_EXTERNAL, playlistId), columns,
        null, null, Members.PLAY_ORDER, signal,
    )?.use { cursor ->
        val audioColumn = cursor.getColumnIndexOrThrow(Members.AUDIO_ID)
        val volumeColumn = if (hasVolumes) cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.VOLUME_NAME) else -1
        buildList {
            while (cursor.moveToNext()) {
                signal.throwIfCanceled()
                val audioId = cursor.getLong(audioColumn)
                if (audioId <= 0) continue
                val collection = if (hasVolumes) {
                    // The joined audio row supplies the actual member volume.
                    val volume = cursor.getString(volumeColumn)?.takeIf(String::isNotEmpty) ?: continue
                    Audio.getContentUri(volume)
                } else Audio.EXTERNAL_CONTENT_URI
                add(ContentUris.withAppendedId(collection, audioId).toString())
            }
        }
    }
}
