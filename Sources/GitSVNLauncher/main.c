// SPDX-License-Identifier: GPL-2.0-or-later
// Relocatable dispatcher for the private Perl/SVN payload beside git-core.
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX], path[PATH_MAX], root[PATH_MAX];
    uint32_t size = sizeof executable;
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, path)) {
        perror("TurtleGit git-svn launcher"); return 127;
    }
    char *slash = strrchr(path, '/'); if (!slash) return 127; *slash = 0;
#if defined(__arm64__)
    const char *arch = "arm64";
#elif defined(__x86_64__)
    const char *arch = "x86_64";
#else
#error Unsupported Git SVN runtime architecture
#endif
    if (snprintf(root, sizeof root, "%s/../git-svn-runtime/%s", path, arch) >= sizeof root) return 127;
    char perl[PATH_MAX], script[PATH_MAX], modules[PATH_MAX];
    if (snprintf(perl, sizeof perl, "%s/Perl/bin/perl", root) >= sizeof perl ||
        snprintf(script, sizeof script, "%s/GitPerl/git-svn.perl", root) >= sizeof script ||
        snprintf(modules, sizeof modules, "%s/GitPerl", root) >= sizeof modules) return 127;
    // Only bundled modules are injected by this dispatcher. Repository and
    // authentication environment remains available to Git/SVN itself.
    unsetenv("PERL5OPT"); unsetenv("PERL5DB"); unsetenv("PERLLIB");
    unsetenv("PERL_LOCAL_LIB_ROOT"); unsetenv("PERL_MB_OPT"); unsetenv("PERL_MM_OPT");
    if (setenv("PERL5LIB", modules, 1) != 0 || setenv("GITPERLLIB", modules, 1) != 0) return 127;
    char **arguments = calloc((size_t)argc + 2, sizeof(char *)); if (!arguments) return 127;
    arguments[0] = perl; arguments[1] = script;
    for (int i = 1; i < argc; ++i) arguments[i + 1] = argv[i];
    execv(perl, arguments);
    perror("TurtleGit bundled git-svn runtime"); free(arguments); return 127;
}
