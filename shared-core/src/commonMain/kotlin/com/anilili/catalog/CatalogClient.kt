package com.anilili.catalog

import com.anilili.data.model.Media
import com.anilili.data.model.MediaPage
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

/** Callbacks are invoked once, from any thread; UI adapters dispatch to their UI executor. */
interface CatalogHttpCompletion {
    fun complete(response: CatalogHttpResponse?, error: String?)
}
interface CatalogCancellation { fun cancel() }
interface CatalogCallbackTransport {
    fun post(request: CatalogHttpRequest, completion: CatalogHttpCompletion): CatalogCancellation
}
interface CatalogPageCompletion {
    fun complete(page: MediaPage?, failure: CatalogFailure?)
}
interface CatalogDetailsCompletion {
    fun complete(media: Media?, failure: CatalogFailure?)
}

/** Swift-friendly lifecycle boundary: cancelling a request cancels the native transport task. */
class CatalogClient(transport: CatalogCallbackTransport, endpoint: String) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val catalog = AniListCatalog(CatalogHttpTransport { request ->
        suspendCancellableCoroutine { continuation ->
            val handle = transport.post(request, object : CatalogHttpCompletion {
                override fun complete(response: CatalogHttpResponse?, error: String?) {
                    if (error != null || response == null) {
                        continuation.resumeWithException(CatalogException(CatalogFailure(
                            CatalogFailureKind.TRANSPORT, 0, "Catalog request failed",
                        )))
                    } else continuation.resume(response)
                }
            })
            continuation.invokeOnCancellation { handle.cancel() }
        }
    }, endpoint)

    fun search(query: String, page: Int, perPage: Int, hideAdult: Boolean, completion: CatalogPageCompletion): CatalogCancellation {
        val job = scope.launch {
            val result = try { catalog.search(query, page, perPage, hideAdult) }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                ensureActive()
                completion.complete(null, failure(error))
                return@launch
            }
            ensureActive()
            completion.complete(result, null)
        }
        return object : CatalogCancellation { override fun cancel() { job.cancel() } }
    }

    fun details(id: Int, completion: CatalogDetailsCompletion): CatalogCancellation {
        val job = scope.launch {
            val result = try { catalog.details(id) }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                ensureActive()
                completion.complete(null, failure(error))
                return@launch
            }
            ensureActive()
            completion.complete(result, null)
        }
        return object : CatalogCancellation { override fun cancel() { job.cancel() } }
    }

    fun close() { scope.cancel() }
    private fun failure(error: Exception): CatalogFailure =
        (error as? CatalogException)?.failure ?: CatalogFailure(CatalogFailureKind.TRANSPORT, 0, "Catalog request failed")
}
