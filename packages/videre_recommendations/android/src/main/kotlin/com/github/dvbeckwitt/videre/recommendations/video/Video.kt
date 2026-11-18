package com.github.dvbeckwitt.videre.recommendations.video

/** Metadata-only projection of Flow's Video; no URL or extraction capability. */
data class Video(
    val id: String,
    val title: String,
    val channelName: String = "",
    val channelId: String = "",
    val thumbnailUrl: String = "",
    val duration: Int = 0,
    val viewCount: Long = 0L,
    val likeCount: Long = 0L,
    val uploadDate: String = "",
    val timestamp: Long = 0L,
    val timestampIsExact: Boolean = false,
    val description: String = "",
    val tags: List<String> = emptyList(),
    val category: String? = null,
    val isMusic: Boolean = false,
    val isLive: Boolean = false,
    val isShort: Boolean = false,
    val isUpcoming: Boolean = false,
    val membersOnlyText: String? = null,
)
