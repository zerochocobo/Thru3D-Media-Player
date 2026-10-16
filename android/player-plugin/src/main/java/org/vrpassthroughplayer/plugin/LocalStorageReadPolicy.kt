package org.vrpassthroughplayer.plugin

import java.nio.file.AccessDeniedException
import java.nio.file.DirectoryIteratorException
import java.nio.file.NoSuchFileException

internal object LocalStorageReadPolicy {
    data class Failure(val state: String, val message: String)
    fun failure(error: Exception, removable: Boolean, allFiles: Boolean): Failure {
        val cause = if (error is DirectoryIteratorException) error.cause else error
        val denied = cause is AccessDeniedException || cause is SecurityException
        return when {
            denied && removable -> Failure("denied", "STORAGE_FOLDER_ACCESS_NEEDED")
            denied && !allFiles -> Failure("denied", "ALL_FILES_ACCESS_NEEDED")
            cause is NoSuchFileException -> Failure("error", "Storage device unavailable")
            else -> Failure("error", "Storage folder could not be read")
        }
    }
}
