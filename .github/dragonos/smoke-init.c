/* DragonOS init for the RustSBI bootloader smoke test. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int emit(const char *message) {
    size_t remaining = strlen(message);
    while (remaining) {
        ssize_t written = write(STDOUT_FILENO, message, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        message += written;
        remaining -= (size_t)written;
    }
    return 0;
}

int main(void) {
    char command[128];
    size_t length = 0;
    int overflow = 0;
    if (emit("RUSTSBI_DRAGONOS_READY v1\n")) return 1;
    for (;;) {
        char c;
        ssize_t count = read(STDIN_FILENO, &c, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            emit("RUSTSBI_DRAGONOS_ERROR stdin\n");
            return 1;
        }
        if (c != '\n' && c != '\r') {
            if (length + 1 < sizeof(command)) command[length++] = c;
            else overflow = 1;
            continue;
        }
        if (!length && !overflow) continue;
        command[length] = '\0';
        int valid = !overflow && length == 38 && !memcmp(command, "smoke ", 6);
        for (size_t i = 6; valid && i < length; i++) {
            if (!((command[i] >= '0' && command[i] <= '9') ||
                  (command[i] >= 'a' && command[i] <= 'f'))) valid = 0;
        }
        if (!valid) {
            if (emit("RUSTSBI_DRAGONOS_ERROR command\n")) return 1;
        } else {
            const char expected[] = "rustsbi-dragonos-ci-v1\n";
            char data[sizeof(expected)];
            size_t used = 0;
            int fd = open("/etc/rustsbi-smoke.txt", O_RDONLY);
            int good = fd >= 0;
            while (good && used < sizeof(data)) {
                ssize_t n = read(fd, data + used, sizeof(data) - used);
                if (n < 0 && errno == EINTR) continue;
                if (n < 0) good = 0;
                if (n <= 0) break;
                used += (size_t)n;
            }
            if (fd >= 0 && close(fd)) good = 0;
            good = good && used == sizeof(expected) - 1 &&
                   !memcmp(data, expected, sizeof(expected) - 1);
            char reply[100];
            snprintf(reply, sizeof(reply), "RESULT %s %s\n", command + 6, good ? "PASS" : "FAIL");
            if (emit(reply)) return 1;
        }
        length = 0;
        overflow = 0;
    }
}
