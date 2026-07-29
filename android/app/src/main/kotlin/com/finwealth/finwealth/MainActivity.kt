package com.finwealth.finwealth

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> result.success(readTokenJson())
                        "write" -> {
                            val value = call.argument<String>("value")
                            if (value.isNullOrEmpty()) {
                                result.error("invalid_argument", "value must be non-empty", null)
                            } else {
                                writeTokenJson(value)
                                result.success(null)
                            }
                        }
                        "clear" -> {
                            clearTokenJson()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("secure_store_error", "secure token store operation failed", null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "installedVersion" -> {
                            val info = packageManager.getPackageInfo(packageName, 0)
                            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                info.longVersionCode
                            } else {
                                @Suppress("DEPRECATION")
                                info.versionCode.toLong()
                            }
                            result.success(
                                mapOf(
                                    "versionName" to (info.versionName ?: ""),
                                    "versionCode" to code.toInt(),
                                ),
                            )
                        }
                        "updateCacheDir" -> result.success(updateCacheDir().absolutePath)
                        "canInstallPackages" -> result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                packageManager.canRequestPackageInstalls()
                            } else {
                                true
                            },
                        )
                        "openInstallPermissionSettings" -> {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            }
                            result.success(null)
                        }
                        "openInstaller" -> {
                            val path = call.argument<String>("path")
                            if (path.isNullOrEmpty()) {
                                result.error("invalid_argument", "path must be non-empty", null)
                            } else {
                                openInstaller(path)
                                result.success(null)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("client_update_error", "client update operation failed", null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONFIG_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "readApiBase" -> result.success(configPrefs().getString(PREF_API_BASE, null))
                        "writeApiBase" -> {
                            val value = call.argument<String>("value")
                            if (value.isNullOrEmpty()) {
                                result.error("invalid_argument", "value must be non-empty", null)
                            } else {
                                configPrefs().edit().putString(PREF_API_BASE, value).apply()
                                result.success(null)
                            }
                        }
                        "clearApiBase" -> {
                            configPrefs().edit().remove(PREF_API_BASE).apply()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("config_store_error", "app config operation failed", null)
                }
            }
    }

    /// 更新包只落在 App 私有 cache 的 updates 子目录（与 FileProvider 映射一致）。
    private fun updateCacheDir(): File =
        File(cacheDir, "updates").apply { mkdirs() }

    private fun openInstaller(path: String) {
        val file = File(path).canonicalFile
        val root = updateCacheDir().canonicalFile
        // 只允许分享已经落在受控目录里的文件，杜绝任意路径外泄。
        require(file.parentFile == root && file.isFile)
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun readTokenJson(): String? {
        val payload = prefs().getString(PREF_TOKEN_PAYLOAD, null) ?: return null
        return try {
            decrypt(payload)
        } catch (_: Exception) {
            clearTokenJson()
            null
        }
    }

    private fun writeTokenJson(value: String) {
        prefs().edit().putString(PREF_TOKEN_PAYLOAD, encrypt(value)).apply()
    }

    private fun clearTokenJson() {
        prefs().edit().remove(PREF_TOKEN_PAYLOAD).apply()
    }

    private fun prefs() =
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun configPrefs() =
        getSharedPreferences(CONFIG_PREFS_NAME, Context.MODE_PRIVATE)

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return "${Base64.encodeToString(cipher.iv, Base64.NO_WRAP)}:${Base64.encodeToString(ciphertext, Base64.NO_WRAP)}"
    }

    private fun decrypt(payload: String): String {
        val parts = payload.split(':', limit = 2)
        require(parts.size == 2)
        val iv = Base64.decode(parts[0], Base64.NO_WRAP)
        val ciphertext = Base64.decode(parts[1], Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(ciphertext), Charsets.UTF_8)
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE,
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(spec, SecureRandom())
        return keyGenerator.generateKey()
    }

    companion object {
        private const val CHANNEL = "finwealth.secure_token_store"
        private const val CONFIG_CHANNEL = "finwealth.app_config"
        private const val UPDATE_CHANNEL = "finwealth.client_update"
        private const val PREFS_NAME = "finwealth_secure_tokens"
        private const val PREF_TOKEN_PAYLOAD = "auth_tokens"
        private const val CONFIG_PREFS_NAME = "finwealth_app_config"
        private const val PREF_API_BASE = "api_base"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "finwealth_auth_token_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
