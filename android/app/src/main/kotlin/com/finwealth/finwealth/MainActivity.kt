package com.finwealth.finwealth

import android.content.Context
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
        private const val PREFS_NAME = "finwealth_secure_tokens"
        private const val PREF_TOKEN_PAYLOAD = "auth_tokens"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "finwealth_auth_token_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
