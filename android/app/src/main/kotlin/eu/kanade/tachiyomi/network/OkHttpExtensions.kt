@file:JvmName("OkHttpExtensionsKt")
package eu.kanade.tachiyomi.network

import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Response
import rx.Observable
import java.io.IOException
import kotlin.coroutines.resumeWithException

fun Call.asObservable(): Observable<Response> {
    return Observable.create { subscriber ->
        try {
            val response = execute()
            if (!subscriber.isUnsubscribed) {
                subscriber.onNext(response)
                subscriber.onCompleted()
            }
        } catch (e: Throwable) {
            if (!subscriber.isUnsubscribed) {
                subscriber.onError(e)
            }
        }
    }
}

fun Call.asObservableSuccess(): Observable<Response> {
    return asObservable().doOnNext { response ->
        if (!response.isSuccessful) {
            val code = response.code
            try { response.close() } catch (_: Throwable) {}
            throw HttpException(code)
        }
    }
}

suspend fun Call.await(): Response {
    return suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation {
            cancel()
        }
        enqueue(object : okhttp3.Callback {
            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) {
                    try { response.close() } catch (_: Throwable) {}
                }
            }

            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) {
                    continuation.resumeWithException(e)
                }
            }
        })
    }
}

suspend fun Call.awaitSuccess(): Response {
    val response = await()
    if (!response.isSuccessful) {
        val code = response.code
        try { response.close() } catch (_: Throwable) {}
        throw HttpException(code)
    }
    return response
}
