package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.json.JSONException
import org.junit.Assert.*
import org.junit.Test
import java.net.SocketTimeoutException

class CloudDiagnosticsTest {
    @Test fun list115FailureSurvivesCoreAndMediaDto() {
        val response = JSONObject().put("code", 500).put("message", "Cloud request failed")
            .put("error_detail", "list115.list\n115 code: 430004, message: 文件夹不存在或无权限")
        val failure = try { CloudDiagnostics.checkCore(response, "/list115"); error("accepted failure") }
            catch (failure: CloudFailure) { failure }
        val dto = CloudDiagnostics.response(failure, "cloud.browse")
        assertEquals("Cloud connection failed", dto.getString("error"))
        assertEquals("cloud_unavailable", dto.getString("error_reason"))
        assertTrue(dto.getString("error_detail").contains("115 code: 430004"))
        assertTrue(dto.getString("error_detail").contains("文件夹不存在或无权限"))
        assertTrue(dto.getString("error_detail").contains("/list115"))
    }
    @Test fun rootSuccessAndLegacyChildFailureKeepTheirOwnResults() {
        var calls = 0
        val drive = CloudDrive(CloudDrive.P115, "UID=fixture", CloudTransport { _, _, _ ->
            CloudResponse(if (calls++ == 0) JSONObject("""{"state":true,"count":1,"data":[{"cid":"42","n":"云下载"}]}""")
                else JSONObject("""{"state":false,"errno":70005,"errmsg":"目录访问被拒绝"}"""))
        })
        assertEquals("云下载", drive.page("/").files.single().name)
        val failure = try { drive.page("/云下载"); error("accepted failure") } catch (failure: CloudFailure) { failure }
        assertTrue(failure.detail.contains("70005")); assertTrue(failure.detail.contains("目录访问被拒绝"))
        assertEquals(2, calls)
    }
    @Test fun networkAndMalformedResponseRemainDistinctWithoutPayloads() {
        val timeout = CloudDiagnostics.response(SocketTimeoutException("Read timed out"), "OpenList /list115")
        assertTrue(timeout.getString("error_detail").contains("SocketTimeoutException: Read timed out"))
        val malformed = CloudDiagnostics.response(JSONException("invalid {secret-payload}"), "cloud.library")
        assertTrue(malformed.getString("error_detail").contains("Invalid cloud response"))
        assertFalse(malformed.toString().contains("secret-payload"))
    }
    @Test fun diagnosticsRedactSecretsAndRemainBounded() {
        val input = "115 code: 403, message: denied\nCookie: UID=cookie-secret; CID=cid-secret\nAuthorization: Bearer bearer-secret\n" +
            """{"access_token":"access-secret","refresh_token":"refresh-secret","password":"password-secret"} """ +
            "https://user:uri-secret@proapi.115.com/file?sign=signed-secret UID=uid-secret SEID=seid-secret"
        val detail = CloudFailure(detail = input).detail
        for (secret in listOf("cookie-secret", "cid-secret", "bearer-secret", "access-secret", "refresh-secret", "password-secret", "uri-secret", "signed-secret", "uid-secret", "seid-secret"))
            assertFalse(secret, detail.contains(secret))
        assertTrue(detail.contains("115 code: 403")); assertTrue(detail.contains("denied"))
        assertTrue(CloudDiagnostics.sanitize("中".repeat(10000)).length <= 4097)
    }
    @Test fun knownCoreSearchErrorsRetainActionableText() {
        try { CloudDiagnostics.checkCore(JSONObject().put("code", 500).put("message", "Search expired. Search again"), "/search"); fail() }
        catch (failure: IllegalStateException) { assertEquals("Search expired. Search again", failure.message) }
    }
    @Test fun loginErrorCodeSurvivesZeroErrnoAndJsonCredentialRedaction() {
        val failure = CloudDiagnostics.providerFailure(JSONObject("""{"state":false,"errno":0,"code":99,"errmsg":"Session expired"}"""))
        assertEquals("cloud_login_required", failure.reason)
        assertTrue(failure.detail.contains("99"))
        val safe = CloudDiagnostics.sanitize("""{"cookie":"private-cookie","authorization":"private-auth"}""")
        assertFalse(safe.contains("private-cookie")); assertFalse(safe.contains("private-auth"))
    }
}
