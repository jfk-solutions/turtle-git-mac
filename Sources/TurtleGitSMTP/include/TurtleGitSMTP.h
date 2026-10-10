// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TURTLEGIT_SMTP_H
#define TURTLEGIT_SMTP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int (*TGSMTPProgress)(void *context, uint64_t uploaded, uint64_t total);
/* encryption: 0 optional STARTTLS (upstream None), 1 mandatory STARTTLS, 2 implicit TLS.
 * No protocol transcript or credential contents are returned or logged.
 * All pointers remain caller-owned for this synchronous call. */
int tg_smtp_send(const char *url, int encryption, const char *sender,
                 const char *const *recipients, size_t recipient_count,
                 const unsigned char *payload, size_t payload_length,
                 const char *login, const char *password, const char *ca_file,
                 long connect_timeout_ms, long timeout_ms,
                 TGSMTPProgress progress, void *context,
                 long *response, int *possibly_submitted);
/* MX lookup uses the system DNS-SD daemon; no SMTP connection is made.
 * Records preserve response order. hostname "." represents a null MX.
 * Local results: -70001 malformed/invalid, -70002 timeout, -70003 cancelled,
 * -70004 capacity exceeded. Other failures are DNSServiceErrorType values. */
typedef struct { uint16_t preference; char hostname[256]; } TGSMTPMXRecord;
int tg_smtp_decode_mx(const unsigned char *bytes, size_t length, TGSMTPMXRecord *record);
int tg_smtp_lookup_mx(const char *domain, long timeout_ms, TGSMTPProgress cancelled,
                      void *context, TGSMTPMXRecord *records, size_t capacity, size_t *count);
#ifdef __cplusplus
}
#endif
#endif
