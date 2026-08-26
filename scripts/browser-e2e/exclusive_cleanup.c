#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

enum {
    EXIT_AMBIGUOUS = 70,
    EXIT_NOT_EMPTY = 71,
    EXIT_USAGE = 64,
};

struct expected_identity {
    dev_t device;
    ino_t inode;
    uid_t owner;
    mode_t mode;
};

static int parse_uintmax(const char *text, uintmax_t maximum, uintmax_t *value) {
    char *end = NULL;
    uintmax_t parsed;

    if (text == NULL || text[0] == '\0' || text[0] == '-') {
        return 0;
    }
    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed > maximum) {
        return 0;
    }
    *value = parsed;
    return 1;
}

static int parse_fd(const char *text, int *descriptor) {
    uintmax_t parsed;

    if (!parse_uintmax(text, INT_MAX, &parsed)) {
        return 0;
    }
    *descriptor = (int)parsed;
    return 1;
}

static int parse_identity(char *const arguments[], struct expected_identity *identity) {
    uintmax_t device;
    uintmax_t inode;
    uintmax_t owner;
    uintmax_t mode;

    if (!parse_uintmax(arguments[0], UINTMAX_MAX, &device) ||
        !parse_uintmax(arguments[1], UINTMAX_MAX, &inode) ||
        !parse_uintmax(arguments[2], UINT_MAX, &owner) ||
        !parse_uintmax(arguments[3], UINT_MAX, &mode)) {
        return 0;
    }
    identity->device = (dev_t)device;
    identity->inode = (ino_t)inode;
    identity->owner = (uid_t)owner;
    identity->mode = (mode_t)mode;
    return (uintmax_t)identity->device == device &&
           (uintmax_t)identity->inode == inode &&
           (uintmax_t)identity->owner == owner &&
           (uintmax_t)identity->mode == mode;
}

static int valid_name(const char *name) {
    return name != NULL && name[0] != '\0' && strchr(name, '/') == NULL &&
           strcmp(name, ".") != 0 && strcmp(name, "..") != 0;
}

static int matches(const struct stat *observed,
                   const struct expected_identity *expected,
                   int require_directory) {
    return observed->st_dev == expected->device &&
           observed->st_ino == expected->inode &&
           observed->st_uid == expected->owner &&
           observed->st_mode == expected->mode &&
           (!require_directory || S_ISDIR(observed->st_mode));
}

static int directory_is_empty(int descriptor) {
    int inspection = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    DIR *directory;
    struct dirent *entry;
    int empty = 1;

    if (inspection < 0) {
        return -1;
    }
    directory = fdopendir(inspection);
    if (directory == NULL) {
        close(inspection);
        return -1;
    }
    errno = 0;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0) {
            empty = 0;
            break;
        }
    }
    if (entry == NULL && errno != 0) {
        empty = -1;
    }
    if (closedir(directory) != 0) {
        empty = -1;
    }
    return empty;
}

static int name_is_absent(int descriptor, const char *name) {
    struct stat ignored;

    errno = 0;
    if (fstatat(descriptor, name, &ignored, AT_SYMLINK_NOFOLLOW) == 0) {
        return 0;
    }
    return errno == ENOENT ? 1 : -1;
}

#if PICKVIA_EXCLUSIVE_CLEANUP_TESTING
static int pause_after_rename(void) {
    const char *text = getenv("PICKVIA_EXCLUSIVE_CLEANUP_TEST_SOCKET_FD");
    int descriptor;
    char byte;

    if (text == NULL) {
        return 1;
    }
    if (!parse_fd(text, &descriptor) || write(descriptor, "R", 1) != 1 ||
        read(descriptor, &byte, 1) != 1 || byte != 'C') {
        return 0;
    }
    return 1;
}
#else
static int pause_after_rename(void) {
    return 1;
}
#endif

