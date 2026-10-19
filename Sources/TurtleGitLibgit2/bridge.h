// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TURTLEGIT_LIBGIT2_BRIDGE_H
#define TURTLEGIT_LIBGIT2_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef int (*tg_cancel_cb)(void *);
typedef void (*tg_output_cb)(const char *,size_t,void *);
typedef int (*tg_credentials_cb)(const char *,const char *,unsigned int,char **,char **,void *);
typedef int (*tg_certificate_cb)(const char *,const unsigned char *,size_t,int,void *);
typedef int (*tg_http_cb)(const char *,const char *,char ***,size_t *,char **,void *);
typedef void (*tg_url_cb)(const char *,void *);
typedef struct {tg_cancel_cb cancelled;tg_output_cb output;tg_output_cb result;tg_credentials_cb credentials;tg_certificate_cb certificate;tg_url_cb url;tg_http_cb http;void *payload;int verbose;const char *const *config_values;size_t config_count;int force_fetch;} tg_callbacks;
int tg_git_init(void);
void tg_git_shutdown(void);
const char *tg_git_version(void);
const char *tg_git_error(void);
int tg_clone(const char *source,const char *destination,int bare,int no_checkout,int recursive,const char *branch,const char *origin,int depth,const char *ssh_command,tg_callbacks *callbacks);
int tg_fetch(const char *repository,const char *remote,const char *const *refspecs,size_t count,int all_remotes,int tags,int prune,int depth,tg_callbacks *callbacks);
int tg_list_remote(const char *repository,const char *remote,int refs_only,int tags_only,int heads_only,tg_callbacks *callbacks);
int tg_delete_remote(const char *repository,const char *remote,const char *const *refspecs,size_t count,tg_callbacks *callbacks);
#endif
