# Flutter ProGuard Rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep App code and platform channels
-keep class com.example.manga_reader.** { *; }
-keep interface com.example.manga_reader.** { *; }
-keepclassmembers class com.example.manga_reader.** { *; }
-keepclassmembers interface com.example.manga_reader.** { *; }

# Keep Tachiyomi extension interfaces, base classes, models, and network helpers
-keep class eu.kanade.tachiyomi.** { *; }
-keep interface eu.kanade.tachiyomi.** { *; }
-keepclassmembers class eu.kanade.tachiyomi.** { *; }
-keepclassmembers interface eu.kanade.tachiyomi.** { *; }

# Keep Injekt dependency injection
-keep class uy.kohesive.injekt.** { *; }
-keep interface uy.kohesive.injekt.** { *; }
-keepclassmembers class uy.kohesive.injekt.** { *; }

# Keep RxJava (used by Tachiyomi 1.x extensions)
-keep class rx.** { *; }
-keep interface rx.** { *; }
-keepclassmembers class rx.** { *; }

# Keep OkHttp & Okio (extensions call okhttp3 directly)
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-keepclassmembers class okhttp3.** { *; }
-keep class okio.** { *; }
-keep interface okio.** { *; }
-keepclassmembers class okio.** { *; }

# Keep JSoup (extensions parse HTML)
-keep class org.jsoup.** { *; }
-keep interface org.jsoup.** { *; }
-keepclassmembers class org.jsoup.** { *; }

# Keep Kotlinx Serialization
-keep class kotlinx.serialization.** { *; }
-keep interface kotlinx.serialization.** { *; }
-keepclassmembers class kotlinx.serialization.** { *; }

# Keep AndroidX Preference
-keep class androidx.preference.** { *; }
-keep interface androidx.preference.** { *; }
-keepclassmembers class androidx.preference.** { *; }

# Keep Zstandard
-keep class com.squareup.zstd.** { *; }
-keep interface com.squareup.zstd.** { *; }
-keepclassmembers class com.squareup.zstd.** { *; }

# Preserve reflection attributes
-keepattributes *Annotation*,EnclosingMethod,InnerClasses,Signature,SourceFile,LineNumberTable

# Don't warn for unresolved references in third-party libraries
-dontwarn rx.**
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.jsoup.**
-dontwarn uy.kohesive.injekt.**
-dontwarn kotlinx.serialization.**
-dontwarn eu.kanade.tachiyomi.**
-dontwarn com.example.manga_reader.**

