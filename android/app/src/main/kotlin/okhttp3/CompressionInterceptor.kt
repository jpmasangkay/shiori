package okhttp3

import okhttp3.brotli.Brotli
import okhttp3.zstd.Zstd
import okio.BufferedSource
import okio.GzipSource
import okio.Source
import okio.buffer

open class CompressionInterceptor(
    vararg val algorithms: DecompressionAlgorithm
) : Interceptor {

    constructor() : this(*emptyArray<DecompressionAlgorithm>())

    interface DecompressionAlgorithm {
        fun getEncoding(): String
        fun decompress(source: BufferedSource): Source
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        val body = response.body ?: return response

        val encoding = response.header("Content-Encoding") ?: return response
        val algorithm = algorithms.firstOrNull { it.getEncoding().equals(encoding, ignoreCase = true) }
            ?: when {
                encoding.equals("gzip", ignoreCase = true) -> Gzip
                encoding.equals("br", ignoreCase = true) -> Brotli
                encoding.equals("zstd", ignoreCase = true) -> Zstd
                else -> null
            } ?: return response

        val decompressedSource = algorithm.decompress(body.source()).buffer()
        val strippedHeaders = response.headers.newBuilder()
            .removeAll("Content-Encoding")
            .removeAll("Content-Length")
            .build()

        return response.newBuilder()
            .headers(strippedHeaders)
            .body(ResponseBody.create(body.contentType(), -1L, decompressedSource))
            .build()
    }
}

object Gzip : CompressionInterceptor.DecompressionAlgorithm {
    override fun getEncoding(): String = "gzip"
    override fun decompress(source: BufferedSource): Source = GzipSource(source)
}
