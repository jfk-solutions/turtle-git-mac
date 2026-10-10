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

/* Direct mail's MX dependency, replacing Windows DnsQuery. */
#include <dns_sd.h>
#include <poll.h>
#include <time.h>
#include <errno.h>

int tg_smtp_decode_mx(const unsigned char *bytes, size_t length, TGSMTPMXRecord *record) {
    if (!bytes || !record || length < 3) return -70001;
    TGSMTPMXRecord decoded = {0};
    decoded.preference = (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
    size_t offset = 2, output = 0;
    while (offset < length) {
        unsigned size = bytes[offset++];
        if (!size) {
            if (offset != length || (output && output - 1 > 253)) return -70001;
            if (!output) decoded.hostname[output++] = '.';
            else --output; /* Remove the final label separator. */
            decoded.hostname[output] = 0; *record = decoded; return 0;
        }
        /* DNS-SD supplies standalone RDATA: compressed pointers have no packet
         * base here and cannot be followed. Never guess or read past this record. */
        if (size > 63 || size > length - offset || output + size + 1 >= sizeof(decoded.hostname)) return -70001;
        for (unsigned i = 0; i < size; ++i) {
            unsigned c = bytes[offset++];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return -70001;
            decoded.hostname[output++] = (char)c;
        }
        decoded.hostname[output++] = '.';
    }
    return -70001;
}
struct MXQuery { TGSMTPMXRecord *records; size_t capacity, count; int result, done; };
static void mx_reply(DNSServiceRef service, DNSServiceFlags flags, uint32_t interface_index,
                     DNSServiceErrorType error, const char *name, uint16_t type, uint16_t class_value,
                     uint16_t length, const void *data, uint32_t ttl, void *opaque) {
    (void)service; (void)interface_index; (void)name; (void)ttl;
    struct MXQuery *query = opaque;
    if (error) { query->result = error; query->done = 1; return; }
    if (type == kDNSServiceType_MX && class_value == kDNSServiceClass_IN && (flags & kDNSServiceFlagsAdd)) {
        TGSMTPMXRecord record;
        int code = tg_smtp_decode_mx(data, length, &record);
        if (code) { query->result = code; query->done = 1; return; }
        if (query->count == query->capacity) { query->result = -70004; query->done = 1; return; }
        query->records[query->count++] = record;
    }
    if (!(flags & kDNSServiceFlagsMoreComing)) query->done = 1;
}
static int64_t mx_milliseconds(void) {
    struct timespec time_value;
    if (clock_gettime(CLOCK_MONOTONIC, &time_value)) return -1;
    return (int64_t)time_value.tv_sec * 1000 + time_value.tv_nsec / 1000000;
}
int tg_smtp_lookup_mx(const char *domain, long timeout_ms, TGSMTPProgress cancelled,
                      void *context, TGSMTPMXRecord *records, size_t capacity, size_t *count) {
    if (count) *count = 0;
    if (!domain || !*domain || timeout_ms <= 0 || !records || !capacity || !count) return -70001;
    if (cancelled && cancelled(context, 0, 0)) return -70003;
    int64_t started = mx_milliseconds();
    if (started < 0) return -70001;
    struct MXQuery query = {records, capacity, 0, 0, 0};
    DNSServiceRef service = NULL;
    int code = DNSServiceQueryRecord(&service, kDNSServiceFlagsTimeout, kDNSServiceInterfaceIndexAny,
                                     domain, kDNSServiceType_MX, kDNSServiceClass_IN, mx_reply, &query);
    if (code) return code;
    int descriptor = DNSServiceRefSockFD(service);
    if (descriptor < 0) { DNSServiceRefDeallocate(service); return -70001; }
    while (!query.done) {
        if (cancelled && cancelled(context, 0, 0)) { query.result = -70003; break; }
        int64_t now = mx_milliseconds(), remaining = timeout_ms - (now - started);
        if (now < 0) { query.result = -70001; break; }
        if (remaining <= 0) { query.result = -70002; break; }
        struct pollfd descriptor_state = {descriptor, POLLIN, 0};
        int ready = poll(&descriptor_state, 1, (int)(remaining < 50 ? remaining : 50));
        if (ready < 0) { if (errno == EINTR) continue; query.result = -70001; break; }
        if (ready && (descriptor_state.revents & POLLIN)) {
            code = DNSServiceProcessResult(service);
            if (code) { query.result = code; break; }
        } else if (ready && descriptor_state.revents) { query.result = -70001; break; }
    }
    DNSServiceRefDeallocate(service);
    if (cancelled && cancelled(context, 0, 0)) query.result = -70003;
    if (!query.result) *count = query.count;
    return query.result;
}
