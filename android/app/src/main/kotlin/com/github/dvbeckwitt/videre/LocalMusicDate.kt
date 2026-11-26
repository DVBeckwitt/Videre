package com.github.dvbeckwitt.videre

private val musicDateTag = Regex(
    "([0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2})(?:T[0-9]{2}(?::[0-9]{2}){0,2}" +
        "(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?)?)?)?",
)

internal fun localReleaseDate(tag: String?): String? {
    val match = tag?.trim()?.let(musicDateTag::matchEntire) ?: return null
    val (_, yearText, monthText, dayText) = match.groupValues
    val year = yearText.toInt()
    if (year == 0) return null
    if (monthText.isEmpty()) return yearText
    val month = monthText.toInt()
    if (month !in 1..12) return null
    if (dayText.isEmpty()) return "$yearText-$monthText"
    val lastDay = when (month) {
        2 -> if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) 29 else 28
        4, 6, 9, 11 -> 30
        else -> 31
    }
    return "$yearText-$monthText-$dayText".takeIf { dayText.toInt() in 1..lastDay }
}

internal fun localLegacyId3Date(yearTag: String?, dayMonth: String?): String? {
    val year = localReleaseDate(yearTag) ?: return null
    if (year.length != 4 || dayMonth?.length != 4) return year
    return localReleaseDate("$year-${dayMonth.takeLast(2)}-${dayMonth.take(2)}") ?: year
}
