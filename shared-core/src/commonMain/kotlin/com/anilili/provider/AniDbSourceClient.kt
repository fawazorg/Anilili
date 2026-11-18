package com.anilili.provider

import com.anilili.catalog.*
import com.anilili.episodes.EpisodeSourceCompletion
import com.anilili.episodes.PlaybackSource
import kotlinx.coroutines.*
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.time.TimeSource

/** Resolver for a known AniDB App server endpoint. Catalog matching stays platform-specific.
 * At most three total requests, one deadline for the complete operation, and no auth retries. */
class AniDbSourceResolver(
    private val transport: CatalogHttpTransport,
    private val timeoutMs: Long = 15_000,
    private val maxRetries: Int = 2,
    private val retryDelayMs: Long = 250,
) {
    suspend fun resolve(endpoint: String, episodeId: String, nowMs: Long): PlaybackSource {
        if (!MediaSourcePolicy.validUrl(endpoint) || episodeId.isBlank() || nowMs < 0) {
            throw failure(CatalogFailureKind.MALFORMED, 0, "Invalid provider endpoint or episode")
        }
        val started = TimeSource.Monotonic.markNow()
        try {
            return withTimeout(timeoutMs.coerceIn(1, 60_000)) {
                repeat(maxRetries.coerceIn(0, 2) + 1) { attempt ->
                    ensureActive()
                    val response = try {
                        transport.post(CatalogHttpRequest(endpoint, "", "GET", mapOf("Accept" to "application/json")))
                    } catch (error: CancellationException) { throw error }
                    catch (_: Exception) {
                        if (attempt < maxRetries.coerceIn(0, 2)) {
                            delay(retryDelayMs.coerceIn(0, 1_000)); return@repeat
                        }
                        throw failure(CatalogFailureKind.TRANSPORT, 0, "Provider request failed")
                    }
                    ensureActive()
                    if (response.status in 200..299) {
                        // Time spent resolving is included when evaluating URL expiry.
                        return@withTimeout AniDbSourceParser.parse(response.body, episodeId, response.finalUrl ?: endpoint, nowMs + started.elapsedNow().inWholeMilliseconds.coerceAtMost(Long.MAX_VALUE - nowMs))
                    }
                    if ((response.status == 429 || response.status in 500..599) && attempt < maxRetries.coerceIn(0, 2)) {
                        val retryAfterHeader = response.headers.entries.firstOrNull { it.key.equals("Retry-After", true) }?.value
                        val retryAfterSeconds = retryAfterHeader?.trim()?.toLongOrNull()
                        // Never shorten a server's backoff or guess an HTTP-date delay. The caller
                        // can retry later; automatic retries stay within their short bounded budget.
                        if (retryAfterHeader != null && (retryAfterSeconds == null || retryAfterSeconds !in 0..1)) {
                            throw failure(CatalogFailureKind.HTTP, response.status, "Provider requested a later retry")
                        }
                        delay(retryAfterSeconds?.times(1_000) ?: retryDelayMs.coerceIn(0, 1_000))
                    } else throw failure(CatalogFailureKind.HTTP, response.status, "Provider HTTP ${response.status}")
                }
                error("Unreachable retry state")
            }
        } catch (error: TimeoutCancellationException) {
            currentCoroutineContext().ensureActive()
            throw failure(CatalogFailureKind.TIMEOUT, 0, "Provider resolution timed out")
        }
    }

    private fun failure(kind: CatalogFailureKind, status: Int, message: String) =
        CatalogException(CatalogFailure(kind, status, message))
}

/** Cancellation suppresses late callbacks and cancels the underlying platform task.
 * The UI owns single-flight selection and cancels the returned handle before replacement. */
class AniDbSourceClient(transport: CatalogCallbackTransport, timeoutMs: Long) {
    constructor(transport: CatalogCallbackTransport) : this(transport, 15_000)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val resolver = AniDbSourceResolver(CatalogHttpTransport { request ->
        suspendCancellableCoroutine { continuation ->
            val handle = transport.post(request, object : CatalogHttpCompletion {
                override fun complete(response: CatalogHttpResponse?, error: String?) {
                    if (response == null || error != null) continuation.resumeWithException(
                        CatalogException(CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Provider request failed")))
                    else continuation.resume(response)
                }
            })
            continuation.invokeOnCancellation { handle.cancel() }
        }
    }, timeoutMs = timeoutMs)

    fun resolve(endpoint: String, episodeId: String, nowMs: Long, completion: EpisodeSourceCompletion): CatalogCancellation {
        val job = scope.launch {
            val source = try { resolver.resolve(endpoint, episodeId, nowMs) }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                ensureActive()
                completion.complete(null, (error as? CatalogException)?.failure
                    ?: CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Provider request failed"))
                return@launch
            }
            ensureActive()
            completion.complete(source, null)
        }
        return object : CatalogCancellation { override fun cancel() { job.cancel() } }
    }
    fun close() { scope.cancel() }
}
