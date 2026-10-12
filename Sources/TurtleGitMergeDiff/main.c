// SPDX-License-Identifier: GPL-2.0-or-later
// Native adapter for the Subversion diff APIs used by TortoiseGitMerge.
// Subversion/APR are the pinned, relocated GitSVN runtime, not system libraries.
#include <svn_diff.h>
#include <svn_error.h>
#include <apr_general.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static size_t records;
static int failed;
static svn_error_t *emit(const char *kind, apr_off_t os, apr_off_t ol,
                         apr_off_t ms, apr_off_t ml, apr_off_t ts, apr_off_t tl) {
    if (++records > 1000000) { failed = 1; return NULL; }
    printf("%s\t%lld\t%lld\t%lld\t%lld\t%lld\t%lld\n", kind,
           (long long)os, (long long)ol, (long long)ms, (long long)ml, (long long)ts, (long long)tl);
    return NULL;
}
#define CALLBACK(name, kind) static svn_error_t *name(void *baton, apr_off_t os, apr_off_t ol, apr_off_t ms, apr_off_t ml, apr_off_t ts, apr_off_t tl) { (void)baton; return emit(kind, os, ol, ms, ml, ts, tl); }
CALLBACK(common, "common")
CALLBACK(modified, "modified")
CALLBACK(latest, "latest")
CALLBACK(same_change, "same")
static svn_error_t *conflict(void *baton, apr_off_t os, apr_off_t ol, apr_off_t ms, apr_off_t ml, apr_off_t ts, apr_off_t tl, svn_diff_t *resolved) {
    (void)baton; (void)resolved;
    // Keep the top-level region. The caller may request resolved children in
    // a later protocol version; do not flatten away the conflict container.
    return emit("conflict", os, ol, ms, ml, ts, tl);
}
static int read_input(const char *path, svn_string_t *value) {
    FILE *file = fopen(path, "rb"); if (!file) return 0;
    if (fseek(file, 0, SEEK_END) || ftell(file) < 0) { fclose(file); return 0; }
    long size = ftell(file);
    if (size > 32 * 1024 * 1024 || fseek(file, 0, SEEK_SET)) { fclose(file); return 0; }
    char *bytes = malloc((size_t)size + 1); if (!bytes) { fclose(file); return 0; }
    if (fread(bytes, 1, (size_t)size, file) != (size_t)size) { free(bytes); fclose(file); return 0; }
    fclose(file); bytes[size] = 0;
    // Inputs are line-framed ASCII hexadecimal keys, not untrusted filenames
    // from the compared documents. Refuse non-protocol input.
    size_t line = 0;
    for (long i = 0; i < size; ++i) {
        char ch = bytes[i];
        if (ch == '\n') { if (line % 2) { free(bytes); return 0; } line = 0; }
        else if ((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) ++line;
        else { free(bytes); return 0; }
    }
    if (line != 0 || (size && bytes[size - 1] != '\n')) { free(bytes); return 0; }
    value->data = bytes; value->len = (size_t)size; return 1;
}
#define LOAD(name) __typeof__(&name) p_##name = (__typeof__(&name))dlsym(library, #name); if (!p_##name) { fprintf(stderr, "Missing bundled Subversion API: %s\n", #name); dlclose(library); return 1; }
int main(int argc, char **argv) {
    if (!((argc == 5 && !strcmp(argv[2], "2")) || (argc == 6 && !strcmp(argv[2], "3")))) {
        fprintf(stderr, "Expected pinned Git runtime, 2/3, and framed source files.\n"); return 2;
    }
#if defined(__arm64__)
    const char *arch = "arm64";
#elif defined(__x86_64__)
    const char *arch = "x86_64";
#else
#error Unsupported merge engine architecture
#endif
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/libexec/git-svn-runtime/%s/Subversion/lib/libsvn_diff-1.0.dylib", argv[1], arch) >= sizeof path) return 2;
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "Could not load the pinned Subversion diff library.\n"); return 1; }
    LOAD(apr_initialize); LOAD(apr_terminate); LOAD(apr_pool_create_ex); LOAD(apr_pool_destroy);
    LOAD(svn_diff_file_options_create); LOAD(svn_diff_mem_string_diff); LOAD(svn_diff_mem_string_diff3);
    LOAD(svn_diff_output2); LOAD(svn_error_clear);
    if (p_apr_initialize() != APR_SUCCESS) { dlclose(library); return 1; }
    apr_pool_t *pool = NULL;
    if (p_apr_pool_create_ex(&pool, NULL, NULL, NULL) != APR_SUCCESS) { p_apr_terminate(); dlclose(library); return 1; }
    svn_string_t inputs[3] = {{0}}; int count = argc - 3, result = 1;
    for (int i = 0; i < count; ++i) if (!read_input(argv[i + 3], &inputs[i])) { fprintf(stderr, "Invalid merge engine input.\n"); goto cleanup; }
    svn_diff_file_options_t *options = p_svn_diff_file_options_create(pool);
    options->ignore_space = svn_diff_file_ignore_space_none; options->ignore_eol_style = FALSE;
    svn_diff_t *diff = NULL;
    svn_error_t *error = count == 2 ? p_svn_diff_mem_string_diff(&diff, &inputs[0], &inputs[1], options, pool)
        : p_svn_diff_mem_string_diff3(&diff, &inputs[0], &inputs[1], &inputs[2], options, pool);
    if (!error) {
        const svn_diff_output_fns_t callbacks = {common, modified, latest, same_change, conflict};
        printf("svn-diff\t1\t%d\n", count);
        error = p_svn_diff_output2(diff, NULL, &callbacks, NULL, NULL);
    }
    if (error) { fprintf(stderr, "Subversion diff failed (%ld).\n", (long)error->apr_err); p_svn_error_clear(error); }
    else if (!failed && !ferror(stdout)) result = 0;
cleanup:
    for (int i = 0; i < 3; ++i) free((void *)inputs[i].data);
    p_apr_pool_destroy(pool); p_apr_terminate(); dlclose(library); return result;
}
