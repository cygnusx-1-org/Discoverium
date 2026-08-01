# AGP 9 enables R8 minification for release builds by default (AGP 8 did not),
# so these rules only became necessary with the Gradle 9.6.1 / AGP 9.3.0
# toolchain. Upstream Obtainium builds unminified and does not need them.

# room-runtime 2.6.1 ships only "-keep class * extends androidx.room.RoomDatabase",
# which keeps the class but not its members. Under R8 full mode (the default
# since AGP 8) that lets the generated *_Impl no-arg constructor be stripped,
# so Room's reflective instantiation fails at startup with:
#   NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
# Room 2.7+ ships this rule itself; keep it here until that version is pulled in.
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# WorkManager instantiates Workers reflectively by class name.
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
