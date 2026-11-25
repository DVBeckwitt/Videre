package com.ryanheise.audioservice

import android.support.v4.media.session.MediaSessionCompat

// Keep the media browser on the app's only playback session. The pinned
// audio_service version exposes its live service within this package.
internal object AudioServiceAccess {
    fun current(): AudioService? = AudioService.instance

    fun setMusicQueue(rows: List<MusicQueueRow>): Boolean {
        val service = current() ?: return false
        service.setQueue(rows.map { row ->
            val item = service.createMediaMetadata(
                row.mediaId, row.title, row.album, row.artist,
                null, null, null, true, null, null, null, null, null
            )
            MediaSessionCompat.QueueItem(item.description, row.id)
        })
        return true
    }
}

internal data class MusicQueueRow(
    val id: Long,
    val mediaId: String,
    val title: String,
    val artist: String?,
    val album: String?,
)
