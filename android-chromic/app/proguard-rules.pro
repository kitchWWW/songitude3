# Release builds ship unshrunk (isMinifyEnabled = false) — the app is small and every dependency
# with reflection (kotlinx.serialization, Coil, Maps) would need keep rules that have to be verified
# on a device. If shrinking is ever turned on, start with:
#   -keepclassmembers class **$$serializer { *** INSTANCE; }
#   -keep,includedescriptorclasses class com.brianellissound.songitude.**$$serializer { *; }
