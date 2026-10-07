/* Synthetic provider parent for contract tests; never contacts a real provider. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#ifndef CLAUDE_VERSION
#define CLAUDE_VERSION "2.1.287"
#endif
#ifndef CODEX_VERSION
#define CODEX_VERSION "0.159.2"
#endif
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts(strstr(argv[0], "/codex") ? "codex-cli " CODEX_VERSION : CLAUDE_VERSION " (Claude Code)");
        return 0;
    }
    if (argc < 2) return 1;
    pid_t child = fork();
    if (child == 0) { execv(argv[1], argv + 1); _exit(1); }
    int status;
    if (child < 0 || waitpid(child, &status, 0) < 0) return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
