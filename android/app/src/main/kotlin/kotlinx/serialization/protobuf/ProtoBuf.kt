package kotlinx.serialization.protobuf

import kotlinx.serialization.BinaryFormat
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.modules.EmptySerializersModule
import kotlinx.serialization.modules.SerializersModule

open class ProtoBuf(
    override val serializersModule: SerializersModule = EmptySerializersModule()
) : BinaryFormat {
    companion object Default : ProtoBuf()

    override fun <T> encodeToByteArray(serializer: SerializationStrategy<T>, value: T): ByteArray {
        return ByteArray(0)
    }

    override fun <T> decodeFromByteArray(deserializer: DeserializationStrategy<T>, bytes: ByteArray): T {
        throw UnsupportedOperationException("ProtoBuf decodeFromByteArray not supported in stub")
    }
}

