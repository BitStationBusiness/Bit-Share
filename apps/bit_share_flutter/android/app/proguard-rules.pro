# Apache Commons Compress registers ZIP extra fields reflectively. R8 may
# otherwise merge their concrete implementations and make registration fail.
-keep,allowobfuscation class * implements org.apache.commons.compress.archivers.zip.ZipExtraField {
    public <init>();
}

# getInfo() deserializes yt-dlp JSON into these models through Gson reflection.
# Keeping their names and fields prevents release-only empty/broken format data.
-keep class com.yausername.youtubedl_android.mapper.** { *; }

# Chaquopy calls these methods reflectively from bitshare_ytdlp.py.
-keep interface com.bitstation.bitshare.download.PythonYtDlpEngine$DownloadCallback { *; }
-keep class * implements com.bitstation.bitshare.download.PythonYtDlpEngine$DownloadCallback { *; }
-keepattributes Signature,*Annotation*
