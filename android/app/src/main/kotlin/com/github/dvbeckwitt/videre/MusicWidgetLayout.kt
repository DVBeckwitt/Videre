package com.github.dvbeckwitt.videre

internal enum class MusicWidgetLayout(
    val resourceId: Int,
    val minWidth: Int,
    val minHeight: Int,
) {
    COMPACT(R.layout.music_home_widget, 168, 110),
    WIDE(R.layout.music_home_widget_wide, 264, 110),
    TALL(R.layout.music_home_widget_tall, 168, 170);

    val hasArtwork: Boolean get() = this != COMPACT
    val hasExtraActions: Boolean get() = this != COMPACT
    val hasStatusLine: Boolean get() = this == TALL

    companion object {
        fun forSize(width: Int, height: Int): MusicWidgetLayout =
            entries
                .filter { width >= it.minWidth && height >= it.minHeight }
                .minByOrNull { layout ->
                    val widthGap = (width - layout.minWidth).toDouble()
                    val heightGap = (height - layout.minHeight).toDouble()
                    widthGap * widthGap + heightGap * heightGap
                } ?: COMPACT
    }
}
