package com.fqapp.fqapp

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Runs the bundled bytevc2 transcoder for issue #466: some short-drama episodes
 * only exist as `bytevc2` (a private H.266/VVC shell), which no Android decoder
 * can play. The transcoder is a patched ffmpeg shipped as
 * `libbvc2transcode.so` (see `third_party/bytevc2/`); it decrypts the CENC
 * input with the episode's own key and writes a plain H.264 mp4.
 *
 * The binary is a real file only when the install extracted the native
 * libraries (`packaging.jniLibs.useLegacyPackaging` in `build.gradle.kts`).
 * Without that copy there is nothing to exec, so [available] answers false and
 * Dart keeps the pre-#466 "this episode cannot play" verdict.
 */
class Bytevc2TranscodePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val worker =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "bytevc2-transcode")
        }
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(executable() != null)
            "transcode" -> transcode(call, result)
            else -> result.notImplemented()
        }
    }

    private fun transcode(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        val keyHex = call.argument<String>("keyHex") ?: ""
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
        if (input.isNullOrEmpty() || output.isNullOrEmpty()) {
            result.error("BAD_ARGUMENT", "transcode needs an input and an output path", null)
            return
        }
        val binary = executable()
        if (binary == null) {
            result.error("UNAVAILABLE", "bytevc2 transcoder is not installed", null)
            return
        }
        val enqueuedAt = SystemClock.elapsedRealtime()
        worker.execute {
            var failure: String? = null
            try {
                val remainingMs = timeoutMs - (SystemClock.elapsedRealtime() - enqueuedAt)
                if (remainingMs <= 0) {
                    throw IllegalStateException("bytevc2 transcode timed out while queued")
                }
                val exit = runFfmpeg(binary, input, output, keyHex, remainingMs)
                if (exit != 0) failure = "bytevc2 transcode exited with $exit"
            } catch (error: Exception) {
                failure = error.message ?: error.toString()
            }
            val message = failure
            main.post {
                if (message == null) result.success(output) else result.error("FAILED", message, null)
            }
        }
    }

    /**
     * Direct exec first. Executing a file the app itself does not own is only
     * reached through its own native library directory, so if the kernel
     * refuses it the dynamic linker still loads it (`linker64 <program>`),
     * which is the same mmap the platform uses for `dlopen`.
     */
    private fun runFfmpeg(
        binary: File,
        input: String,
        output: String,
        keyHex: String,
        timeoutMs: Long,
    ): Int {
        val args = ffmpegArgs(binary.absolutePath, input, output, keyHex)
        return try {
            waitFor(ProcessBuilder(args), timeoutMs)
        } catch (error: IOException) {
            // 只有直接 exec 起不来(权限/SELinux)才换 linker;转码本身的
            // 失败在这里不该被重跑一遍。
            val linker = File("/system/bin/linker64").takeIf { it.exists() }
                ?: File("/system/bin/linker").takeIf { it.exists() }
                ?: throw error
            val fallback = ffmpegArgs(binary.absolutePath, input, output, keyHex)
            fallback.add(0, linker.absolutePath)
            waitFor(ProcessBuilder(fallback), timeoutMs)
        }
    }

    /** Mirrors `zfdang/hongguo-open-player`'s transcoder invocation. */
    private fun ffmpegArgs(binary: String, input: String, output: String, keyHex: String): MutableList<String> {
        val args = mutableListOf(
            binary, "-hide_banner", "-loglevel", "error", "-nostdin",
        )
        val key = keyHex.trim()
        if (key.isNotEmpty()) {
            args += listOf("-decryption_key", key)
        }
        args += listOf(
            "-i", input,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "25",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-movflags", "+faststart",
            "-f", "mp4", "-y", output,
        )
        return args
    }

    private fun waitFor(command: ProcessBuilder, timeoutMs: Long): Int {
        command.redirectErrorStream(true)
        val process = command.start()
        val output = StringBuilder()
        val logReader = Thread({
            try {
                process.inputStream.bufferedReader().use { reader ->
                    val buffer = CharArray(1024)
                    while (true) {
                        val count = reader.read(buffer)
                        if (count < 0) break
                        synchronized(output) {
                            val kept = minOf(count, MAX_LOG_CHARS - output.length)
                            if (kept > 0) output.append(buffer, 0, kept)
                        }
                    }
                }
            } catch (_: IOException) {
                // Killing the process or closing its pipe can interrupt a read.
            }
        }, "bytevc2-transcode-log").apply {
            isDaemon = true
            start()
        }
        var interrupted = false
        try {
            if (!process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                val log = synchronized(output) { output.toString().trim() }
                throw IllegalStateException("bytevc2 transcode timed out: $log")
            }
            logReader.join(CLEANUP_TIMEOUT_MS)
            val exit = process.exitValue()
            if (exit != 0) {
                val log = synchronized(output) { output.toString().trim() }
                throw IllegalStateException("bytevc2 transcode failed (exit $exit): $log")
            }
            return exit
        } catch (error: InterruptedException) {
            interrupted = true
            throw error
        } finally {
            process.destroyForcibly()
            try {
                process.waitFor(CLEANUP_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                interrupted = true
            }
            for (stream in listOf(process.inputStream, process.outputStream, process.errorStream)) {
                try {
                    stream.close()
                } catch (_: IOException) {
                    // Cleanup must preserve the transcode's original outcome.
                }
            }
            logReader.interrupt()
            try {
                logReader.join(CLEANUP_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                interrupted = true
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
    }

    private fun executable(): File? {
        val binary = File(context.applicationInfo.nativeLibraryDir, BINARY)
        if (!binary.isFile) return null
        if (!binary.canExecute()) binary.setExecutable(true, false)
        return binary
    }

    private companion object {
        const val CHANNEL = "fqapp/bytevc2transcode"
        const val BINARY = "libbvc2transcode.so"
        const val MAX_LOG_CHARS = 4096
        const val CLEANUP_TIMEOUT_MS = 1000L
        const val DEFAULT_TIMEOUT_MS = 10 * 60 * 1000L
    }
}
