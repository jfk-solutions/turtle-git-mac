// SPDX-License-Identifier: GPL-2.0-or-later
#include "include/TurtleGitSMTP.h"
#include <curl/curl.h>
#include <pthread.h>
#include <string.h>
#include <stdint.h>

static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static CURLcode initialization_result = CURLE_FAILED_INIT;
static void initialize(void) { initialization_result = curl_global_init(CURL_GLOBAL_DEFAULT); }
struct Upload {
    const unsigned char *payload;
    size_t length, offset;
    TGSMTPProgress progress;
    void *context;
};
static size_t read_payload(char *buffer, size_t size, size_t count, void *opaque) {
    struct Upload *upload = opaque;
    if (upload->progress && upload->progress(upload->context, upload->offset, upload->length)) return CURL_READFUNC_ABORT;
    if (size && count > SIZE_MAX / size) return CURL_READFUNC_ABORT;
    size_t room = size * count, remaining = upload->length - upload->offset;
    size_t copied = room < remaining ? room : remaining;
    if (copied) memcpy(buffer, upload->payload + upload->offset, copied);
    upload->offset += copied;
    return copied;
}
static int report_progress(void *opaque, curl_off_t total_down, curl_off_t down, curl_off_t total_up, curl_off_t up) {
    (void)total_down; (void)down;
    struct Upload *upload = opaque;
    return upload->progress ? upload->progress(upload->context, up > 0 ? (uint64_t)up : 0, total_up > 0 ? (uint64_t)total_up : upload->length) : 0;
}
static size_t discard_output(char *bytes, size_t size, size_t count, void *opaque) {
    (void)bytes; (void)opaque;
    return size && count > SIZE_MAX / size ? 0 : size * count;
}
int tg_smtp_send(const char *url, int encryption, const char *sender,
                 const char *const *recipients, size_t recipient_count,
                 const unsigned char *payload, size_t payload_length,
                 const char *login, const char *password, const char *ca_file,
                 long connect_timeout_ms, long timeout_ms,
                 TGSMTPProgress progress, void *context, long *response, int *possibly_submitted) {
    if (response) *response = 0;
    if (possibly_submitted) *possibly_submitted = 0;
    if (!url || !sender || !recipients || !recipient_count || !payload || !payload_length || encryption < 0 || encryption > 2) return CURLE_BAD_FUNCTION_ARGUMENT;
    pthread_once(&initialization, initialize);
    if (initialization_result != CURLE_OK) return initialization_result;
    CURL *curl = curl_easy_init();
    if (!curl) return CURLE_FAILED_INIT;
    CURLcode result = CURLE_OK;
    struct curl_slist *addresses = NULL;
    struct Upload upload = { payload, payload_length, 0, progress, context };
    for (size_t i = 0; i < recipient_count; ++i) {
        struct curl_slist *next = curl_slist_append(addresses, recipients[i]);
        if (!next) { result = CURLE_OUT_OF_MEMORY; goto finish; }
        addresses = next;
    }
#define SET(option, value) do { result = curl_easy_setopt(curl, option, value); if (result != CURLE_OK) goto finish; } while (0)
    SET(CURLOPT_URL, url);
    /* Keep the pre-7.85 option for macOS 13's system library compatibility. */
    SET(CURLOPT_PROTOCOLS, (long)(CURLPROTO_SMTP | CURLPROTO_SMTPS));
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT_MS, connect_timeout_ms);
    SET(CURLOPT_TIMEOUT_MS, timeout_ms);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_USE_SSL, (long)(encryption == 1 ? CURLUSESSL_ALL : encryption == 0 ? CURLUSESSL_TRY : CURLUSESSL_NONE));
    if (ca_file) SET(CURLOPT_CAINFO, ca_file);
    if (login) { SET(CURLOPT_LOGIN_OPTIONS, "AUTH=LOGIN"); SET(CURLOPT_USERNAME, login); SET(CURLOPT_PASSWORD, password ? password : ""); }
    SET(CURLOPT_MAIL_FROM, sender);
    SET(CURLOPT_MAIL_RCPT, addresses);
    SET(CURLOPT_READFUNCTION, read_payload);
    SET(CURLOPT_READDATA, &upload);
    SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)payload_length);
    SET(CURLOPT_UPLOAD, 1L);
    SET(CURLOPT_WRITEFUNCTION, discard_output);
    SET(CURLOPT_WRITEDATA, NULL);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_XFERINFOFUNCTION, report_progress);
    SET(CURLOPT_XFERINFODATA, &upload);
    SET(CURLOPT_VERBOSE, 0L);
    result = curl_easy_perform(curl);
    if (response) curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, response);
    /* A lost final reply may conceal acceptance. Never auto-retry such failures. */
    if (possibly_submitted) *possibly_submitted = upload.offset == upload.length;
finish:
    curl_slist_free_all(addresses);
    curl_easy_cleanup(curl);
    return (int)result;
#undef SET
}
