package com.anilili.episodes

import com.anilili.catalog.CatalogCallbackTransport
import com.anilili.catalog.CatalogCancellation
import com.anilili.catalog.CatalogException
import com.anilili.catalog.CatalogFailure
import com.anilili.catalog.CatalogFailureKind
import com.anilili.catalog.CatalogHttpCompletion
import com.anilili.catalog.CatalogHttpResponse
import com.anilili.catalog.CatalogHttpTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

interface EpisodeListCompletion { fun complete(episodes: List<Episode>?, failure: CatalogFailure?) }
interface EpisodeSourceCompletion { fun complete(source: PlaybackSource?, failure: CatalogFailure?) }

/** Swift callbacks can arrive on any thread; request cancellation cancels native transport. */
class EpisodeClient(transport: CatalogCallbackTransport, endpoint: String) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val repository = EpisodeRepository(CatalogHttpTransport { request ->
        suspendCancellableCoroutine { continuation ->
            val handle = transport.post(request, object : CatalogHttpCompletion {
                override fun complete(response: CatalogHttpResponse?, error: String?) {
                    if (error != null || response == null) continuation.resumeWithException(
                        CatalogException(CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Episode request failed")),
                    ) else continuation.resume(response)
                }
            })
            continuation.invokeOnCancellation { handle.cancel() }
        }
    }, endpoint)

    fun episodes(animeId: Int, completion: EpisodeListCompletion): CatalogCancellation {
        val job = scope.launch {
            val rows = try { repository.episodes(animeId) }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                ensureActive()
                completion.complete(null, failure(error))
                return@launch
            }
            ensureActive()
            completion.complete(rows, null)
        }
        return object : CatalogCancellation { override fun cancel() { job.cancel() } }
    }

    fun resolve(animeId: Int, episodeId: String, completion: EpisodeSourceCompletion): CatalogCancellation {
        val job = scope.launch {
            val source = try { repository.resolve(animeId, episodeId) }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                ensureActive()
                completion.complete(null, failure(error))
                return@launch
            }
            ensureActive()
            completion.complete(source, null)
        }
        return object : CatalogCancellation { override fun cancel() { job.cancel() } }
    }

    fun close() { scope.cancel() }
    private fun failure(error: Exception) = (error as? CatalogException)?.failure
        ?: CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Episode request failed")
}
