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
typedef int (*tg_filter_cb)(const char *,const char *,const char *,const char *,const unsigned char *,size_t,unsigned char **,size_t *,void *);
typedef void (*tg_added_cb)(const char *,void *);
typedef void (*tg_reference_cb)(const char *,const char *,const char *,const char *,int,size_t,void *);
typedef void (*tg_checkout_cb)(const char *,const char *,size_t,size_t,void *);
typedef int (*tg_reset_file_cb)(const char *,void *);
typedef void (*tg_reset_progress_cb)(size_t,size_t,void *);
typedef struct {const char *path;const char *old_path;const char *parent_hash;const char *old_hash;const char *new_hash;unsigned int parent_index,old_mode,new_mode;int status,binary,counts_known,is_directory;size_t additions,deletions;} tg_history_delta;
typedef int (*tg_history_header_cb)(const char *,const char *const *,size_t,void *);
typedef int (*tg_history_cb)(const tg_history_delta *,void *);
typedef void (*tg_url_cb)(const char *,void *);
typedef struct {const char *name,*oid,*symbolic_target,*object_type,*subject,*author_name,*author_email,*committer_name,*committer_email,*upstream;int64_t author_time,committer_time;int has_author,has_committer;} tg_local_reference;
typedef int (*tg_local_reference_cb)(const tg_local_reference *,void *);
typedef struct {int number;uint32_t mode;const char *oid;} tg_inspection_stage;
typedef struct {int kind,value;const char *path,*base;const tg_inspection_stage *stages;size_t stage_count;} tg_inspection;
typedef int (*tg_inspection_cb)(const tg_inspection *,void *);
typedef struct {int object_type;const char *oid,*tree;const char *const *parents;size_t parent_count;const char *encoding,*author_name,*author_email,*committer_name,*committer_email,*message;int64_t author_time,committer_time;int author_offset,committer_offset;} tg_single_commit;
typedef int (*tg_single_commit_cb)(const tg_single_commit *,void *);
typedef int (*tg_finder_cb)(const char *,int,int,int,void *);
typedef struct {tg_cancel_cb cancelled;tg_output_cb output;tg_output_cb result;tg_credentials_cb credentials;tg_certificate_cb certificate;tg_url_cb url;tg_http_cb http;void *payload;int verbose;const char *const *config_values;size_t config_count;int force_fetch;tg_filter_cb filter;tg_added_cb added;tg_reference_cb reference_updated;tg_checkout_cb checked_out;tg_reset_file_cb reset_file;tg_reset_progress_cb reset_progress;tg_history_cb history_delta;tg_history_header_cb history_header;tg_local_reference_cb local_reference;tg_inspection_cb inspection;tg_single_commit_cb single_commit;tg_finder_cb finder_status;} tg_callbacks;
int tg_local_references(const char *repository,int scope,tg_callbacks *callbacks);
int tg_local_reference_names(const char *repository,tg_callbacks *callbacks);
int tg_containing_references(const char *repository,const char *oid,int tags,int local,int remote,tg_callbacks *callbacks);
int tg_delete_local_reference(const char *repository,const char *name,const char *expected_oid,const char *expected_symbolic_target,tg_callbacks *callbacks);
int tg_inspect_merge_base(const char *repository,const char *from,const char *to,tg_callbacks *callbacks);
int tg_inspect_clean(const char *repository,int staged_ok,tg_callbacks *callbacks);
int tg_inspect_conflicts(const char *repository,tg_callbacks *callbacks);
int tg_inspect_conflict_info(const char *repository,const char *const *paths,size_t count,tg_callbacks *callbacks);
int tg_read_single_commit(const char *repository,const char *revision,int allow_tree,tg_callbacks *callbacks);
int tg_finder_status(const char *repository,int full,int case_sensitive,uint32_t limit_kib,tg_callbacks *callbacks);
int tg_git_init(void);
void tg_git_shutdown(void);
const char *tg_git_version(void);
const char *tg_git_error(void);
int tg_clone(const char *source,const char *destination,int bare,int no_checkout,int recursive,const char *branch,const char *origin,int depth,const char *ssh_command,tg_callbacks *callbacks);
int tg_unified_diff(const char *repository,const char *old_revision,const char *new_revision,const char *const *paths,size_t count,int no_prefix,tg_callbacks *callbacks);
int tg_history_diff(const char *repository,const char *revision,int simple,unsigned int threshold,tg_callbacks *callbacks);
int tg_reset(const char *repository,const char *revision,int mode,tg_callbacks *callbacks);
int tg_revert(const char *repository,const char *revision,unsigned int mainline,tg_callbacks *callbacks);
int tg_fetch(const char *repository,const char *remote,const char *const *refspecs,size_t count,int all_remotes,int tags,int prune,int depth,tg_callbacks *callbacks);
int tg_list_remote(const char *repository,const char *remote,int refs_only,int tags_only,int heads_only,tg_callbacks *callbacks);
int tg_delete_remote(const char *repository,const char *remote,const char *const *refspecs,size_t count,tg_callbacks *callbacks);
int tg_materialize_blob(const char *repository,const char *oid,const char *path,tg_callbacks *callbacks);
int tg_run_filter(const char *command,const char *directory,int input,int output,int error,const char *const *environment,tg_callbacks *callbacks);
int tg_add(const char *repository,const char *private_index,int mode,int mode_only,const char *const *paths,size_t count,tg_callbacks *callbacks);
int tg_prepare_index(const char *repository,const char *private_index,const char *const *operations,const char *const *paths,const uint32_t *modes,size_t count,tg_callbacks *callbacks);
#endif
