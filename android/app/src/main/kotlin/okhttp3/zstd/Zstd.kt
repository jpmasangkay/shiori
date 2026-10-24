package okhttp3.zstd

import com.squareup.zstd.okio.zstdDecompress
import okhttp3.CompressionInterceptor
import okio.BufferedSource
import okio.Source

object Zstd : CompressionInterceptor.DecompressionAlgorithm {
    override fun getEncoding(): String = "zstd"

    override fun decompress(source: BufferedSource): Source {
        return try {
            source.zstdDecompress()
        } catch (_: Throwable) {
            source
        }
    }
}

