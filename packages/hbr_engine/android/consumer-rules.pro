# MediaPipe Tasks drives its native graph through JNI and serialises its
# options with protobuf-lite, which finds message fields by name through
# reflection. If R8 renames or strips these classes, segmentation still
# "runs" but returns an empty person mask, so the exported video shows only
# the new background. Keep them intact.
-keep class com.google.mediapipe.** { *; }
-keep interface com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
-dontwarn javax.annotation.**
-dontwarn javax.lang.model.**
-dontwarn com.google.auto.value.**

# This plugin (small; kept whole so JNI and on-device tests can reach it).
-keep class com.holistic.hbr_engine.** { *; }