int main(int argc, char *argv[]) {
    int parent_descriptor;
    int root_descriptor;
    int quarantine_descriptor = -1;
    int empty;
    struct expected_identity root_expected;
    struct expected_identity parent_expected;
    struct expected_identity helper_expected;
    struct stat root_observed;
    struct stat parent_observed;
    struct stat named_observed;
    const char *original;
    const char *quarantine;
    const char *helper_name;

    if (argc != 18 || !parse_fd(argv[1], &parent_descriptor) ||
        !parse_fd(argv[2], &root_descriptor) || !valid_name(argv[3]) ||
        !valid_name(argv[4]) || strncmp(argv[4], ".pickvia-finalize-", 18) != 0 ||
        !parse_identity(&argv[5], &root_expected) ||
        !parse_identity(&argv[9], &parent_expected) ||
        !parse_identity(&argv[14], &helper_expected)) {
        return EXIT_USAGE;
    }
    original = argv[3];
    quarantine = argv[4];
    helper_name = argv[13];
    if (strcmp(helper_name, "-") != 0 && !valid_name(helper_name)) {
        return EXIT_USAGE;
    }
    if (fstat(parent_descriptor, &parent_observed) != 0 ||
        fstat(root_descriptor, &root_observed) != 0 ||
        !matches(&parent_observed, &parent_expected, 1) ||
        !matches(&root_observed, &root_expected, 1) ||
        parent_observed.st_dev != root_observed.st_dev) {
        return EXIT_AMBIGUOUS;
    }
    if (fstatat(parent_descriptor, original, &named_observed, AT_SYMLINK_NOFOLLOW) != 0 ||
        !matches(&named_observed, &root_expected, 1)) {
        return EXIT_AMBIGUOUS;
    }
    if (strcmp(helper_name, "-") != 0) {
        if (fstatat(root_descriptor, helper_name, &named_observed, AT_SYMLINK_NOFOLLOW) != 0 ||
            !matches(&named_observed, &helper_expected, 0) ||
            !S_ISREG(named_observed.st_mode) || named_observed.st_nlink != 1 ||
            unlinkat(root_descriptor, helper_name, 0) != 0 ||
            name_is_absent(root_descriptor, helper_name) != 1) {
            return EXIT_AMBIGUOUS;
        }
    }
    empty = directory_is_empty(root_descriptor);
    if (empty == 0) {
        return EXIT_NOT_EMPTY;
    }
    if (empty < 0 || name_is_absent(parent_descriptor, quarantine) != 1) {
        return EXIT_AMBIGUOUS;
    }
    if (renameatx_np(parent_descriptor, original, parent_descriptor, quarantine,
                     RENAME_EXCL) != 0) {
        return EXIT_AMBIGUOUS;
    }
    if (!pause_after_rename()) {
        return EXIT_AMBIGUOUS;
    }
    quarantine_descriptor = openat(parent_descriptor, quarantine,
                                   O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (quarantine_descriptor < 0 ||
        fstat(quarantine_descriptor, &named_observed) != 0 ||
        !matches(&named_observed, &root_expected, 1) ||
        fstat(root_descriptor, &root_observed) != 0 ||
        !matches(&root_observed, &root_expected, 1) ||
        name_is_absent(parent_descriptor, original) != 1) {
        if (quarantine_descriptor >= 0) {
            close(quarantine_descriptor);
        }
        return EXIT_AMBIGUOUS;
    }
    empty = directory_is_empty(root_descriptor);
    if (empty != 1 || directory_is_empty(quarantine_descriptor) != 1) {
        close(quarantine_descriptor);
        return empty == 0 ? EXIT_NOT_EMPTY : EXIT_AMBIGUOUS;
    }
    if (unlinkat(parent_descriptor, quarantine, AT_REMOVEDIR) != 0) {
        close(quarantine_descriptor);
        return errno == ENOTEMPTY ? EXIT_NOT_EMPTY : EXIT_AMBIGUOUS;
    }
    if (name_is_absent(parent_descriptor, original) != 1 ||
        name_is_absent(parent_descriptor, quarantine) != 1 ||
        fstat(root_descriptor, &root_observed) != 0 ||
        !matches(&root_observed, &root_expected, 1) ||
        directory_is_empty(root_descriptor) != 1) {
        close(quarantine_descriptor);
        return EXIT_AMBIGUOUS;
    }
    if (close(quarantine_descriptor) != 0) {
        return EXIT_AMBIGUOUS;
    }
    return 0;
}
