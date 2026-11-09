package com.edde746.plezy.maggioflix

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.edde746.plezy.PlezyActivity
import com.edde746.plezy.R
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * MaggioFlix: "È disponibile" notifications.
 *
 * Every ~15 minutes (WorkManager) and whenever the app comes to the foreground, the user's Seerr
 * requests are read with the session cookie the Flutter side hands over. A request whose title
 * became available (or, for a series, whose first requested episodes arrived) since the last look
 * posts a notification, and is queued for the in-app notice the TV shows on its next start.
 *
 * The first look after sign-in only records the current state, so existing requests never notify.
 */
object MaggioflixAvailability {
  const val CHANNEL = "com.maggioflix/availability"
  private const val TAG = "MaggioflixAvailability"
  private const val PREFS = "maggioflix_availability"
  private const val KEY_BASE = "base_url"
  private const val KEY_COOKIE = "cookie"
  private const val KEY_USER = "user_id"
  private const val KEY_STATE = "state"
  private const val KEY_BASELINE = "baseline_done"
  private const val KEY_PENDING = "pending"
  private const val WORK_NAME = "maggioflix_availability"
  private const val NOTIFICATION_CHANNEL = "maggioflix_available"
  private const val NOTIFICATION_TAG = "maggioflix_available"

  // Seerr MediaStatus values.
  private const val STATUS_PARTIAL = 4
  private const val STATUS_AVAILABLE = 5

  private val executor = Executors.newSingleThreadExecutor()
  private val mainHandler = Handler(Looper.getMainLooper())
  private val lock = Any()

