// Compile with -I tests/native/media_delete_host; run as an unprivileged Linux
// user with a writable output directory on a filesystem enforcing chmod.
#ifndef MEDIA_DELETE_SOURCE
#define MEDIA_DELETE_SOURCE "../../native/rvm/media_delete.cpp"
#endif
#include MEDIA_DELETE_SOURCE
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/stat.h>

namespace fs = std::filesystem;
static JNIEnv env;
static int checks = 0, failures = 0;
static void expect(bool value, const char* description) {
    ++checks;
    if (!value) ++failures;
    std::cout << (value ? "PASS " : "FAIL ") << description << '\n';
}
static std::vector<jbyte> utf8(const std::string& s) { return {s.begin(), s.end()}; }
static int removeFile(const std::string& path) {
    auto bytes = utf8(path);
    return Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_unlink(&env, nullptr, &bytes);
}
static int removeAt(const std::string& root, const std::string& relative, bool directory) {
    auto a = utf8(root), b = utf8(relative);
    return Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_removeAt(&env, nullptr, &a, &b, directory);
}
static int renameAt(const std::string& parent, const std::string& from, const std::string& to) {
    auto a = utf8(parent), b = utf8(from), c = utf8(to);
    return Java_org_vrpassthroughplayer_plugin_NativeMediaDelete_renameAt(&env, nullptr, &a, &b, &c);
}
static void touch(const fs::path& file) {
    std::ofstream out(file); out << "fixture";
    if (!out) throw std::runtime_error("Cannot create fixture");
}
static int fdCount() {
    int count = 0;
    for ([[maybe_unused]] const auto& entry : fs::directory_iterator("/proc/self/fd")) ++count;
    return count;
}
int main(int argc, char** argv) {
    if (argc != 2 || geteuid() == 0) {
        std::cerr << "Run as an unprivileged user; pass an existing writable build output directory\n";
        return 2;
    }
    std::string pattern = (fs::canonical(argv[1]) / "media-delete-XXXXXX").string();
    char* made = ::mkdtemp(pattern.data());
    if (!made) return 2;
    const fs::path base(made), ancestor = base / "search-only", folder = ancestor / "Pictures";
    fs::create_directories(folder);
    touch(folder / "screenshot.png"); touch(folder / "old.mp4");
    fs::create_directories(folder / "tree" / "nested");
    touch(folder / "tree" / "nested" / "child.png");
    expect(::chmod(ancestor.c_str(), 0111) == 0, "create search-only ancestor");
    int fd = ::open(ancestor.c_str(), O_RDONLY | O_DIRECTORY);
    const int readError = errno;
    if (fd >= 0) ::close(fd);
    expect(fd == -1 && readError == EACCES, "old read-directory requirement really fails");
    expect(removeFile((folder / "screenshot.png").string()) == 0 && !fs::exists(folder / "screenshot.png"),
           "delete own screenshot through unreadable ancestor");
    expect(renameAt(folder.string(), "old.mp4", "new.mp4") == 0 && fs::exists(folder / "new.mp4") && !fs::exists(folder / "old.mp4"),
           "rename through unreadable ancestor");
    expect(removeAt((folder / "tree").string(), "nested/child.png", false) == 0, "delete nested file through unreadable ancestor");
    expect(removeAt((folder / "tree").string(), "nested", true) == 0, "delete nested empty folder");
    expect(removeAt((folder / "tree").string(), "", true) == 0, "delete empty tree root");
    ::chmod(ancestor.c_str(), 0700);

    const fs::path safe = base / "safe", outside = base / "outside";
    fs::create_directories(safe); fs::create_directories(outside);
    touch(outside / "keep.png");
    fs::create_directory_symlink(outside, safe / "link");
    expect(removeFile((safe / "link" / "keep.png").string()) != 0 && fs::exists(outside / "keep.png"), "symlink ancestor cannot redirect file deletion");
    expect(removeAt(safe.string(), "link/keep.png", false) != 0 && fs::exists(outside / "keep.png"), "symlink ancestor cannot redirect tree deletion");
    expect(renameAt((safe / "link").string(), "keep.png", "moved.png") != 0 && fs::exists(outside / "keep.png"), "symlink ancestor cannot redirect rename");
    expect(removeAt(safe.string(), "../outside/keep.png", false) == EINVAL && fs::exists(outside / "keep.png"), "reject parent traversal");
    expect(removeAt(safe.string(), "/outside/keep.png", false) == EINVAL, "reject absolute relative path");
    expect(removeFile("relative.png") == EINVAL, "reject relative file path");
    expect(removeFile(safe.string() + std::string("/bad\0.png", 9)) == EINVAL, "reject embedded NUL");
    expect(removeFile((safe / "missing.png").string()) == ENOENT, "preserve missing-file errno");
    fs::create_directory(safe / "empty");
    expect(removeFile((safe / "empty").string()) != 0 && fs::is_directory(safe / "empty"), "file unlink cannot delete a substituted empty directory");
    touch(safe / "empty" / "keep.png");
    expect(removeAt(safe.string(), "empty", true) == ENOTEMPTY && fs::exists(safe / "empty" / "keep.png"), "directory removal cannot recursively delete unplanned contents");
    touch(safe / "a.png"); touch(safe / "b.png");
    expect(renameAt(safe.string(), "a.png", "b.png") == EEXIST && fs::exists(safe / "a.png") && fs::exists(safe / "b.png"), "rename never replaces existing destination");
    expect(renameAt(safe.string(), "a.png", "../escape.png") == EINVAL && fs::exists(safe / "a.png"), "reject rename destination traversal");
    expect(renameAt(safe.string(), ".", "other") == EINVAL, "reject rename dot source");
    expect(renameAt(safe.string(), "a.png", "renamed.png") == 0 && fs::exists(safe / "renamed.png"), "ordinary rename still works");
    touch(safe / u8"截图 空格.png");
    expect(removeFile((safe / u8"截图 空格.png").string()) == 0, "UTF-8 screenshot filename deletion");
    ::chmod(safe.c_str(), 0500);
    expect(removeFile((safe / "b.png").string()) == EACCES && fs::exists(safe / "b.png"), "O_PATH does not bypass parent write permission");
    ::chmod(safe.c_str(), 0700);
    const int before = fdCount();
    for (int i = 0; i < 100; ++i) {
        removeFile((safe / "missing.png").string());
        removeAt(safe.string(), "link/keep.png", false);
        renameAt((safe / "link").string(), "keep.png", "moved.png");
    }
    expect(fdCount() == before, "failed operations close all directory handles");
    // Only the uniquely created fixture subtree is removed.
    fs::remove_all(base);
    std::cout << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
