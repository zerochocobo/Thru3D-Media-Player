# Local file operations

Local deletion/tree deletion/rename keep identity, no-follow traversal and no-replace rules. Android native code opens ancestor directory handles with `O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`: search permission is enough for traversal; the final operation still requires actual write permission. Errors distinguish denied access from other failures without logging private filenames/paths.

`tests/native/media_delete_test.cpp` includes production `native/rvm/media_delete.cpp`; `media_delete_host/jni.h` replaces only the JNI byte-array boundary. Compile with a Linux C++17 compiler and `-I tests/native/media_delete_host`, then pass a disposable output directory on a filesystem enforcing POSIX permissions. Run as an unprivileged user; WSL root can use `setpriv --reuid=65534 --regid=65534 --clear-groups`. Keep executables/reports in `build/output/`. The fixture creates/removes only its own `media-delete-XXXXXX` subtree; never supply user media as test data.

Host checks cover search-only ancestors, UTF-8, files/directories, symlink escape, parent traversal, retained write protection, no-replace and descriptor cleanup. They do not establish Android SELinux/FUSE or headset acceptance.
