package com.stockfoliong.app

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel.Result
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class BiometricVault(private val activity: FragmentActivity) {
    private val prefs = activity.getSharedPreferences("biometric_sessions_v2", Context.MODE_PRIVATE)
    private var pending = false

    fun handle(call: MethodCall, result: Result) {
        val scope = call.argument<String>("scope") ?: return result.error("scope", "Missing scope", null)
        val alias = "stockfolio.biometric.v2.$scope"
        if (pending) return result.error("busy", "Biometric verification already in progress.", null)
        try {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val writing = call.method == "write"
            when (call.method) {
                "delete" -> {
                    store.deleteEntry(alias)
                    prefs.edit().remove(alias).apply()
                    return result.success(null)
                }
                "read", "write" -> Unit
                else -> return result.notImplemented()
            }
            val token = if (writing) requireNotNull(call.argument<String>("token")) else null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            var sealed = ByteArray(0)
            if (writing) {
                // Enrollment is available only after password sign-in. Replace invalidated keys here, never on read.
                val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setUserAuthenticationRequired(true)
                if (Build.VERSION.SDK_INT >= 30) spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                if (Build.VERSION.SDK_INT >= 24) spec.setInvalidatedByBiometricEnrollment(true)
                val key = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                    init(spec.build())
                    generateKey()
                }
                cipher.init(Cipher.ENCRYPT_MODE, key)
            } else {
                val record = prefs.getString(alias, null) ?: return result.success(null)
                val (iv, data) = record.split(':', limit = 2)
                val key = store.getKey(alias, null) as? SecretKey ?: return result.success(null)
                cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
                sealed = Base64.decode(data, Base64.NO_WRAP)
            }
            val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        pending = false
                        result.error("biometric", message.toString(), null)
                    }
                    override fun onAuthenticationSucceeded(auth: BiometricPrompt.AuthenticationResult) {
                        pending = false
                        try {
                            val verified = requireNotNull(auth.cryptoObject?.cipher)
                            if (token == null) {
                                result.success(verified.doFinal(sealed).toString(Charsets.UTF_8))
                            } else {
                                val data = verified.doFinal(token.toByteArray(Charsets.UTF_8))
                                val record = Base64.encodeToString(verified.iv, Base64.NO_WRAP) + ":" +
                                    Base64.encodeToString(data, Base64.NO_WRAP)
                                check(prefs.edit().putString(alias, record).commit())
                                result.success(null)
                            }
                        } catch (_: Exception) {
                            result.error("key", "Please sign in with your password and set up biometrics again.", null)
                        }
                    }
                })
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle(if (writing) "Enable biometric sign-in" else "Unlock Stockfolio")
                .setAllowedAuthenticators(BIOMETRIC_STRONG)
                .setNegativeButtonText("Cancel")
                .build()
            pending = true
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        } catch (_: Exception) {
            pending = false
            result.error("unavailable", "Biometric verification is unavailable. Use your password.", null)
        }
    }
}