  fun attach(context: Context, messenger: BinaryMessenger) {
    val appContext = context.applicationContext
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "configure" -> {
          configure(appContext, call.arguments as? Map<*, *>)
          result.success(true)
        }
        "check" -> executor.execute {
          val found = try {
            check(appContext)
          } catch (e: Exception) {
            Log.w(TAG, "check failed", e)
            0
          }
          mainHandler.post { result.success(found) }
        }
        "takePending" -> result.success(takePending(appContext))
        else -> result.notImplemented()
      }
    }
  }

  private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun configure(context: Context, args: Map<*, *>?) {
    val baseUrl = (args?.get("baseUrl") as? String)?.trimEnd('/')
    val cookie = args?.get("cookie") as? String
    val userId = (args?.get("userId") as? Number)?.toInt()
    val workManager = WorkManager.getInstance(context)
    if (baseUrl.isNullOrEmpty() || cookie.isNullOrEmpty() || userId == null) {
      prefs(context).edit().remove(KEY_BASE).remove(KEY_COOKIE).apply()
      workManager.cancelUniqueWork(WORK_NAME)
      return
    }
    synchronized(lock) {
      val p = prefs(context)
      val sameAccount = p.getString(KEY_BASE, null) == baseUrl && p.getInt(KEY_USER, -1) == userId
      val edit = p.edit().putString(KEY_BASE, baseUrl).putString(KEY_COOKIE, cookie).putInt(KEY_USER, userId)
      if (!sameAccount) edit.remove(KEY_STATE).remove(KEY_PENDING).putBoolean(KEY_BASELINE, false)
      edit.apply()
    }
    ensureNotificationChannel(context)
    val request = PeriodicWorkRequestBuilder<MaggioflixAvailabilityWorker>(15, TimeUnit.MINUTES)
      .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
      .build()
    workManager.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
  }

  private fun takePending(context: Context): String = synchronized(lock) {
    val p = prefs(context)
    val pending = p.getString(KEY_PENDING, null) ?: "[]"
    p.edit().remove(KEY_PENDING).apply()
    pending
  }

  private data class Found(
    val requestId: Int,
    val isMovie: Boolean,
    val tmdbId: Int,
    val partial: Boolean,
    val seasons: List<Int>,
  )

  /** Reads the requests and notifies what changed. Returns how many notices it raised. */
  fun check(context: Context): Int = synchronized(lock) {
    val p = prefs(context)
    val baseUrl = p.getString(KEY_BASE, null) ?: return 0
    val cookie = p.getString(KEY_COOKIE, null) ?: return 0
    val userId = p.getInt(KEY_USER, -1)
    if (userId < 0) return 0

    val body = httpGet(
      "$baseUrl/api/v1/request?take=50&skip=0&filter=all&sort=modified&requestedBy=$userId",
      cookie,
    ) ?: return 0
    val results = JSONObject(body).optJSONArray("results") ?: return 0

    val state = try {
      JSONObject(p.getString(KEY_STATE, null) ?: "{}")
    } catch (e: Exception) {
      JSONObject()
    }
    val baselineDone = p.getBoolean(KEY_BASELINE, false)
    val found = mutableListOf<Found>()

    for (i in 0 until results.length()) {
      val request = results.optJSONObject(i) ?: continue
      val id = request.optInt("id", -1)
      val media = request.optJSONObject("media") ?: continue
      if (id < 0) continue
      val isMovie = request.optString("type") != "tv"
      val is4k = request.optBoolean("is4k", false)
      val tmdbId = media.optInt("tmdbId", -1)
      val requestedSeasons = mutableListOf<Int>()
      request.optJSONArray("seasons")?.let { seasons ->
        for (s in 0 until seasons.length()) {
          val number = seasons.optJSONObject(s)?.optInt("seasonNumber", -1) ?: -1
          if (number >= 0) requestedSeasons.add(number)
        }
      }
      val status = derivedStatus(media, isMovie, is4k, requestedSeasons)
      val key = id.toString()
      val previous = if (state.has(key)) state.optInt(key, 0) else 0
      state.put(key, status)
      if (!baselineDone || tmdbId < 0) continue
      if (status == STATUS_AVAILABLE && previous != STATUS_AVAILABLE) {
        found += Found(id, isMovie, tmdbId, partial = false, seasons = requestedSeasons)
      } else if (!isMovie && status == STATUS_PARTIAL && previous < STATUS_PARTIAL) {
        found += Found(id, isMovie, tmdbId, partial = true, seasons = requestedSeasons)
      }
    }

    p.edit().putString(KEY_STATE, state.toString()).putBoolean(KEY_BASELINE, true).apply()
    if (found.isEmpty()) return 0

    val pending = try {
      JSONArray(p.getString(KEY_PENDING, null) ?: "[]")
    } catch (e: Exception) {
      JSONArray()
    }
    val italian = Locale.getDefault().language == "it"
    for (item in found) {
      val details = httpGet(
        "$baseUrl/api/v1/${if (item.isMovie) "movie" else "tv"}/${item.tmdbId}?language=" +
          URLEncoder.encode(Locale.getDefault().language, "UTF-8"),
        cookie,
      )?.let { runCatching { JSONObject(it) }.getOrNull() }
      val title = details?.optString(if (item.isMovie) "title" else "name")?.takeIf { it.isNotBlank() }
        ?: if (italian) "Un titolo che hai richiesto" else "A title you requested"
      val posterPath = details?.optString("posterPath")?.takeIf { it.startsWith("/") }
      val posterUrl = posterPath?.let { "https://image.tmdb.org/t/p/w342$it" }
      val (heading, text) = texts(item, title, italian)
      notify(context, item, heading, text, posterUrl, italian)
      pending.put(
        JSONObject()
          .put("requestId", item.requestId)
          .put("tmdbId", item.tmdbId)
          .put("kind", if (item.isMovie) "movie" else "show")
          .put("title", title)
          .put("heading", heading)
          .put("text", text)
          .put("posterUrl", posterUrl ?: JSONObject.NULL)
      )
    }
    // Keep the in-app queue short: the TV notice lists the latest few.
    val trimmed = JSONArray()
    val start = maxOf(0, pending.length() - 10)
    for (i in start until pending.length()) trimmed.put(pending.get(i))
    p.edit().putString(KEY_PENDING, trimmed.toString()).apply()
    return found.size
  }

  /**
   * Movies follow the media status (4K requests the 4K one). Series follow the seasons that were
   * requested: available when all of them are, partial as soon as one has episodes on the server.
   */
  private fun derivedStatus(media: JSONObject, isMovie: Boolean, is4k: Boolean, requestedSeasons: List<Int>): Int {
    val field = if (is4k) "status4k" else "status"
    val mediaStatus = media.optInt(field, 1)
    if (isMovie || requestedSeasons.isEmpty()) return mediaStatus
    val seasons = media.optJSONArray("seasons") ?: return mediaStatus
    val bySeason = HashMap<Int, Int>()
    for (i in 0 until seasons.length()) {
      val season = seasons.optJSONObject(i) ?: continue
      bySeason[season.optInt("seasonNumber", -1)] = season.optInt(field, 1)
    }
    val statuses = requestedSeasons.map { bySeason[it] ?: 1 }
    return when {
      statuses.all { it == STATUS_AVAILABLE } -> STATUS_AVAILABLE
      statuses.any { it == STATUS_AVAILABLE || it == STATUS_PARTIAL } -> STATUS_PARTIAL
      else -> minOf(mediaStatus, 3)
    }
  }

  private fun texts(item: Found, title: String, italian: Boolean): Pair<String, String> {
    if (item.partial) {
      return if (italian) {
        "Nuovi episodi: $title" to "I primi episodi sono già sul server."
      } else {
        "New episodes: $title" to "The first episodes are already on the server."
      }
    }
    val heading = if (italian) "È disponibile: $title" else "Now available: $title"
    val text = when {
      item.isMovie -> if (italian) "Il film che hai richiesto è pronto. Buona visione!" else "The movie you requested is ready. Enjoy!"
      item.seasons.size == 1 -> if (italian) "Stagione ${item.seasons[0]} completa." else "Season ${item.seasons[0]} is complete."
      else -> if (italian) "Le stagioni che hai richiesto sono complete." else "The seasons you requested are complete."
    }
    return heading to text
  }

  private fun ensureNotificationChannel(context: Context) {
    val italian = Locale.getDefault().language == "it"
    val channel = NotificationChannelCompat.Builder(NOTIFICATION_CHANNEL, NotificationManagerCompat.IMPORTANCE_HIGH)
      .setName(if (italian) "Richieste disponibili" else "Available requests")
      .setDescription(
        if (italian) "Ti avvisa quando un film o una serie che hai richiesto è pronta da guardare."
        else "Tells you when a movie or series you requested is ready to watch."
      )
      .build()
    NotificationManagerCompat.from(context).createNotificationChannel(channel)
  }

  private fun notify(context: Context, item: Found, heading: String, text: String, posterUrl: String?, italian: Boolean) {
    if (Build.VERSION.SDK_INT >= 33 &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
    ) {
      return
    }
    ensureNotificationChannel(context)
    val playUri = Uri.parse("maggioflix://play?type=${if (item.isMovie) "movie" else "show"}&tmdb=${item.tmdbId}")
    val requestsUri = Uri.parse("maggioflix://requests")
    val builder = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL)
      .setSmallIcon(R.drawable.ic_stat_notification)
      .setColor(0xFFE53935.toInt())
      .setContentTitle(heading)
      .setContentText(text)
      .setStyle(NotificationCompat.BigTextStyle().bigText(text))
      .setPriority(NotificationCompat.PRIORITY_HIGH)
      .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
      .setAutoCancel(true)
      .setContentIntent(openIntent(context, requestsUri, item.requestId * 3))
      .addAction(0, if (italian) "Guarda ora" else "Watch now", openIntent(context, playUri, item.requestId * 3 + 1))
      .addAction(0, if (italian) "Le mie richieste" else "My requests", openIntent(context, requestsUri, item.requestId * 3 + 2))
    val poster = posterUrl?.let { downloadBitmap(it) }
    if (poster != null) builder.setLargeIcon(poster)
    try {
      NotificationManagerCompat.from(context).notify(NOTIFICATION_TAG, item.requestId, builder.build())
    } catch (e: SecurityException) {
      Log.w(TAG, "notification refused", e)
    }
  }

  private fun openIntent(context: Context, uri: Uri, requestCode: Int): PendingIntent {
    val intent = Intent(context, PlezyActivity::class.java)
      .setAction(Intent.ACTION_VIEW)
      .setData(uri)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    return PendingIntent.getActivity(
      context,
      requestCode,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
  }

  private fun httpGet(url: String, cookie: String): String? {
    var connection: HttpURLConnection? = null
    return try {
      connection = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 15000
        readTimeout = 20000
        instanceFollowRedirects = false
        setRequestProperty("Accept", "application/json")
        setRequestProperty("Cookie", "connect.sid=$cookie")
      }
      if (connection.responseCode != 200) {
        Log.i(TAG, "GET ${connection.url.path} -> ${connection.responseCode}")
        null
      } else {
        connection.inputStream.bufferedReader().use { it.readText() }
      }
    } catch (e: Exception) {
      Log.w(TAG, "GET failed", e)
      null
    } finally {
      connection?.disconnect()
    }
  }

  private fun downloadBitmap(url: String): Bitmap? {
    var connection: HttpURLConnection? = null
    return try {
      connection = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 8000
        readTimeout = 8000
      }
      if (connection.responseCode != 200) null else connection.inputStream.use { stream -> BitmapFactory.decodeStream(stream) }
    } catch (e: Exception) {
      null
    } finally {
      connection?.disconnect()
    }
  }
}

/** Periodic background look at the requests; see [MaggioflixAvailability]. */
class MaggioflixAvailabilityWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result {
    try {
      MaggioflixAvailability.check(applicationContext)
    } catch (e: Exception) {
      Log.w("MaggioflixAvailability", "background check failed", e)
    }
    return Result.success()
  }
}
