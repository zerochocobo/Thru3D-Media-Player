package org.vrpassthroughplayer.plugin

import org.json.JSONException
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** The sign-in screen reports only fixed stage/category names and numeric statuses. */
internal class CloudLoginFailure(stage: Stage, error: Exception? = null) : IOException() {
    enum class Stage { REQUEST, CALLBACK, EXCHANGE, CREDENTIAL, CORE, MOUNT, ROOT, SAVE }

    val reason = (error as? CloudFailure)?.reason
    val code = buildString {
        val cloud = error as? CloudFailure
        append("AUTH-").append(stage.name)
        val detail = cloud?.detail.orEmpty().lowercase()
        val category = when (cloud?.cause ?: error) {
            is UnknownHostException -> "DNS"
            is SocketTimeoutException -> "TIMEOUT"
            is SSLException -> "TLS"
            is JSONException -> "RESPONSE"
            else -> when {
                "no such host" in detail -> "DNS"
                "i/o timeout" in detail || "context deadline exceeded" in detail -> "TIMEOUT"
                "x509:" in detail || "tls handshake" in detail -> "TLS"
                stage == Stage.MOUNT && "failed to get user id" in detail -> "PROFILE"
                "failed to refresh token:" in detail || "empty token returned from official api" in detail -> "REFRESH"
                else -> ""
            }
        }
        if (category.isNotEmpty()) append(' ').append(category)
        cloud?.httpStatus?.takeIf { it in 100..599 }?.let { append(" HTTP ").append(it) }
        cloud?.apiCode?.let { append(" API ").append(it) }
    }

    companion object {
        inline fun <T> at(stage: Stage, block: () -> T): T = try {
            block()
        } catch (error: CloudLoginFailure) {
            throw error
        } catch (error: Exception) {
            throw CloudLoginFailure(stage, error)
        }
    }
}
