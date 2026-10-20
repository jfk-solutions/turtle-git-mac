// SPDX-License-Identifier: GPL-2.0-or-later
#include "bridge.h"
#include <git2.h>
#include <git2/sys/config.h>
#include <git2/sys/errors.h>
#include <git2/sys/repository.h>
#include <git2/sys/filter.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <dirent.h>

typedef struct {tg_callbacks *callbacks;const char *origin;const char *ssh_command;unsigned int received,indexed,completed;unsigned int recursion;const char *configuration_directory;unsigned int push_rejections;const char *private_index;const char *repository_path;git_repository *notification_repository;} context;
static int stopped(context *ctx);
static context *active_context;
static int register_smudge(void);
// Called only by our private static libgit2 HTTP request patch. Strings use
// malloc ownership and are released by the transport before the next request.
int turtlegit_http_configuration(const char *url,char ***headers,size_t *count,char **proxy){
 context *ctx=active_context;if(!ctx||stopped(ctx))return GIT_EUSER;
 if(!ctx->callbacks->http)return 0;
 int result=ctx->callbacks->http(url,ctx->configuration_directory,headers,count,proxy,ctx->callbacks->payload);
 if(result<0)git_error_set_str(GIT_ERROR_CONFIG,"Cannot read captured HTTP transport configuration");return result;
}
int tg_git_init(void){int result=git_libgit2_init();if(result>=0&&getenv("GIT_CONFIG_GLOBAL")){int options=git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH,GIT_CONFIG_LEVEL_XDG,"");if(options<0)return options;}if(result>=0)result=register_smudge();return result;}
void tg_git_shutdown(void){git_filter_unregister("turtlegit-smudge");git_libgit2_shutdown();}
const char *tg_git_version(void){return LIBGIT2_VERSION;}
const char *tg_git_error(void){const git_error *error=git_error_last();return error&&error->message?error->message:"libgit2 operation failed";}
static int stopped(context *ctx){return ctx->callbacks->cancelled&&ctx->callbacks->cancelled(ctx->callbacks->payload);}
static void emit(context *ctx,const char *text){if(ctx->callbacks->output)ctx->callbacks->output(text,strlen(text),ctx->callbacks->payload);}
static int sideband(const char *text,int length,void *payload){context *ctx=payload;if(stopped(ctx))return GIT_EUSER;if(ctx->callbacks->output)ctx->callbacks->output(text,(size_t)length,ctx->callbacks->payload);return 0;}
static int transfer(const git_indexer_progress *progress,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;char line[180];
 if(progress->total_objects){unsigned int percent=100u*progress->received_objects/progress->total_objects;if(percent!=ctx->received){ctx->received=percent;snprintf(line,sizeof(line),"Receiving objects: %u%% (%u/%u), %zu bytes\r",percent,progress->received_objects,progress->total_objects,progress->received_bytes);emit(ctx,line);}}
 if(progress->total_deltas){unsigned int percent=100u*progress->indexed_deltas/progress->total_deltas;if(percent!=ctx->indexed){ctx->indexed=percent;snprintf(line,sizeof(line),"Resolving deltas: %u%% (%u/%u)\r",percent,progress->indexed_deltas,progress->total_deltas);emit(ctx,line);}}
 return 0;
}
static void checkout_progress(const char *path,size_t completed,size_t total,void *payload){context *ctx=payload;if(stopped(ctx))return;if(path&&*path&&total&&ctx->callbacks->checked_out)ctx->callbacks->checked_out(ctx->repository_path?ctx->repository_path:"",path,completed,total,ctx->callbacks->payload);if(!total)return;unsigned int percent=(unsigned int)(completed*100/total);if(percent==ctx->completed)return;ctx->completed=percent;char line[160];snprintf(line,sizeof(line),"Updating files: %u%% (%zu/%zu)\r",percent,completed,total);emit(ctx,line);}
static int checkout_notify(git_checkout_notify_t why,const char *path,const git_diff_file *base,const git_diff_file *target,const git_diff_file *work,void *payload){(void)why;(void)path;(void)base;(void)target;(void)work;return stopped(payload)?GIT_EUSER:0;}
static int credentials(git_credential **out,const char *url,const char *username,unsigned int allowed,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;
 if(!(allowed&(GIT_CREDENTIAL_USERPASS_PLAINTEXT|GIT_CREDENTIAL_USERNAME))){git_error_set_str(GIT_ERROR_CALLBACK,"This transport credential type is not supported by the native helper");return GIT_EAUTH;}
 char *user=NULL,*password=NULL;int result=ctx->callbacks->credentials?ctx->callbacks->credentials(url,username,allowed,&user,&password,ctx->callbacks->payload):-1;
 if(result==0&&user){if(allowed&GIT_CREDENTIAL_USERPASS_PLAINTEXT)result=git_credential_userpass_plaintext_new(out,user,password?password:"");else result=git_credential_username_new(out,user);}else result=GIT_EAUTH;
 if(password){memset(password,0,strlen(password));free(password);}free(user);if(result<0)git_error_set_str(GIT_ERROR_CALLBACK,"Native authentication was rejected, cancelled, or unavailable");return result;
}
static int certificate(git_cert *cert,int valid,const char *authority,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;
 if(!cert||cert->cert_type!=GIT_CERT_X509||!ctx->callbacks->certificate){if(valid)return 0;git_error_set_str(GIT_ERROR_SSL,"Unsupported or rejected certificate");return GIT_ECERTIFICATE;}
 git_cert_x509 *x509=(git_cert_x509 *)cert;
 if(ctx->callbacks->certificate(authority,x509->data,x509->len,valid,ctx->callbacks->payload)==0&&!stopped(ctx))return 0;
 git_error_set_str(GIT_ERROR_SSL,"Certificate was rejected or cancelled");return GIT_ECERTIFICATE;
}
static int remote_ready(git_remote *remote,int direction,void *payload){context *ctx=payload;if(stopped(ctx))return GIT_EUSER;ctx->notification_repository=git_remote_owner(remote);const char *url=direction==GIT_DIRECTION_PUSH?git_remote_pushurl(remote):NULL;if(!url)url=git_remote_url(remote);if(ctx->callbacks->url)ctx->callbacks->url(url,ctx->callbacks->payload);return 0;}
static int tips(const char *name,const git_oid *old,const git_oid *new,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;char line[1024],a[GIT_OID_MAX_HEXSIZE+1],b[GIT_OID_MAX_HEXSIZE+1];git_oid_tostr(a,sizeof(a),old);git_oid_tostr(b,sizeof(b),new);
 if(!ctx->callbacks->reference_updated){snprintf(line,sizeof(line)," %.*s..%.*s %s\n",8,a,8,b,name);emit(ctx,line);return 0;}
 int change=0;size_t count=0;
 if(!git_oid_is_zero(old)&&!git_oid_is_zero(new)){
  if(git_oid_equal(old,new))change=1;
  else if(ctx->notification_repository){size_t ahead=0,behind=0;
   if(git_graph_ahead_behind(&ahead,&behind,ctx->notification_repository,new,old)==0){
    if(ahead>0&&behind==0){change=4;count=ahead;}
    else if(ahead==0&&behind>0){change=5;count=behind;}
    else {git_commit *old_commit=NULL,*new_commit=NULL;git_time_t old_time=0,new_time=0;
     if(git_commit_lookup(&old_commit,ctx->notification_repository,old)==0)old_time=git_commit_committer(old_commit)->when.time;
     if(git_commit_lookup(&new_commit,ctx->notification_repository,new)==0)new_time=git_commit_committer(new_commit)->when.time;
     change=old_time<new_time?6:old_time>new_time?7:8;git_commit_free(old_commit);git_commit_free(new_commit);
    }
   }
  }
 }else if(!git_oid_is_zero(old))change=3;else if(!git_oid_is_zero(new))change=2;
 if(ctx->callbacks->reference_updated)ctx->callbacks->reference_updated(ctx->repository_path?ctx->repository_path:"",name,a,b,change,count,ctx->callbacks->payload);
 return 0;
}
static void remote_callbacks(git_remote_callbacks *options,context *ctx){git_remote_init_callbacks(options,GIT_REMOTE_CALLBACKS_VERSION);options->sideband_progress=sideband;options->transfer_progress=transfer;options->credentials=credentials;options->certificate_check=certificate;options->remote_ready=remote_ready;options->update_tips=tips;options->payload=ctx;}
static void checkout_options(git_checkout_options *options,context *ctx){options->progress_cb=checkout_progress;options->progress_payload=ctx;options->notify_cb=checkout_notify;options->notify_payload=ctx;options->notify_flags=GIT_CHECKOUT_NOTIFY_ALL;}
// APP-level command configuration is read-only: libgit2 writes still target
// repository config. Never persist transient -c or counted environment options.
static int configure_repository(git_repository *repository,context *ctx){
 ctx->notification_repository=repository;
 ctx->configuration_directory=git_repository_workdir(repository);if(!ctx->configuration_directory)ctx->configuration_directory=git_repository_path(repository);if(!ctx->callbacks->config_count)return 0;git_config *config=NULL;git_config_backend *backend=NULL;
 int result=git_repository_config(&config,repository);if(result<0)return result;
 git_config_backend_memory_options options=GIT_CONFIG_BACKEND_MEMORY_OPTIONS_INIT;options.backend_type="command line";
 result=git_config_backend_from_values(&backend,(const char **)ctx->callbacks->config_values,ctx->callbacks->config_count,&options);
 if(result==0){backend->readonly=1;result=git_config_add_backend(config,backend,GIT_CONFIG_LEVEL_APP,repository,1);if(result<0)backend->free(backend);}
 git_config_free(config);return result;
}
static int create_repository(git_repository **out,const char *path,int bare,void *payload){context *ctx=payload;if(stopped(ctx))return GIT_EUSER;git_repository_init_options init=GIT_REPOSITORY_INIT_OPTIONS_INIT;init.flags=GIT_REPOSITORY_INIT_MKPATH|GIT_REPOSITORY_INIT_EXTERNAL_TEMPLATE|(bare?GIT_REPOSITORY_INIT_BARE:0);init.template_path=getenv("GIT_TEMPLATE_DIR");int result=git_repository_init_ext(out,path,&init);if(result<0)return result;if(ctx->ssh_command){git_config *config=NULL;if((result=git_repository_config(&config,*out))==0){result=git_config_set_string(config,"core.sshCommand",ctx->ssh_command);git_config_free(config);}}if(result==0)result=configure_repository(*out,ctx);return result;}
static int create_remote(git_remote **out,git_repository *repository,const char *name,const char *url,void *payload){(void)name;context *ctx=payload;return git_remote_create(out,repository,ctx->origin?ctx->origin:"origin",url);}
static int recursive_update(git_repository *,context *);
static int update_submodule(git_submodule *submodule,const char *name,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;char line[1024];snprintf(line,sizeof(line),"Submodule '%s'\n",name);emit(ctx,line);
 const char *previous=ctx->configuration_directory,*previous_path=ctx->repository_path;git_repository *previous_repository=ctx->notification_repository,*prepared=NULL,*child=NULL;
 const char *relative=git_submodule_path(submodule);size_t parent_length=previous_path?strlen(previous_path):0,path_length=relative?strlen(relative):0;char *path=malloc(parent_length+path_length+2);if(!path)return -1;
 if(parent_length)snprintf(path,parent_length+path_length+2,"%s/%s",previous_path,relative?relative:"");else snprintf(path,path_length+2,"%s",relative?relative:"");ctx->repository_path=path;
 int result=git_submodule_init(submodule,0);
 if(result<0)goto done;if((result=git_submodule_repo_init(&prepared,submodule,1))<0)goto done;
 if((result=configure_repository(prepared,ctx))<0)goto done;
 git_submodule_update_options options=GIT_SUBMODULE_UPDATE_OPTIONS_INIT;remote_callbacks(&options.fetch_opts.callbacks,ctx);options.fetch_opts.proxy_opts.type=GIT_PROXY_AUTO;options.fetch_opts.proxy_opts.credentials=credentials;options.fetch_opts.proxy_opts.certificate_check=certificate;options.fetch_opts.proxy_opts.payload=ctx;checkout_options(&options.checkout_opts,ctx);
 if((result=git_submodule_update(submodule,1,&options))<0)goto done;ctx->notification_repository=prepared;
 if((result=git_submodule_open(&child,submodule))<0)goto done;result=recursive_update(child,ctx);
 done:ctx->configuration_directory=previous;ctx->repository_path=previous_path;ctx->notification_repository=previous_repository;git_repository_free(child);git_repository_free(prepared);free(path);return result;
}
static int recursive_update(git_repository *repository,context *ctx){
 if(ctx->recursion>=64){git_error_set_str(GIT_ERROR_SUBMODULE,"Submodule recursion limit exceeded");return -1;}
 const char *previous=ctx->configuration_directory;git_repository *previous_repository=ctx->notification_repository;ctx->recursion++;int result=configure_repository(repository,ctx);if(result==0)result=git_submodule_foreach(repository,update_submodule,ctx);ctx->recursion--;ctx->configuration_directory=previous;ctx->notification_repository=previous_repository;return result;
}
// Pinned libgit2 creates the chosen remote correctly but hardcodes "origin"
// when writing the checked-out/unborn branch's tracking configuration.
static int configure_clone_tracking(git_repository *repository,const char *origin,int bare){
 if(bare||!origin||!strcmp(origin,"origin"))return 0;
 git_reference *head=NULL;git_config *config=NULL;int result=git_reference_lookup(&head,repository,"HEAD");if(result<0)return result;
 const char *target=git_reference_symbolic_target(head);
 if(target&&!strncmp(target,"refs/heads/",11)){
  const char *branch=target+11;size_t length=strlen(branch)+32;char *key=malloc(length);
  if(!key){git_reference_free(head);return -1;}
  snprintf(key,length,"branch.%s.remote",branch);result=git_repository_config(&config,repository);
  if(result==0)result=git_config_set_string(config,key,origin);git_config_free(config);free(key);
 }
 git_reference_free(head);return result;
}
int tg_clone(const char *source,const char *destination,int bare,int no_checkout,int recursive,const char *branch,const char *origin,int depth,const char *ssh_command,tg_callbacks *callbacks){
 context ctx={callbacks,origin,ssh_command,UINT_MAX,UINT_MAX,UINT_MAX};git_clone_options options=GIT_CLONE_OPTIONS_INIT;options.bare=bare;if(depth>0)options.local=GIT_CLONE_NO_LOCAL;options.checkout_branch=branch;options.fetch_opts.depth=depth;options.fetch_opts.proxy_opts.type=GIT_PROXY_AUTO;options.fetch_opts.proxy_opts.credentials=credentials;options.fetch_opts.proxy_opts.certificate_check=certificate;options.fetch_opts.proxy_opts.payload=&ctx;options.repository_cb=create_repository;options.repository_cb_payload=&ctx;options.remote_cb=create_remote;options.remote_cb_payload=&ctx;remote_callbacks(&options.fetch_opts.callbacks,&ctx);checkout_options(&options.checkout_opts,&ctx);if(no_checkout||bare)options.checkout_opts.checkout_strategy=GIT_CHECKOUT_NONE;
 active_context=&ctx;git_repository *repository=NULL;int result=git_clone(&repository,source,destination,&options);if(result==0)result=configure_clone_tracking(repository,origin,bare);if(result==0&&recursive&&!bare&&!no_checkout)result=recursive_update(repository,&ctx);git_repository_free(repository);active_context=NULL;emit(&ctx,"\n");return result;
}
static int fetch_one(git_repository *repository,const char *name,const char *const *refspecs,size_t count,int tags,int prune,int depth,context *ctx){
 if(stopped(ctx))return GIT_EUSER;git_remote *remote=NULL;int valid_name=0;int result=git_remote_name_is_valid(&valid_name,name);if(result<0)return result;if(valid_name){result=git_remote_lookup(&remote,repository,name);if(result==GIT_ENOTFOUND)result=git_remote_create_anonymous(&remote,repository,name);}else result=git_remote_create_anonymous(&remote,repository,name);if(result<0)return result;
 git_fetch_options options=GIT_FETCH_OPTIONS_INIT;remote_callbacks(&options.callbacks,ctx);options.depth=depth;options.proxy_opts.type=GIT_PROXY_AUTO;options.proxy_opts.credentials=credentials;options.proxy_opts.certificate_check=certificate;options.proxy_opts.payload=ctx;options.update_fetchhead=GIT_REMOTE_UPDATE_FETCHHEAD|(ctx->callbacks->reference_updated?GIT_REMOTE_UPDATE_REPORT_UNCHANGED:0);options.download_tags=(git_remote_autotag_option_t)tags;options.prune=(git_fetch_prune_t)prune;git_strarray specs={(char **)refspecs,count};
 char line[1024];snprintf(line,sizeof(line),"Fetching %s\n",git_remote_name(remote)?git_remote_name(remote):"remote repository");emit(ctx,line);ctx->received=ctx->indexed=UINT_MAX;
 git_strarray forced={0};
 if(ctx->callbacks->force_fetch){
  git_strarray configured={0};if(!count){result=git_remote_get_fetch_refspecs(&configured,remote);if(result<0){git_remote_free(remote);return result;}specs=configured;}
  forced.count=specs.count;forced.strings=calloc(forced.count?forced.count:1,sizeof(char*));if(!forced.strings){git_strarray_dispose(&configured);git_remote_free(remote);return -1;}
  for(size_t i=0;i<forced.count;i++){const char *value=specs.strings[i];size_t length=strlen(value);forced.strings[i]=malloc(length+2);if(!forced.strings[i]){git_strarray_dispose(&forced);git_strarray_dispose(&configured);git_remote_free(remote);return -1;}if(value[0]=='+'||value[0]=='^')memcpy(forced.strings[i],value,length+1);else{forced.strings[i][0]='+';memcpy(forced.strings[i]+1,value,length+1);}}
  git_strarray_dispose(&configured);result=git_remote_fetch(remote,forced.count?&forced:NULL,&options,NULL);git_strarray_dispose(&forced);
 }else result=git_remote_fetch(remote,count?&specs:NULL,&options,NULL);git_remote_free(remote);emit(ctx,"\n");return result;
}
int tg_fetch(const char *path,const char *remote,const char *const *refspecs,size_t count,int all_remotes,int tags,int prune,int depth,tg_callbacks *callbacks){
 git_repository *repository=NULL;int result=git_repository_open_ext(&repository,path,0,NULL);if(result<0)return result;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};result=configure_repository(repository,&ctx);if(result<0){git_repository_free(repository);return result;}
 active_context=&ctx;if(all_remotes){git_strarray names={0};result=git_remote_list(&names,repository);for(size_t i=0;result==0&&i<names.count;i++){git_config *config=NULL;char key[1024];int skip=0;if(git_repository_config_snapshot(&config,repository)==0){snprintf(key,sizeof(key),"remote.%s.skipFetchAll",names.strings[i]);if(git_config_get_bool(&skip,config,key)==GIT_ENOTFOUND){snprintf(key,sizeof(key),"remote.%s.skipDefaultUpdate",names.strings[i]);(void)git_config_get_bool(&skip,config,key);}git_config_free(config);}if(!skip)result=fetch_one(repository,names.strings[i],NULL,0,tags,prune,depth,&ctx);}git_strarray_dispose(&names);}
 else result=fetch_one(repository,remote,refspecs,count,tags,prune,depth,&ctx);
 git_repository_free(repository);active_context=NULL;return result;
}

// Listing may be requested by Clone before a filesystem repository exists.
// This repository/config object stays entirely in memory; no init or config
// writes are performed on the selected working directory.
static int open_listing_repository(git_repository **out,const char *path){
 int result=git_repository_open_ext(out,path,0,NULL);if(result!=GIT_ENOTFOUND)return result;
 git_error_clear();git_config *config=NULL;result=git_repository_new(out);if(result<0)return result;
 result=git_config_open_default(&config);if(result==0)result=git_repository_set_config(*out,config);git_config_free(config);
 if(result<0){git_repository_free(*out);*out=NULL;}return result;
}
static int lookup_remote(git_remote **out,git_repository *repository,const char *name){
 int valid=0,result=git_remote_name_is_valid(&valid,name);if(result<0)return result;
 if(valid){result=git_remote_lookup(out,repository,name);if(result!=GIT_ENOTFOUND)return result;}
 return git_remote_create_anonymous(out,repository,name);
}
static void configure_proxy(git_proxy_options *options,context *ctx){
 options->type=GIT_PROXY_AUTO;options->credentials=credentials;options->certificate_check=certificate;options->payload=ctx;
}
static int valid_advertisement(const char *name){
 if(!strcmp(name,"HEAD"))return 1;
 size_t length=strlen(name);int peeled=length>=3&&!strcmp(name+length-3,"^{}");int valid=0;
 if(peeled){char *base=malloc(length-2);if(!base)return 0;memcpy(base,name,length-3);base[length-3]='\0';int result=git_reference_name_is_valid(&valid,base);free(base);return result==0&&valid;}
 return git_reference_name_is_valid(&valid,name)==0&&valid;
}
int tg_list_remote(const char *path,const char *name,int refs_only,int tags_only,int heads_only,tg_callbacks *callbacks){
 git_repository *repository=NULL;git_remote *remote=NULL;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 int result=open_listing_repository(&repository,path);if(result<0)return result;
 result=configure_repository(repository,&ctx);if(!ctx.configuration_directory)ctx.configuration_directory=path;
 if(result==0)result=lookup_remote(&remote,repository,name);
 active_context=&ctx;
 git_remote_connect_options options=GIT_REMOTE_CONNECT_OPTIONS_INIT;remote_callbacks(&options.callbacks,&ctx);configure_proxy(&options.proxy_opts,&ctx);
 if(result==0&&!stopped(&ctx))result=git_remote_connect_ext(remote,GIT_DIRECTION_FETCH,&options);
 const git_remote_head **heads=NULL;size_t count=0;
 if(result==0)result=git_remote_ls(&heads,&count,remote);
 for(size_t i=0;result==0&&i<count;i++){
  if(stopped(&ctx)){result=GIT_EUSER;break;}
  const char *reference=heads[i]->name;size_t length=strlen(reference);int peeled=length>=3&&!strcmp(reference+length-3,"^{}");
  if(refs_only&&(strncmp(reference,"refs/",5)||peeled))continue;
  if((tags_only||heads_only)&&!((tags_only&&!strncmp(reference,"refs/tags/",10))||(heads_only&&!strncmp(reference,"refs/heads/",11))))continue;
  if(!valid_advertisement(reference)){git_error_set_str(GIT_ERROR_REFERENCE,"The remote advertised an invalid reference name");result=-1;break;}
  char oid[GIT_OID_MAX_HEXSIZE+1];git_oid_tostr(oid,sizeof(oid),&heads[i]->oid);
  if(callbacks->result){callbacks->result(oid,strlen(oid),callbacks->payload);callbacks->result("\t",1,callbacks->payload);callbacks->result(reference,length,callbacks->payload);callbacks->result("\n",1,callbacks->payload);}
 }
 if(remote)git_remote_disconnect(remote);git_remote_free(remote);git_repository_free(repository);active_context=NULL;
 return stopped(&ctx)?GIT_EUSER:result;
}
static int push_status(const char *reference,const char *status,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;
 if(status){ctx->push_rejections++;emit(ctx," ! [remote rejected] ");emit(ctx,reference);emit(ctx,": ");emit(ctx,status);emit(ctx,"\n");}
 else{emit(ctx," - [deleted] ");emit(ctx,reference);emit(ctx,"\n");}
 // A rejected ref must not prevent receipt of later successful/rejected rows.
 return 0;
}
static int deletion_negotiation(const git_push_update **updates,size_t count,void *payload){
 context *ctx=payload;if(stopped(ctx))return GIT_EUSER;
 for(size_t i=0;i<count;i++){
  int valid=0;const char *reference=updates[i]->dst_refname;
  if(!reference||strncmp(reference,"refs/",5)||git_reference_name_is_valid(&valid,reference)<0||!valid||!git_oid_is_zero(&updates[i]->dst)){
   git_error_set_str(GIT_ERROR_REFERENCE,"The optional helper only permits remote reference deletion");return -1;
  }
 }
 return 0;
}
int tg_delete_remote(const char *path,const char *name,const char *const *refspecs,size_t count,tg_callbacks *callbacks){
 // Validate every requested operation before opening any transport. There is
 // deliberately no configured-refspec or normal-push fallback.
 if(!count||count>4096){git_error_set_str(GIT_ERROR_REFERENCE,"Explicit deletion refspecs are required");return -1;}
 for(size_t i=0;i<count;i++){
  const char *spec=refspecs[i];int valid=0;
  if(strncmp(spec,":refs/",6)||git_reference_name_is_valid(&valid,spec+1)<0||!valid){git_error_set_str(GIT_ERROR_REFERENCE,"Invalid remote deletion refspec");return -1;}
 }
 git_repository *repository=NULL;git_remote *remote=NULL;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 int result=git_repository_open_ext(&repository,path,0,NULL);if(result<0)return result;
 result=configure_repository(repository,&ctx);if(result==0)result=lookup_remote(&remote,repository,name);
 active_context=&ctx;git_push_options options=GIT_PUSH_OPTIONS_INIT;remote_callbacks(&options.callbacks,&ctx);configure_proxy(&options.proxy_opts,&ctx);
 options.callbacks.push_update_reference=push_status;options.callbacks.push_negotiation=deletion_negotiation;
 git_strarray specs={(char **)refspecs,count};
 if(result==0&&!stopped(&ctx))result=git_remote_push(remote,&specs,&options);
 if(result==0&&ctx.push_rejections){git_error_set_str(GIT_ERROR_REFERENCE,"The remote rejected one or more reference deletions");result=-1;}
 if(remote)git_remote_disconnect(remote);git_remote_free(remote);git_repository_free(repository);active_context=NULL;
 return stopped(&ctx)?GIT_EUSER:result;
}

// Custom smudge semantics adapted from TortoiseGit src/libgit2/filter-filter.c.
// Copyright (C) 2014, 2016-2021, 2023, 2026 TortoiseGit; GPL-2.0-or-later.
// Registered once for helper checkout and historical materialization. The
// actual filter source repository supplies cwd, including nested submodules.
static int smudge_check(git_filter *self,void **payload,const git_filter_source *src,const char **values){
 (void)self;(void)src;if(!values||!values[0]||GIT_ATTR_IS_TRUE(values[0])||GIT_ATTR_IS_FALSE(values[0])||GIT_ATTR_IS_UNSPECIFIED(values[0]))return GIT_PASSTHROUGH;
 *payload=strdup(values[0]);return *payload?0:-1;
}
static void smudge_cleanup(git_filter *self,void *payload){(void)self;free(payload);}
static int smudge_apply(git_filter *self,void **payload,git_buf *to,const git_buf *from,const git_filter_source *src){
 (void)self;context *ctx=active_context;if(!ctx||stopped(ctx))return GIT_EUSER;
 const char *previous=ctx->configuration_directory;git_repository *repository=git_filter_source_repo(src);
 git_config *config=NULL;git_buf command=GIT_BUF_INIT;int required=0,result;char *key=NULL;unsigned char *bytes=NULL;size_t length=0;
 if((result=configure_repository(repository,ctx))<0){ctx->configuration_directory=previous;return result;}
 if((result=git_repository_config_snapshot(&config,repository))<0){ctx->configuration_directory=previous;return result;}
 size_t keysize=strlen((char *)*payload)+32;key=malloc(keysize);if(!key){result=-1;goto done;}
 snprintf(key,keysize,"filter.%s.required",(char *)*payload);result=git_config_get_bool(&required,config,key);if(result<0&&result!=GIT_ENOTFOUND)goto done;
 snprintf(key,keysize,"filter.%s.%s",(char *)*payload,git_filter_source_mode(src)==GIT_FILTER_TO_WORKTREE?"smudge":"clean");result=git_config_get_string_buf(&command,config,key);
 if(result==GIT_ENOTFOUND){if(required){git_error_set_str(GIT_ERROR_FILTER,"Required external filter command is missing");result=-1;}else result=GIT_PASSTHROUGH;goto done;}if(result<0)goto done;
 result=ctx->callbacks->filter?ctx->callbacks->filter(command.ptr,git_filter_source_path(src),ctx->configuration_directory,git_filter_source_mode(src)==GIT_FILTER_TO_ODB?ctx->private_index:NULL,(const unsigned char *)from->ptr,from->size,&bytes,&length,ctx->callbacks->payload):-1;
 if(stopped(ctx)){result=GIT_EUSER;goto done;}
 if(result<0){if(required)git_error_set_str(GIT_ERROR_FILTER,"Required external filter failed");else result=GIT_PASSTHROUGH;goto done;}
 result=git_buf_set(to,bytes,length);
 done:ctx->configuration_directory=previous;free(bytes);free(key);git_buf_dispose(&command);git_config_free(config);return result;
}
static int register_smudge(void){
 static git_filter driver=GIT_FILTER_INIT;driver.attributes="filter";driver.check=smudge_check;driver.apply=smudge_apply;driver.cleanup=smudge_cleanup;
 return git_filter_register("turtlegit-smudge",&driver,GIT_FILTER_DRIVER_PRIORITY);
}
int tg_materialize_blob(const char *path,const char *oidtext,const char *filename,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};git_repository *repository=NULL;git_blob *blob=NULL;git_buf bytes=GIT_BUF_INIT;git_oid oid;int result;
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 if((result=git_repository_open(&repository,path))<0)goto done;if((result=configure_repository(repository,&ctx))<0)goto done;
 if((result=git_oid_fromstr(&oid,oidtext))<0)goto done;if((result=git_blob_lookup(&blob,repository,&oid))<0)goto done;
 git_blob_filter_options options=GIT_BLOB_FILTER_OPTIONS_INIT;options.flags&=~(uint32_t)GIT_BLOB_FILTER_CHECK_FOR_BINARY;
 result=git_blob_filter(&bytes,blob,filename,&options);if(result==0&&stopped(&ctx))result=GIT_EUSER;
 if(result==0&&callbacks->result)callbacks->result(bytes.ptr,bytes.size,callbacks->payload);
 done:git_buf_dispose(&bytes);git_blob_free(blob);git_repository_free(repository);active_context=NULL;return result;
}

// A private process group owns the shell and every filter descendant. File-backed
// streams avoid pipe deadlocks for simultaneous large input/output/stderr.
static int run_filter_process(const char *command,const char *directory,int input,int output,int error,const char *const *environment,tg_callbacks *callbacks){
 posix_spawn_file_actions_t actions;posix_spawnattr_t attributes;pid_t pid=0;int status=0,result;
 if(posix_spawn_file_actions_init(&actions)!=0)return -1;
 if(posix_spawnattr_init(&attributes)!=0){posix_spawn_file_actions_destroy(&actions);return -1;}
 result=posix_spawn_file_actions_addchdir_np(&actions,directory);
 if(!result)result=posix_spawn_file_actions_adddup2(&actions,input,STDIN_FILENO);
 if(!result)result=posix_spawn_file_actions_adddup2(&actions,output,STDOUT_FILENO);
 if(!result)result=posix_spawn_file_actions_adddup2(&actions,error,STDERR_FILENO);
 if(!result)result=posix_spawnattr_setpgroup(&attributes,0);
 if(!result)result=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_CLOEXEC_DEFAULT);
 char *argv[]={"/bin/sh","-c",(char *)command,NULL};
 if(!result)result=posix_spawn(&pid,"/bin/sh",&actions,&attributes,argv,(char *const *)environment);
 posix_spawnattr_destroy(&attributes);posix_spawn_file_actions_destroy(&actions);if(result)return -1;
 int cancelling=0,ticks=0;struct timespec pause={0,10000000};
 for(;;){pid_t waited=waitpid(pid,&status,WNOHANG);if(waited==pid)break;if(waited<0&&errno!=EINTR){kill(-pid,SIGKILL);while(waitpid(pid,&status,0)<0&&errno==EINTR){}return -1;}
  if(callbacks->cancelled&&callbacks->cancelled(callbacks->payload)){if(!cancelling){kill(-pid,SIGTERM);cancelling=1;}else if(++ticks>=20)kill(-pid,SIGKILL);}
  nanosleep(&pause,NULL);
 }
 // Disallow a shell filter leaving owned background workers after returning.
 kill(-pid,SIGKILL);return !cancelling&&WIFEXITED(status)&&WEXITSTATUS(status)==0?0:-1;
}

int tg_run_filter(const char *command,const char *directory,int input,int output,int error,const char *const *environment,tg_callbacks *callbacks){
 int lock=-1;const char *path=getenv("TURTLEGIT_LIBGIT2_FILTER_LOCK");
 if(path){
  struct stat info;lock=open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
  if(lock<0)return -1;
  if(fstat(lock,&info)<0||!S_ISREG(info.st_mode)||info.st_uid!=geteuid()||(info.st_mode&0777)!=0600){close(lock);return -1;}
  while(flock(lock,LOCK_EX|LOCK_NB)<0){if(errno!=EINTR&&errno!=EWOULDBLOCK){close(lock);return -1;}if(callbacks->cancelled&&callbacks->cancelled(callbacks->payload)){close(lock);return -1;}struct timespec pause={0,10000000};nanosleep(&pause,NULL);}
 }
 // Recheck after acquisition: Core publishes cancellation before taking locks.
 int result=-1;if(!callbacks->cancelled||!callbacks->cancelled(callbacks->payload))result=run_filter_process(command,directory,input,output,error,environment,callbacks);
 if(lock>=0){flock(lock,LOCK_UN);close(lock);}return result;
}

// AddProgressCommand uses explicit per-path adds and one final write. The
// supplied private index is attached directly; caller GIT_INDEX_FILE is ignored.
int tg_add(const char *path,const char *private_index,int mode,int mode_only,const char *const *paths,size_t count,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};ctx.private_index=private_index;
 git_repository *repository=NULL;git_index *index=NULL;git_buf actual=GIT_BUF_INIT;int result=-1,descriptor=-1;struct stat info,real_info;
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 descriptor=open(private_index,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 if(descriptor<0||fstat(descriptor,&info)<0||!S_ISREG(info.st_mode)||info.st_uid!=geteuid()||(info.st_mode&0777)!=0600||info.st_nlink!=1){git_error_set_str(GIT_ERROR_INDEX,"Private Add index must be an owned regular 0600 file");goto done;}
 if((result=git_repository_open(&repository,path))<0)goto done;
 if((result=git_repository_item_path(&actual,repository,GIT_REPOSITORY_ITEM_INDEX))<0)goto done;
 if(stat(actual.ptr,&real_info)==0&&info.st_dev==real_info.st_dev&&info.st_ino==real_info.st_ino){git_error_set_str(GIT_ERROR_INDEX,"Add must not write the live repository index");result=-1;goto done;}
 if((result=configure_repository(repository,&ctx))<0)goto done;
 if((result=git_index_open(&index,private_index))<0)goto done;
 if((result=git_repository_set_index(repository,index))<0)goto done;
 if((result=git_index_read(index,1))<0)goto done;
 for(size_t i=0;i<count;i++){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  if(mode_only){
   const git_index_entry *existing=git_index_get_bypath(index,paths[i],0);
   if(!existing){
    size_t position;if(git_index_find_prefix(&position,index,paths[i])==0){const git_index_entry *child=git_index_get_byindex(index,position);size_t length=strlen(paths[i]);if(child&&strlen(child->path)>length&&!strncmp(child->path,paths[i],length)&&child->path[length]=='/')continue;}
    git_error_set_str(GIT_ERROR_INDEX,"Could not update the staged file mode");result=-1;goto done;
   }
   if(existing->mode==GIT_FILEMODE_COMMIT)continue;
   git_index_entry entry=*existing;entry.mode=mode==1?GIT_FILEMODE_BLOB_EXECUTABLE:GIT_FILEMODE_LINK;
   if((result=git_index_add(index,&entry))<0)goto done;
  }else if((result=git_index_add_bypath(index,paths[i]))<0)goto done;
  if(mode&&!mode_only){
   const char *workdir=git_repository_workdir(repository);size_t length=(workdir?strlen(workdir):0)+strlen(paths[i])+2;char *location=malloc(length);
   if(!location){result=-1;goto done;}snprintf(location,length,"%s%s",workdir?workdir:"",paths[i]);struct stat disk;int found=lstat(location,&disk);free(location);
   if(found<0){git_error_set_str(GIT_ERROR_OS,"Cannot inspect Add file mode");result=-1;goto done;}
   if(!S_ISDIR(disk.st_mode)){
    const git_index_entry *existing=git_index_get_bypath(index,paths[i],0);if(!existing){git_error_set_str(GIT_ERROR_INDEX,"Added index entry is missing");result=-1;goto done;}
    git_index_entry entry=*existing;entry.mode=mode==1?GIT_FILEMODE_BLOB_EXECUTABLE:GIT_FILEMODE_LINK;
    if((result=git_index_add(index,&entry))<0)goto done;
   }
  }
  if(callbacks->added)callbacks->added(paths[i],callbacks->payload);
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 }
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 // Detect replacement of the reviewed private inode before committing it.
 struct stat current;if(lstat(private_index,&current)<0||!S_ISREG(current.st_mode)||current.st_dev!=info.st_dev||current.st_ino!=info.st_ino){git_error_set_str(GIT_ERROR_INDEX,"Private Add index changed during operation");result=-1;goto done;}
 result=git_index_write(index);
 if(result==0){
  int written=open(private_index,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat final;
  if(written<0||fstat(written,&final)<0||!S_ISREG(final.st_mode)||final.st_uid!=geteuid()||final.st_nlink!=1||fchmod(written,0600)<0){git_error_set_str(GIT_ERROR_INDEX,"Cannot preserve private Add index permissions");result=-1;}
  if(written>=0)close(written);
 }
 done:if(descriptor>=0)close(descriptor);git_buf_dispose(&actual);git_index_free(index);git_repository_free(repository);active_context=NULL;return result;
}

// CommitDlg checked-row preparation. Unchecked base entries are restored in the
// private copy by the caller; checked add/remove/rename operations settle here
// with the same external clean driver and one final private-index write.
int tg_prepare_index(const char *path,const char *private_index,const char *const *operations,const char *const *paths,const uint32_t *modes,size_t count,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};ctx.private_index=private_index;
 git_repository *repository=NULL;git_index *index=NULL;git_buf actual=GIT_BUF_INIT;int result=-1,descriptor=-1;struct stat info,real_info;
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 descriptor=open(private_index,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
 if(descriptor<0||fstat(descriptor,&info)<0||!S_ISREG(info.st_mode)||info.st_uid!=geteuid()||(info.st_mode&0777)!=0600||info.st_nlink!=1){git_error_set_str(GIT_ERROR_INDEX,"Commit preparation requires an owned regular 0600 private index");goto done;}
 if((result=git_repository_open(&repository,path))<0)goto done;
 if((result=git_repository_item_path(&actual,repository,GIT_REPOSITORY_ITEM_INDEX))<0)goto done;
 if(stat(actual.ptr,&real_info)==0&&info.st_dev==real_info.st_dev&&info.st_ino==real_info.st_ino){git_error_set_str(GIT_ERROR_INDEX,"Commit preparation must not write the live index");result=-1;goto done;}
 if((result=configure_repository(repository,&ctx))<0)goto done;
 if((result=git_index_open(&index,private_index))<0)goto done;
 if((result=git_repository_set_index(repository,index))<0)goto done;
 if((result=git_index_read(index,1))<0)goto done;
 for(size_t i=0;i<count;i++){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  if(!strcmp(operations[i],"remove")){
   result=git_index_remove_bypath(index,paths[i]);if(result==GIT_ENOTFOUND){git_error_clear();result=0;}if(result<0)goto done;
  }else if(!strcmp(operations[i],"add")){
   if((result=git_index_add_bypath(index,paths[i]))<0)goto done;
   if(modes[i]){
    const git_index_entry *existing=git_index_get_bypath(index,paths[i],0);
    if(!existing){git_error_set_str(GIT_ERROR_INDEX,"Prepared index entry is missing");result=-1;goto done;}
    if(existing->mode!=GIT_FILEMODE_COMMIT){git_index_entry entry=*existing;entry.mode=modes[i];if((result=git_index_add(index,&entry))<0)goto done;}
   }
  }else{git_error_set_str(GIT_ERROR_INDEX,"Unsupported Commit index operation");result=-1;goto done;}
 }
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 struct stat current;if(lstat(private_index,&current)<0||!S_ISREG(current.st_mode)||current.st_dev!=info.st_dev||current.st_ino!=info.st_ino){git_error_set_str(GIT_ERROR_INDEX,"Private Commit index changed during preparation");result=-1;goto done;}
 result=git_index_write(index);
 if(result==0){int written=open(private_index,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat final;
  if(written<0||fstat(written,&final)<0||!S_ISREG(final.st_mode)||final.st_uid!=geteuid()||final.st_nlink!=1||fchmod(written,0600)<0){git_error_set_str(GIT_ERROR_INDEX,"Cannot preserve private Commit index permissions");result=-1;}
  if(written>=0)close(written);
 }
 done:if(descriptor>=0)close(descriptor);git_buf_dispose(&actual);git_index_free(index);git_repository_free(repository);active_context=NULL;return result;
}

// Reset notification is a pre-overwrite UPDATED receipt, not checkout progress.
// The parent must acknowledge any requested Trash operation before we return.
static int reset_notify(git_checkout_notify_t why,const char *path,const git_diff_file *base,const git_diff_file *target,const git_diff_file *work,void *payload){
 (void)base;(void)target;(void)work;context *ctx=payload;
 if(stopped(ctx))return GIT_EUSER;
 if((why&GIT_CHECKOUT_NOTIFY_UPDATED)&&ctx->callbacks->reset_file&&ctx->callbacks->reset_file(path,ctx->callbacks->payload)<0){git_error_set_str(GIT_ERROR_CHECKOUT,"Reset overwrite notification or recycle request was refused");return GIT_EUSER;}
 return stopped(ctx)?GIT_EUSER:0;
}
static void reset_progress(const char *path,size_t completed,size_t total,void *payload){
 (void)path;context *ctx=payload;if(!stopped(ctx)&&ctx->callbacks->reset_progress)ctx->callbacks->reset_progress(completed,total,ctx->callbacks->payload);
}
// Pinned checkout's absent-workdir TYPECHANGE branch omits blob/link writes.
// Capture only that case before Reset changes HEAD; never infer recycle work
// from this diff. Recycling remains exclusively in real UPDATED callbacks.
static int reset_missing_typechanges(git_strarray *paths,git_repository *repository,git_tree *target,context *ctx){
 git_reference *head=NULL;git_tree *before=NULL;git_diff *diff=NULL;int result=0;size_t bytes=0;
 const char *root=git_repository_workdir(repository);if(!root)return 0;
 result=git_repository_head(&head,repository);
 if(result==GIT_EUNBORNBRANCH||result==GIT_ENOTFOUND){git_error_clear();result=0;goto done;}
 if(result<0||(result=git_reference_peel((git_object **)&before,head,GIT_OBJECT_TREE))<0)goto done;
 git_diff_options options=GIT_DIFF_OPTIONS_INIT;options.flags=GIT_DIFF_INCLUDE_TYPECHANGE|GIT_DIFF_INCLUDE_TYPECHANGE_TREES;
 if((result=git_diff_tree_to_tree(&diff,repository,before,target,&options))<0)goto done;
 for(size_t i=0;i<git_diff_num_deltas(diff);i++){
  if(stopped(ctx)){result=GIT_EUSER;goto done;}
  const git_diff_delta *delta=git_diff_get_delta(diff,i);
  if(delta->status!=GIT_DELTA_TYPECHANGE||(delta->new_file.mode!=GIT_FILEMODE_BLOB&&delta->new_file.mode!=GIT_FILEMODE_BLOB_EXECUTABLE&&delta->new_file.mode!=GIT_FILEMODE_LINK))continue;
  const char *relative=delta->new_file.path;size_t length=strlen(relative),root_length=strlen(root);
  if(length>1048576||paths->count>=100000||length+1>67108864-bytes){git_error_set_str(GIT_ERROR_CHECKOUT,"Reset missing type-change repair exceeds bounds");result=-1;goto done;}
  char *full=malloc(root_length+length+1);if(!full){result=-1;goto done;}memcpy(full,root,root_length);memcpy(full+root_length,relative,length+1);
  struct stat info;int found=lstat(full,&info),inspection_error=errno;free(full);
  if(found==0)continue;
  if(inspection_error!=ENOENT){git_error_set_str(GIT_ERROR_CHECKOUT,"Cannot inspect Reset type-change repair path");result=-1;goto done;}
  char **grown=realloc(paths->strings,(paths->count+1)*sizeof(char *));if(!grown){result=-1;goto done;}paths->strings=grown;
  char *copy=strdup(relative);if(!copy){result=-1;goto done;}paths->strings[paths->count++]=copy;bytes+=length+1;
 }
 done:git_diff_free(diff);git_tree_free(before);git_reference_free(head);return result;
}
static int reset_recreate_typechanges(git_repository *repository,git_tree *target,git_strarray *paths,git_checkout_options *options,context *ctx){
 const char *root=git_repository_workdir(repository);size_t kept=0;int result=0;
 for(size_t i=0;i<paths->count;i++){
  if(stopped(ctx)){result=GIT_EUSER;goto compact_done;}
  size_t length=strlen(root)+strlen(paths->strings[i])+1;char *full=malloc(length);if(!full){result=-1;goto compact_done;}snprintf(full,length,"%s%s",root,paths->strings[i]);
  struct stat info;int found=lstat(full,&info),inspection_error=errno;free(full);
  if(found!=0&&inspection_error!=ENOENT){git_error_set_str(GIT_ERROR_CHECKOUT,"Cannot recheck Reset type-change repair path");result=-1;goto compact_done;}
  if(found!=0){char *value=paths->strings[i];paths->strings[i]=NULL;paths->strings[kept++]=value;}
  else {free(paths->strings[i]);paths->strings[i]=NULL;}
 }
 compact_done:
 if(result<0){for(size_t i=kept;i<paths->count;i++)free(paths->strings[i]);paths->count=kept;return result;}
 paths->count=kept;if(!kept)return 0;
 options->checkout_strategy=GIT_CHECKOUT_FORCE|GIT_CHECKOUT_RECREATE_MISSING|GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH;
 options->baseline=target;options->paths=*paths;
 if(stopped(ctx))return GIT_EUSER;
 return git_checkout_tree(repository,(git_object *)target,options);
}
int tg_reset(const char *path,const char *revision,int mode,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};git_repository *repository=NULL;git_object *target=NULL;git_tree *target_tree=NULL;git_strarray missing={0};int result=-1;
 if(mode<1||mode>3){git_error_set_str(GIT_ERROR_INVALID,"Unsupported reset mode");return -1;}
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 if((result=git_repository_open(&repository,path))<0||(result=configure_repository(repository,&ctx))<0||(result=git_revparse_single(&target,repository,revision))<0)goto done;
 if(mode==GIT_RESET_HARD&&((result=git_object_peel((git_object **)&target_tree,target,GIT_OBJECT_TREE))<0||(result=reset_missing_typechanges(&missing,repository,target_tree,&ctx))<0))goto done;
 git_checkout_options options=GIT_CHECKOUT_OPTIONS_INIT;options.notify_flags=GIT_CHECKOUT_NOTIFY_ALL;options.notify_cb=reset_notify;options.notify_payload=&ctx;options.progress_cb=reset_progress;options.progress_payload=&ctx;
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 result=git_reset(repository,target,(git_reset_t)mode,&options);
 if(result==0&&mode==GIT_RESET_HARD&&missing.count)result=reset_recreate_typechanges(repository,target_tree,&missing,&options,&ctx);
 done:git_strarray_dispose(&missing);git_tree_free(target_tree);git_object_free(target);git_repository_free(repository);active_context=NULL;return result;
}
int tg_revert(const char *path,const char *revision,unsigned int mainline,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};git_repository *repository=NULL;git_object *object=NULL;git_commit *commit=NULL;int result=-1;
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 if((result=git_repository_open(&repository,path))<0||(result=configure_repository(repository,&ctx))<0||(result=git_revparse_single(&object,repository,revision))<0||(result=git_object_peel((git_object **)&commit,object,GIT_OBJECT_COMMIT))<0)goto done;
 git_revert_options options=GIT_REVERT_OPTIONS_INIT;options.mainline=mainline;
 // Preserve DEFAULT merge/checkout semantics; callbacks only fence cancellation.
 options.checkout_opts.notify_flags=GIT_CHECKOUT_NOTIFY_ALL;options.checkout_opts.notify_cb=checkout_notify;options.checkout_opts.notify_payload=&ctx;
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 result=git_revert(repository,commit,&options);
 done:git_commit_free(commit);git_object_free(object);git_repository_free(repository);active_context=NULL;return result;
}

// Source-selected unified output deliberately uses default diff options: no
// rename finding, merge/context switches or old-working-copy reversal.
typedef struct {context *ctx;size_t bytes;} diff_output;
static int diff_bytes(diff_output *out,const char *bytes,size_t count){
 if(stopped(out->ctx))return GIT_EUSER;
 if(count>134217728-out->bytes){git_error_set_str(GIT_ERROR_INVALID,"Unified diff output exceeds bounds");return -1;}
 if(out->ctx->callbacks->result&&count)out->ctx->callbacks->result(bytes,count,out->ctx->callbacks->payload);out->bytes+=count;return 0;
}
static int unified_line(const git_diff_delta *delta,const git_diff_hunk *hunk,const git_diff_line *line,void *payload){
 (void)delta;(void)hunk;diff_output *out=payload;int result;
 if(line->origin==GIT_DIFF_LINE_CONTEXT||line->origin==GIT_DIFF_LINE_ADDITION||line->origin==GIT_DIFF_LINE_DELETION){if((result=diff_bytes(out,&line->origin,1))<0)return result;}
 return diff_bytes(out,line->content,line->content_len);
}
static int diff_cancel(const git_diff *diff,const git_diff_delta *delta,const char *matched,void *payload){(void)diff;(void)delta;(void)matched;return stopped(payload)?GIT_EUSER:0;}
static int diff_progress(const git_diff *diff,const char *old_path,const char *new_path,void *payload){(void)diff;(void)old_path;(void)new_path;return stopped(payload)?GIT_EUSER:0;}
static int source_tree(git_tree **out,git_repository *repository,const char *revision){
 git_object *object=NULL;int result=git_revparse_single(&object,repository,revision);if(result<0)return result;
 switch(git_object_type(object)){
 case GIT_OBJECT_TREE:*out=(git_tree *)object;return 0;
 case GIT_OBJECT_COMMIT:result=git_commit_tree(out,(git_commit *)object);break;
 default:git_error_set_str(GIT_ERROR_INVALID,"Unified diff endpoint is not a tree or commit");result=GIT_ENOTFOUND;break;
 }
 git_object_free(object);return result;
}
int tg_unified_diff(const char *path,const char *old_revision,const char *new_revision,const char *const *paths,size_t count,int no_prefix,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};git_repository *repository=NULL;git_tree *old_tree=NULL,*new_tree=NULL;git_diff *diff=NULL,*work=NULL;git_diff_stats *stats=NULL;git_buf stat=GIT_BUF_INIT;int result=-1;diff_output out={&ctx,0};
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 if((result=git_repository_open(&repository,path))<0||(result=configure_repository(repository,&ctx))<0)goto done;
 result=git_repository_head_unborn(repository);if(result==1){result=0;goto done;}if(result!=0)goto done;
 git_diff_options options=GIT_DIFF_OPTIONS_INIT;options.pathspec.strings=(char **)paths;options.pathspec.count=count;options.flags|=GIT_DIFF_DISABLE_PATHSPEC_MATCH;options.notify_cb=diff_cancel;options.progress_cb=diff_progress;options.payload=&ctx;
 if(no_prefix){options.old_prefix="";options.new_prefix="";}
 if(!strcmp(old_revision,"WORKTREE")||!strcmp(new_revision,"WORKTREE")){
  const char *base=!strcmp(old_revision,"WORKTREE")?new_revision:old_revision;
  if(!*base){git_error_set_str(GIT_ERROR_INVALID,"Working diff requires a revision endpoint");result=-1;goto done;}
  if(strcmp(base,"WORKTREE")&&(result=source_tree(&old_tree,repository,base))<0)goto done;
  if((result=git_diff_tree_to_index(&diff,repository,old_tree,NULL,&options))<0||(result=git_diff_index_to_workdir(&work,repository,NULL,&options))<0||(result=git_diff_merge(diff,work))<0)goto done;
 }else{
  const char *after=new_revision,*before=old_revision;if(!*after){after=before;before="";}
  if(!*after){git_error_set_str(GIT_ERROR_INVALID,"Unified diff requires a revision");result=-1;goto done;}
  if((result=source_tree(&new_tree,repository,after))<0)goto done;
  if(*before){if((result=source_tree(&old_tree,repository,before))<0)goto done;}
  else {size_t length=strlen(after)+3;char *parent=malloc(length);if(!parent){result=-1;goto done;}snprintf(parent,length,"%s~1",after);(void)source_tree(&old_tree,repository,parent);free(parent);git_error_clear();}
  if((result=git_diff_tree_to_tree(&diff,repository,old_tree,new_tree,&options))<0)goto done;
 }
 if((result=git_diff_get_stats(&stats,diff))<0||(result=git_diff_stats_to_buf(&stat,stats,GIT_DIFF_STATS_FULL,0))<0||(result=diff_bytes(&out,stat.ptr,stat.size))<0||(result=diff_bytes(&out,"\n",1))<0)goto done;
 for(size_t i=0;i<git_diff_num_deltas(diff);i++){
  git_patch *patch=NULL;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  result=git_patch_from_diff(&patch,diff,i);if(result==0&&!patch){git_error_set_str(GIT_ERROR_INVALID,"Unified patch is unavailable");result=-1;}if(result==0)result=git_patch_print(patch,unified_line,&out);git_patch_free(patch);if(result<0)goto done;
 }
 result=0;
 done:git_buf_dispose(&stat);git_diff_stats_free(stats);git_diff_free(work);git_diff_free(diff);git_tree_free(old_tree);git_tree_free(new_tree);git_repository_free(repository);active_context=NULL;return result;
}
int tg_history_diff(const char *path,const char *revision,int simple,unsigned int threshold,tg_callbacks *callbacks){
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX};git_repository *repository=NULL;git_commit *commit=NULL;git_tree *tree=NULL;git_oid oid;char **parents=NULL;size_t parent_count=0,emitted=0;int result=-1;
 active_context=&ctx;if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 if(threshold>100||git_oid_fromstr(&oid,revision)<0){git_error_set_str(GIT_ERROR_INVALID,"Invalid history diff request");goto done;}
 if((result=git_repository_open(&repository,path))<0||(result=configure_repository(repository,&ctx))<0||(result=git_commit_lookup(&commit,repository,&oid))<0||(result=git_commit_tree(&tree,commit))<0)goto done;
 parent_count=git_commit_parentcount(commit);if(parent_count>4096){git_error_set_str(GIT_ERROR_INVALID,"History parent count exceeds bounds");result=-1;goto done;}
 parents=calloc(parent_count?parent_count:1,sizeof(char *));if(!parents){result=-1;goto done;}
 for(size_t p=0;p<parent_count;p++){parents[p]=malloc(GIT_OID_MAX_HEXSIZE+1);if(!parents[p]){result=-1;goto done;}git_oid_tostr(parents[p],GIT_OID_MAX_HEXSIZE+1,git_commit_parent_id(commit,(unsigned int)p));}
 if(callbacks->history_header&&(result=callbacks->history_header(revision,(const char *const *)parents,parent_count,callbacks->payload))<0)goto done;
 for(size_t p=0;p<(parent_count?parent_count:1);p++){
  git_commit *parent=NULL;git_tree *before=NULL;git_diff *diff=NULL;
  if(stopped(&ctx)){result=GIT_EUSER;goto parent_done;}
  if(parent_count&&((result=git_commit_parent(&parent,commit,(unsigned int)p))<0||(result=git_commit_tree(&before,parent))<0))goto parent_done;
  git_diff_options options=GIT_DIFF_OPTIONS_INIT;options.notify_cb=diff_cancel;options.progress_cb=diff_progress;options.payload=&ctx;
  if((result=git_diff_tree_to_tree(&diff,repository,before,tree,&options))<0)goto parent_done;
  if(!simple&&threshold){git_diff_find_options find=GIT_DIFF_FIND_OPTIONS_INIT;find.flags=GIT_DIFF_FIND_COPIES|GIT_DIFF_FIND_RENAMES;find.rename_threshold=find.copy_threshold=(uint16_t)threshold;if((result=git_diff_find_similar(diff,&find))<0)goto parent_done;}
  for(size_t i=0;i<git_diff_num_deltas(diff);i++){
   git_patch *patch=NULL;const git_diff_delta *delta=git_diff_get_delta(diff,i);tg_history_delta value={0};char old_oid[GIT_OID_MAX_HEXSIZE+1],new_oid[GIT_OID_MAX_HEXSIZE+1];
   if(stopped(&ctx)){result=GIT_EUSER;goto parent_done;}
   if(emitted++>=100000){git_error_set_str(GIT_ERROR_INVALID,"History delta count exceeds bounds");result=-1;goto parent_done;}
   value.path=delta->new_file.path;value.old_path=delta->old_file.path;value.parent_index=(unsigned int)p;value.parent_hash=parent_count?parents[p]:"";value.status=delta->status;value.old_mode=delta->old_file.mode;value.new_mode=delta->new_file.mode;
   git_oid_tostr(old_oid,sizeof(old_oid),&delta->old_file.id);git_oid_tostr(new_oid,sizeof(new_oid),&delta->new_file.id);value.old_hash=old_oid;value.new_hash=new_oid;
   if(!simple){
    if((result=git_patch_from_diff(&patch,diff,i))<0)goto parent_done;
    if(!patch){git_error_set_str(GIT_ERROR_INVALID,"History patch is unavailable");result=-1;goto parent_done;}
    delta=git_patch_get_delta(patch);value.binary=(delta->flags&GIT_DIFF_FLAG_BINARY)!=0;value.counts_known=!value.binary;value.is_directory=((delta->status==GIT_DELTA_DELETED?delta->old_file.mode:delta->new_file.mode)&S_IFDIR)==S_IFDIR;
    if(value.counts_known&&(result=git_patch_line_stats(NULL,&value.additions,&value.deletions,patch))<0){git_patch_free(patch);goto parent_done;}
    const git_diff_delta *next=i+1<git_diff_num_deltas(diff)?git_diff_get_delta(diff,i+1):NULL;
    if(next&&!strcmp(delta->new_file.path,next->new_file.path)&&((delta->status==GIT_DELTA_DELETED&&next->status==GIT_DELTA_ADDED)||(delta->status==GIT_DELTA_ADDED&&next->status==GIT_DELTA_DELETED))){
     const git_diff_delta *added=delta->status==GIT_DELTA_ADDED?delta:next,*deleted=delta->status==GIT_DELTA_DELETED?delta:next;
     value.status=GIT_DELTA_MODIFIED;value.binary=0;value.counts_known=0;value.old_mode=deleted->old_file.mode;value.new_mode=added->new_file.mode;git_oid_tostr(old_oid,sizeof(old_oid),&deleted->old_file.id);git_oid_tostr(new_oid,sizeof(new_oid),&added->new_file.id);i++;
    }
   }
   result=callbacks->history_delta?callbacks->history_delta(&value,callbacks->payload):0;git_patch_free(patch);if(result<0)goto parent_done;
  }
  result=0;
  parent_done:git_diff_free(diff);git_tree_free(before);git_commit_free(parent);if(result<0)goto done;
 }
 result=0;
 done:if(parents){for(size_t p=0;p<parent_count;p++)free(parents[p]);free(parents);}git_tree_free(tree);git_commit_free(commit);git_repository_free(repository);active_context=NULL;return result;
}

/* Local reference reads use their pinned source command gates in Core. These
 * callbacks retain literal names before resolving a symbolic reference. */
static int local_reference_row(context *ctx,git_repository *repo,git_reference *raw,int metadata){
 git_reference *ref=NULL;git_object *object=NULL;git_buf upstream=GIT_BUF_INIT;int result=0;
 const char *name=git_reference_name(raw),*symbolic=git_reference_symbolic_target(raw);
 if((result=git_reference_resolve(&ref,raw))<0)goto done;
 const git_oid *oid=git_reference_target(ref);char hex[GIT_OID_SHA1_HEXSIZE+1];
 if(!oid){result=-1;git_error_set_str(GIT_ERROR_REFERENCE,"Reference has no object ID");goto done;}
 git_oid_tostr(hex,sizeof(hex),oid);
 tg_local_reference row={0};row.name=name;row.oid=hex;row.symbolic_target=symbolic;row.object_type="";row.subject="";row.author_name="";row.author_email="";row.committer_name="";row.committer_email="";
 if(metadata){
  if((result=git_object_lookup(&object,repo,oid,GIT_OBJECT_ANY))<0)goto done;
  row.object_type=git_object_type2string(git_object_type(object));
  const git_signature *author=NULL,*committer=NULL;
  if(git_object_type(object)==GIT_OBJECT_TAG && git_reference_is_tag(ref)){
   git_tag *tag=(git_tag *)object;const char *message=git_tag_message(tag);row.subject=message?message:"";author=committer=git_tag_tagger(tag);
  }else if(git_object_type(object)==GIT_OBJECT_COMMIT){
   git_commit *commit=(git_commit *)object;const char *summary=git_commit_summary(commit);row.subject=summary?summary:"";author=git_commit_author(commit);committer=git_commit_committer(commit);
   if(git_reference_is_branch(ref)){
    result=git_branch_upstream_name(&upstream,repo,git_reference_name(ref));
    if(result==GIT_ENOTFOUND){git_error_clear();result=0;}else if(result<0)goto done;
    row.upstream=upstream.ptr;
   }
  }
  if(author){row.has_author=1;row.author_name=author->name?author->name:"";row.author_email=author->email?author->email:"";row.author_time=author->when.time;}
  if(committer){row.has_committer=1;row.committer_name=committer->name?committer->name:"";row.committer_email=committer->email?committer->email:"";row.committer_time=committer->when.time;}
 }
 if(stopped(ctx)){result=GIT_EUSER;goto done;}
 if(ctx->callbacks->local_reference)result=ctx->callbacks->local_reference(&row,ctx->callbacks->payload);
 done:git_buf_dispose(&upstream);git_object_free(object);git_reference_free(ref);return result;
}
int tg_local_references(const char *path,int scope,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_reference_iterator *iterator=NULL;git_reference *ref=NULL;int result=0;size_t count=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0||(result=git_reference_iterator_new(&iterator,repo))<0)goto done;
 while((result=git_reference_next(&ref,iterator))==0){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  if(++count>100000){git_error_set_str(GIT_ERROR_REFERENCE,"Reference inventory exceeds bounds");result=-1;goto done;}
  const char *name=git_reference_name(ref);int included=scope==0||(scope==1&&!strncmp(name,"refs/heads/",11))||(scope==2&&(!strncmp(name,"refs/heads/",11)||!strncmp(name,"refs/tags/",10)))||(scope==3&&strncmp(name,"refs/tags/",10))||(scope==4&&!strncmp(name,"refs/remotes/",13));
  result=included?local_reference_row(&ctx,repo,ref,1):0;git_reference_free(ref);ref=NULL;if(result<0)goto done;
 }
 if(result==GIT_ITEROVER)result=0;
 done:git_reference_free(ref);git_reference_iterator_free(iterator);git_repository_free(repo);return result;
}
int tg_containing_references(const char *path,const char *hash,int tags,int local,int remote,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_reference_iterator *iterator=NULL;git_reference *raw=NULL,*ref=NULL;git_object *object=NULL;git_oid wanted;int result=0;size_t count=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 if(git_oid_fromstr(&wanted,hash)<0)return -1;
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0||(result=git_reference_iterator_new(&iterator,repo))<0)goto done;
 while((result=git_reference_next(&raw,iterator))==0){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  if(++count>100000){git_error_set_str(GIT_ERROR_REFERENCE,"Reference inventory exceeds bounds");result=-1;goto done;}
  int eligible=git_reference_is_tag(raw)?tags:git_reference_is_remote(raw)?remote:git_reference_is_branch(raw)?local:0;
  if(eligible && git_reference_resolve(&ref,raw)==0){
   const git_oid *oid=git_reference_target(ref);
   if(git_reference_is_tag(ref) && git_object_lookup(&object,repo,oid,GIT_OBJECT_TAG)==0){
    git_object *peeled=NULL;if(git_object_peel(&peeled,object,GIT_OBJECT_ANY)==0){git_object_free(object);object=peeled;oid=git_object_id(object);}else{git_error_clear();oid=NULL;}
   }else git_error_clear();
   if(oid && (git_oid_equal(oid,&wanted)||git_graph_descendant_of(repo,oid,&wanted)==1)){
    result=local_reference_row(&ctx,repo,raw,0);if(result<0)goto done;
   }
  }
  /* The source skips unresolved/tag-peeling/graph failures per reference. */
  git_error_clear();git_object_free(object);object=NULL;git_reference_free(ref);ref=NULL;git_reference_free(raw);raw=NULL;
 }
 if(result==GIT_ITEROVER)result=0;
 done:git_object_free(object);git_reference_free(ref);git_reference_free(raw);git_reference_iterator_free(iterator);git_repository_free(repo);return result;
}

/* Removal holds every symbolic-chain lock until the captured OID and immediate
 * alias target have been checked. No dereferencing mutation is used. */
static int local_reference_changed(void){git_error_set_str(GIT_ERROR_REFERENCE,"The reference changed after this operation began; refresh before retrying");return GIT_EMODIFIED;}
static int local_config_key_compare(const void *a,const void *b){return strcmp(*(const char *const *)a,*(const char *const *)b);}
static int local_branch_config_prepare(git_config **prepared,git_transaction **prepared_transaction,git_repository *repo,const char *name){
 git_config *config=NULL;git_transaction *transaction=NULL;git_config_iterator *iterator=NULL;git_config_entry *entry=NULL;char **keys=NULL;size_t count=0,bytes=0,scanned=0;int result=0;
 const char *shortname=name+strlen("refs/heads/");size_t length=strlen(shortname)+8;char *prefix=malloc(length+1);if(!prefix)return -1;snprintf(prefix,length+1,"branch.%s.",shortname);
 if((result=git_repository_config(&config,repo))<0||(result=git_config_lock(&transaction,config))<0||(result=git_config_iterator_new(&iterator,config))<0)goto done;
 while((result=git_config_next(&entry,iterator))==0){
  if(++scanned>100000){git_error_set_str(GIT_ERROR_CONFIG,"Branch configuration scan exceeds bounds");result=-1;goto done;}
  if(strncmp(entry->name,prefix,strlen(prefix)))continue;
  size_t n=strnlen(entry->name,1048577);if(n>1048576||count>=100000||n>67108864-bytes){git_error_set_str(GIT_ERROR_CONFIG,"Branch configuration exceeds bounds");result=-1;goto done;}
  char **grown=realloc(keys,(count+1)*sizeof(char *));if(!grown){result=-1;goto done;}keys=grown;keys[count]=strdup(entry->name);if(!keys[count]){result=-1;goto done;}count++;bytes+=n;
 }
 if(result!=GIT_ITEROVER)goto done;result=0;git_config_iterator_free(iterator);iterator=NULL;
 qsort(keys,count,sizeof(char *),local_config_key_compare);
 for(size_t i=0;i<count;i++){if(i&&!strcmp(keys[i-1],keys[i]))continue;result=git_config_delete_multivar(config,keys[i],".*");if(result==GIT_ENOTFOUND){git_error_clear();result=0;}if(result<0)break;}
 if(result==0){*prepared=config;*prepared_transaction=transaction;config=NULL;transaction=NULL;}
 done:for(size_t i=0;i<count;i++)free(keys[i]);free(keys);free(prefix);git_config_iterator_free(iterator);git_transaction_free(transaction);git_config_free(config);return result;
}
int tg_delete_local_reference(const char *path,const char *name,const char *hash,const char *symbolic,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_reference *raw=NULL;git_transaction *transaction=NULL,*config_transaction=NULL;git_config *config=NULL;git_oid wanted;int result=0;char *names[33]={0},*targets[33]={0};git_oid ids[33];int types[33]={0};size_t count=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 int valid=0;if(strncmp(name,"refs/",5)||git_reference_name_is_valid(&valid,name)<0||!valid||git_oid_fromstr(&wanted,hash)<0){git_error_set_str(GIT_ERROR_REFERENCE,"Invalid local reference deletion request");return -1;}
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0)goto done;
 const char *cursor=name;
 for(;;){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  if(count>=32){result=local_reference_changed();goto done;}
  for(size_t i=0;i<count;i++)if(!strcmp(cursor,names[i])){result=local_reference_changed();goto done;}
  if((result=git_reference_lookup(&raw,repo,cursor))<0)goto done;
  names[count]=strdup(cursor);if(!names[count]){result=-1;goto done;}
  types[count]=git_reference_type(raw);
  if(types[count]==GIT_REFERENCE_SYMBOLIC){targets[count]=strdup(git_reference_symbolic_target(raw));if(!targets[count]){result=-1;goto done;}cursor=targets[count];count++;git_reference_free(raw);raw=NULL;}
  else {const git_oid *oid=git_reference_target(raw);if(!oid){result=local_reference_changed();goto done;}git_oid_cpy(&ids[count],oid);count++;git_reference_free(raw);raw=NULL;break;}
 }
 if((symbolic==NULL)!=(targets[0]==NULL)||(symbolic&&strcmp(symbolic,targets[0]))||!git_oid_equal(&ids[count-1],&wanted)){result=local_reference_changed();goto done;}
 if((result=git_transaction_new(&transaction,repo))<0)goto done;
 /* Immediate failure on competing locks; no lock-order waits or retry mutation. */
 for(size_t i=0;i<count;i++)if((result=git_transaction_lock_ref(transaction,names[i]))<0)goto done;
 for(size_t i=0;i<count;i++){
  if((result=git_reference_lookup(&raw,repo,names[i]))<0)goto done;
  if(git_reference_type(raw)!=types[i]||(targets[i]&&(!git_reference_symbolic_target(raw)||strcmp(targets[i],git_reference_symbolic_target(raw))))||(!targets[i]&&(!git_reference_target(raw)||!git_oid_equal(&ids[i],git_reference_target(raw))))){result=local_reference_changed();goto done;}
  git_reference_free(raw);raw=NULL;
 }
 if((result=git_reference_lookup(&raw,repo,name))<0)goto done;
 if(git_reference_is_branch(raw)||git_reference_is_remote(raw)){
  int head=git_branch_is_head(raw);if(head<0){result=head;goto done;}
  if(head|| (git_reference_is_branch(raw)&&git_branch_is_checked_out(raw))){git_error_set_str(GIT_ERROR_REFERENCE,"Cannot delete a branch checked out in this or a linked worktree");result=-1;goto done;}
 }
 /* Stage cleanup while both the named reference and config writer are held.
  * This prevents cleanup from erasing a newly recreated branch's config. */
 if(!strncmp(name,"refs/heads/",11)&&(result=local_branch_config_prepare(&config,&config_transaction,repo,name))<0)goto done;
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 if((result=git_transaction_remove(transaction,name))<0||(result=git_transaction_commit(transaction))<0)goto done;
 if(config_transaction&&(result=git_transaction_commit(config_transaction))<0){
  const git_error *error=git_error_last();char *message=strdup(error&&error->message?error->message:"configuration write failed");
  git_error_set(GIT_ERROR_CONFIG,"Reference '%s' was deleted, but branch configuration cleanup failed: %s",name,message?message:"configuration write failed");free(message);
 }
 done:git_reference_free(raw);git_transaction_free(transaction);git_transaction_free(config_transaction);git_config_free(config);git_repository_free(repo);for(size_t i=0;i<33;i++){free(names[i]);free(targets[i]);}return result;
}

int tg_local_reference_names(const char *path,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_reference_iterator *iterator=NULL;const char *name=NULL;int result=0;size_t count=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0||(result=git_reference_iterator_new(&iterator,repo))<0)goto done;
 while((result=git_reference_next_name(&name,iterator))==0){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  if(++count>100000){git_error_set_str(GIT_ERROR_REFERENCE,"Reference names exceed bounds");result=-1;goto done;}
  tg_local_reference row={0};row.name=name;
  if(callbacks->local_reference&&(result=callbacks->local_reference(&row,callbacks->payload))<0)goto done;
 }
 if(result==GIT_ITEROVER)result=0;
 done:git_reference_iterator_free(iterator);git_repository_free(repo);return result;
}

/* Source IsFastForward takes one merge base (to, from); unrelated commits are
 * a normal negative decision, not a fabricated common ancestor. */
static int inspection_emit(context *ctx,const tg_inspection *row){
 if(stopped(ctx))return GIT_EUSER;
 return ctx->callbacks->inspection?ctx->callbacks->inspection(row,ctx->callbacks->payload):0;
}
int tg_inspect_merge_base(const char *path,const char *from,const char *to,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_commit *a=NULL,*b=NULL;git_oid from_oid,to_oid,base;int result=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};tg_inspection row={0};row.kind=0;
 if(git_oid_fromstr(&from_oid,from)<0||git_oid_fromstr(&to_oid,to)<0)return -1;
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0)goto done;
 /* The source resolves both inputs before asking for the merge base. */
 if((result=git_commit_lookup(&a,repo,&from_oid))<0||(result=git_commit_lookup(&b,repo,&to_oid))<0)goto done;
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 result=git_merge_base(&base,repo,&to_oid,&from_oid);
 if(result==GIT_ENOTFOUND){git_error_clear();result=inspection_emit(&ctx,&row);}
 else if(result==0){char hex[GIT_OID_MAX_HEXSIZE+1];git_oid_tostr(hex,sizeof(hex),&base);row.base=hex;row.value=git_oid_equal(&base,&from_oid);result=inspection_emit(&ctx,&row);}
 done:git_commit_free(a);git_commit_free(b);git_repository_free(repo);return result;
}
int tg_inspect_clean(const char *path,int staged_ok,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_status_list *status=NULL;int result=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};tg_inspection row={0};row.kind=1;
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0)goto done;
 int unborn=git_repository_head_unborn(repo);if(unborn<0){result=unborn;goto done;}
 if(unborn){result=inspection_emit(&ctx,&row);goto done;}
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 git_status_options options=GIT_STATUS_OPTIONS_INIT;options.show=staged_ok?GIT_STATUS_SHOW_WORKDIR_ONLY:GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
 options.flags=GIT_STATUS_OPT_UPDATE_INDEX|GIT_STATUS_OPT_EXCLUDE_SUBMODULES;
 if((result=git_status_list_new(&status,repo,&options))<0)goto done;
 row.value=git_status_list_entrycount(status)==0;result=inspection_emit(&ctx,&row);
 done:git_status_list_free(status);git_repository_free(repo);return result;
}
int tg_inspect_conflicts(const char *path,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_index *index=NULL;int result=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};tg_inspection row={0};row.kind=2;
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0||(result=git_repository_index(&index,repo))<0)goto done;
 row.value=git_index_has_conflicts(index);result=inspection_emit(&ctx,&row);
 done:git_index_free(index);git_repository_free(repo);return result;
}
int tg_inspect_conflict_info(const char *path,const char *const *paths,size_t count,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_index *index=NULL;int result=0;context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 if(count>100000){git_error_set_str(GIT_ERROR_INDEX,"Conflict inspection exceeds bounds");return -1;}
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0||(result=git_repository_index(&index,repo))<0)goto done;
 for(size_t i=0;i<count;i++){
  if(stopped(&ctx)){result=GIT_EUSER;goto done;}
  const git_index_entry *ancestor=NULL,*ours=NULL,*theirs=NULL;tg_inspection_stage stages[3];char hashes[3][GIT_OID_MAX_HEXSIZE+1];size_t n=0;
  result=git_index_conflict_get(&ancestor,&ours,&theirs,index,paths[i]);
  if(result==GIT_ENOTFOUND){git_error_clear();result=0;}else if(result<0)goto done;
  const git_index_entry *values[3]={ancestor,ours,theirs};
  for(int stage=0;stage<3;stage++)if(values[stage]){
   git_oid_tostr(hashes[n],sizeof(hashes[n]),&values[stage]->id);stages[n].number=stage+1;stages[n].mode=values[stage]->mode;stages[n].oid=hashes[n];n++;
  }
  tg_inspection row={0};row.kind=3;row.path=paths[i];row.stages=stages;row.stage_count=n;
  if((result=inspection_emit(&ctx,&row))<0)goto done;
 }
 done:git_index_free(index);git_repository_free(repo);return result;
}

/* GitRev::GetCommit(string, allowTree), not the unconditionally gitdll-backed
 * GetCommitFromHash overload. Getter strings stay in their declared encoding;
 * no summary folding, message trimming, or UTF-8 conversion occurs here. */
int tg_read_single_commit(const char *path,const char *revision,int allow_tree,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_object *object=NULL;git_commit *commit=NULL;git_tree *tree=NULL;char *peeled_revision=NULL;char **parents=NULL;size_t parent_count=0;int result=0;
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};tg_single_commit row={0};char oid[GIT_OID_MAX_HEXSIZE+1],tree_oid[GIT_OID_MAX_HEXSIZE+1];
 size_t revision_length=strnlen(revision,1048577);if(!revision_length||revision_length>1048576){git_error_set_str(GIT_ERROR_OBJECT,"Invalid single-commit revision");return -1;}
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0)goto done;
 peeled_revision=malloc(revision_length+4);if(!peeled_revision){result=-1;goto done;}memcpy(peeled_revision,revision,revision_length);memcpy(peeled_revision+revision_length,"^{}",4);
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 result=git_revparse_single(&object,repo,peeled_revision);
 if(result==0)result=git_commit_lookup(&commit,repo,git_object_id(object));
 if(result<0){
  if(!allow_tree)goto done;
  git_error_clear();git_object_free(object);object=NULL;
  /* Source fallback uses the ORIGINAL revision, without recursively peeling
   * an annotated tag to a tree. Direct tree IDs/expressions are accepted. */
  if((result=git_revparse_single(&object,repo,revision))<0||(result=git_tree_lookup(&tree,repo,git_object_id(object)))<0)goto done;
  row.object_type=1;git_oid_tostr(oid,sizeof(oid),git_tree_id(tree));row.oid=oid;
 }else{
  const git_signature *author=git_commit_author(commit),*committer=git_commit_committer(commit);
  if(!author||!committer){git_error_set_str(GIT_ERROR_OBJECT,"Commit is missing author or committer metadata");result=-1;goto done;}
  parent_count=git_commit_parentcount(commit);if(parent_count>4096){git_error_set_str(GIT_ERROR_OBJECT,"Commit parent count exceeds bounds");result=-1;goto done;}
  if(parent_count){parents=calloc(parent_count,sizeof(char *));if(!parents){result=-1;goto done;}}
  for(size_t i=0;i<parent_count;i++){
   if(stopped(&ctx)){result=GIT_EUSER;goto done;}
   const git_oid *parent=git_commit_parent_id(commit,(unsigned int)i);if(!parent){git_error_set_str(GIT_ERROR_OBJECT,"Invalid commit parent");result=-1;goto done;}
   parents[i]=malloc(GIT_OID_MAX_HEXSIZE+1);if(!parents[i]){result=-1;goto done;}git_oid_tostr(parents[i],GIT_OID_MAX_HEXSIZE+1,parent);
  }
  git_oid_tostr(oid,sizeof(oid),git_commit_id(commit));git_oid_tostr(tree_oid,sizeof(tree_oid),git_commit_tree_id(commit));
  row.object_type=0;row.oid=oid;row.tree=tree_oid;row.parents=(const char *const *)parents;row.parent_count=parent_count;
  row.encoding=git_commit_message_encoding(commit);row.author_name=author->name;row.author_email=author->email;row.author_time=author->when.time;row.author_offset=author->when.offset;
  row.committer_name=committer->name;row.committer_email=committer->email;row.committer_time=committer->when.time;row.committer_offset=committer->when.offset;row.message=git_commit_message_raw(commit);
 }
 if(stopped(&ctx)){result=GIT_EUSER;goto done;}
 result=callbacks->single_commit?callbacks->single_commit(&row,callbacks->payload):0;
 done:if(parents){for(size_t i=0;i<parent_count;i++)free(parents[i]);free(parents);}free(peeled_revision);git_tree_free(tree);git_commit_free(commit);git_object_free(object);git_repository_free(repo);return result;
}

/* Finder uses GitIndex.cpp's stat-first algorithm, independently of Git's
 * command mask. Never refresh/write the user's index while collecting badges. */
static int finder_emit(context *ctx,const char *path,int state,int skip,int assume){
 if(stopped(ctx))return GIT_EUSER;
 return ctx->callbacks->finder_status?ctx->callbacks->finder_status(path,state,skip,assume,ctx->callbacks->payload):GIT_EUSER;
}
static int finder_same_stat(const struct stat *a,const struct stat *b){
 return a->st_dev==b->st_dev&&a->st_ino==b->st_ino&&a->st_mode==b->st_mode&&a->st_size==b->st_size&&a->st_mtimespec.tv_sec==b->st_mtimespec.tv_sec&&a->st_mtimespec.tv_nsec==b->st_mtimespec.tv_nsec&&a->st_ctimespec.tv_sec==b->st_ctimespec.tv_sec&&a->st_ctimespec.tv_nsec==b->st_ctimespec.tv_nsec;
}
/* No directory symlink traversal, including a replacement of an indexed
 * directory with a link. Leaf symlinks are inspected without following them. */
static int finder_parent(int root,const char *path,char **leaf){
 char *copy=strdup(path);if(!copy)return -1;int fd=dup(root);if(fd<0){free(copy);return -1;}
 char *start=copy,*slash;
 while((slash=strchr(start,'/'))){*slash=0;if(!*start||!strcmp(start,".")||!strcmp(start,"..")){close(fd);free(copy);errno=EINVAL;return -1;}
  int next=openat(fd,start,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(fd);fd=next;if(fd<0){free(copy);return -1;}start=slash+1;
 }
 if(!*start||!strcmp(start,".")||!strcmp(start,"..")){close(fd);free(copy);errno=EINVAL;return -1;}
 *leaf=strdup(start);free(copy);if(!*leaf){close(fd);return -1;}return fd;
}
static int finder_index_state(git_repository *repo,const git_index_entry *entry,int caps,int root,uint64_t limit,uint64_t *hash_bytes,context *ctx,int *state){
 int skip=(entry->flags_extended&GIT_INDEX_ENTRY_SKIP_WORKTREE)!=0,assume=(entry->flags&GIT_INDEX_ENTRY_VALID)!=0;
 *state=0;
 if(!skip&&!assume){
  char *leaf=NULL;int parent=finder_parent(root,entry->path,&leaf);struct stat before,after;
  if(parent<0){if(errno==ENOENT||errno==ENOTDIR||errno==ELOOP)*state=3;else return -1;}
  else {
   if(fstatat(parent,leaf,&before,AT_SYMLINK_NOFOLLOW)<0){if(errno==ENOENT||errno==ENOTDIR)*state=3;else{close(parent);free(leaf);return -1;}}
   else if(entry->mode==GIT_FILEMODE_COMMIT){*state=S_ISDIR(before.st_mode)?0:1;}
   else {
    int link=S_ISLNK(before.st_mode),indexed_link=entry->mode==GIT_FILEMODE_LINK;
    if((link&&!indexed_link)||(!(caps&GIT_INDEX_CAPABILITY_NO_SYMLINKS)&&link!=indexed_link))*state=1;
    else if(!link&&(uint32_t)before.st_size!=entry->file_size)*state=1;
    else if((int32_t)before.st_mtimespec.tv_sec==entry->mtime.seconds&&(uint32_t)before.st_mtimespec.tv_nsec==entry->mtime.nanoseconds)*state=0;
    else if(before.st_size>=0&&(uint64_t)before.st_size<limit){
     if((uint64_t)before.st_size>268435456-*hash_bytes){git_error_set_str(GIT_ERROR_INDEX,"Finder filtered content exceeds aggregate 256 MiB hash budget");close(parent);free(leaf);return -1;}
     *hash_bytes+=(uint64_t)before.st_size;
     git_oid actual;int hash_result=-1;
     if(stopped(ctx)){close(parent);free(leaf);return GIT_EUSER;}
     if(link){char target[1048577];ssize_t n=readlinkat(parent,leaf,target,sizeof(target));if(n>=0&&(size_t)n<sizeof(target))hash_result=git_odb_hash(&actual,target,(size_t)n,GIT_OBJECT_BLOB);}
     else if(S_ISREG(before.st_mode))hash_result=git_repository_hashfile(&actual,repo,entry->path,GIT_OBJECT_BLOB,NULL);
     if(stopped(ctx)){close(parent);free(leaf);return GIT_EUSER;}
     *state=hash_result==0&&git_oid_equal(&actual,&entry->id)&&fstatat(parent,leaf,&after,AT_SYMLINK_NOFOLLOW)==0&&finder_same_stat(&before,&after)?0:1;
     git_error_clear();
    }else *state=1;
   }
   close(parent);free(leaf);
  }
 }
 if(GIT_INDEX_ENTRY_STAGE(entry))*state=6;
 else if(entry->flags_extended&GIT_INDEX_ENTRY_INTENT_TO_ADD)*state=2;
 return 0;
}
static int finder_tree_entry(git_tree_entry **out,git_repository *repo,git_tree *tree,const char *path,int ignore_case){
 if(!tree)return GIT_ENOTFOUND;
 int result=git_tree_entry_bypath(out,tree,path);if(result!=GIT_ENOTFOUND||!ignore_case)return result;
 git_error_clear();git_tree *owned=NULL;const git_tree *current=tree;char *copy=strdup(path);if(!copy)return -1;
 char *part=copy,*slash;size_t visited=0;
 while(1){slash=strchr(part,'/');if(slash)*slash=0;const git_tree_entry *entry=git_tree_entry_byname(current,part);
  if(!entry){size_t count=git_tree_entrycount(current);for(size_t i=0;i<count;i++){if(++visited>100000){result=-1;goto done;}const git_tree_entry *candidate=git_tree_entry_byindex(current,i);if(!strcasecmp(git_tree_entry_name(candidate),part)){entry=candidate;break;}}}
  if(!entry){result=GIT_ENOTFOUND;goto done;}
  if(!slash){result=git_tree_entry_dup(out,entry);goto done;}
  git_tree *next=NULL;result=git_tree_lookup(&next,repo,git_tree_entry_id(entry));if(result<0)goto done;git_tree_free(owned);owned=next;current=next;part=slash+1;
 }
 done:git_tree_free(owned);free(copy);return result;
}
typedef struct {context *ctx;git_repository *repo;git_index *index;git_tree *tree;int full,ignore_case;size_t visited;} finder_walk;
static const git_index_entry *finder_index_entry(git_index *index,const char *path){
 const git_index_entry *entry=git_index_get_bypath(index,path,0);
 for(int stage=1;!entry&&stage<=3;stage++)entry=git_index_get_bypath(index,path,stage);
 return entry;
}
static int finder_deleted(const char *root,const git_tree_entry *entry,void *raw){
 finder_walk *walk=raw;if(stopped(walk->ctx))return GIT_EUSER;
 if(git_tree_entry_type(entry)==GIT_OBJECT_TREE)return 0;
 size_t n=strlen(root)+strlen(git_tree_entry_name(entry))+1;if(n>1048576)return -1;
 char *name=malloc(n);if(!name)return -1;snprintf(name,n,"%s%s",root,git_tree_entry_name(entry));
 int result=0;if(!finder_index_entry(walk->index,name))result=finder_emit(walk->ctx,name,3,0,0);free(name);return result;
}
static int finder_worktree(finder_walk *walk,int fd,const char *prefix,unsigned depth){
 if(depth>256){git_error_set_str(GIT_ERROR_INDEX,"Finder directory depth exceeds budget");return -1;}
 int copy=dup(fd);if(copy<0)return -1;DIR *directory=fdopendir(copy);if(!directory){close(copy);return -1;}
 int result=0;struct dirent *item;
 while((item=readdir(directory))){
  if(!strcmp(item->d_name,".")||!strcmp(item->d_name,"..")||!strcasecmp(item->d_name,".git"))continue;
  if(stopped(walk->ctx)){result=GIT_EUSER;break;}
  if(++walk->visited>100000){git_error_set_str(GIT_ERROR_INDEX,"Finder worktree exceeds path budget");result=-1;break;}
  size_t length=strlen(prefix)+strlen(item->d_name)+1;if(length>1048576){result=-1;break;}
  char *name=malloc(length);if(!name){result=-1;break;}snprintf(name,length,"%s%s",prefix,item->d_name);
  struct stat info;if(fstatat(fd,item->d_name,&info,AT_SYMLINK_NOFOLLOW)<0){free(name);if(errno==ENOENT)continue;result=-1;break;}
  const git_index_entry *indexed=finder_index_entry(walk->index,name);
  if(S_ISDIR(info.st_mode)&&(!indexed||indexed->mode!=GIT_FILEMODE_COMMIT)){
   int child=openat(fd,item->d_name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
   if(child<0){free(name);result=-1;break;}
   struct stat admin;int nested=fstatat(child,".git",&admin,AT_SYMLINK_NOFOLLOW)==0;
   if(nested){if(!indexed)result=finder_emit(walk->ctx,name,4,0,0);}
   else {char *sub=malloc(length+1);if(!sub)result=-1;else{
    snprintf(sub,length+1,"%s/",name);size_t position=0;int found=git_index_find_prefix(&position,walk->index,sub);
    if(found==GIT_ENOTFOUND&&!indexed){git_error_clear();int state=4,ignored=0;git_tree_entry *base=NULL;
     if(walk->full&&walk->tree&&finder_tree_entry(&base,walk->repo,walk->tree,name,walk->ignore_case)==0)state=3;
     else if(walk->full){git_error_clear();result=git_ignore_path_is_ignored(&ignored,walk->repo,sub);if(result==0&&ignored)state=5;}
     git_tree_entry_free(base);if(result==0)result=finder_emit(walk->ctx,name,state,0,0);
    }else if(found<0&&found!=GIT_ENOTFOUND)result=found;
    if(result==0)result=finder_worktree(walk,child,sub,depth+1);free(sub);
   }}
   close(child);
  }else if(!indexed){
   int state=4;git_tree_entry *base=NULL;
   if(walk->full&&walk->tree&&finder_tree_entry(&base,walk->repo,walk->tree,name,walk->ignore_case)==0)state=3;
   else if(walk->full){int ignored=0;git_error_clear();result=git_ignore_path_is_ignored(&ignored,walk->repo,name);if(result==0&&ignored)state=5;}
   git_tree_entry_free(base);if(result==0)result=finder_emit(walk->ctx,name,state,0,0);
  }
  free(name);if(result<0)break;
 }
 closedir(directory);return result;
}
int tg_finder_status(const char *path,int full,int case_sensitive,uint32_t limit_kib,tg_callbacks *callbacks){
 git_repository *repo=NULL;git_index *index=NULL;git_tree *tree=NULL;git_object *head=NULL;int result=0,root=-1;struct stat index_before,index_after;int had_index=0;char *index_path=NULL;
 context ctx={callbacks,NULL,NULL,UINT_MAX,UINT_MAX,UINT_MAX,0};
 if((result=git_repository_open(&repo,path))<0||(result=configure_repository(repo,&ctx))<0||(result=git_repository_index(&index,repo))<0)goto done;
 active_context=&ctx;
 if(!git_repository_workdir(repo)){git_error_set_str(GIT_ERROR_REPOSITORY,"Finder status requires a working tree");result=-1;goto done;}
 root=open(git_repository_workdir(repo),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0){result=-1;goto done;}
 const char *ip=git_index_path(index);if(ip){index_path=strdup(ip);had_index=lstat(ip,&index_before)==0;}
 if((result=git_index_read(index,1))<0)goto done;
 int caps=git_index_caps(index);if(case_sensitive)caps&=~GIT_INDEX_CAPABILITY_IGNORE_CASE;
 if((result=git_index_set_caps(index,caps))<0)goto done;
 if((result=finder_emit(&ctx,NULL,(caps&GIT_INDEX_CAPABILITY_IGNORE_CASE)==0,0,0))<0)goto done;
 if(full){result=git_revparse_single(&head,repo,"HEAD^{tree}");if(result==GIT_EUNBORNBRANCH||result==GIT_ENOTFOUND){git_error_clear();result=0;}else if(result<0)goto done;else tree=(git_tree *)head;}
 uint64_t hash_bytes=0;size_t count=git_index_entrycount(index);if(count>100000){git_error_set_str(GIT_ERROR_INDEX,"Finder index exceeds entry budget");result=-1;goto done;}
 for(size_t i=0;i<count;i++){
  const git_index_entry *entry=git_index_get_byindex(index,i);int state;
  if((result=finder_index_state(repo,entry,caps,root,(uint64_t)limit_kib*1024,&hash_bytes,&ctx,&state))<0)goto done;
  if(full&&(state==0||state==1)){
   git_tree_entry *base=NULL;int found=tree?finder_tree_entry(&base,repo,tree,entry->path,(caps&GIT_INDEX_CAPABILITY_IGNORE_CASE)!=0):GIT_ENOTFOUND;
   if(found==GIT_ENOTFOUND){git_error_clear();state=2;}else if(found<0){result=found;goto done;}else if(!git_oid_equal(git_tree_entry_id(base),&entry->id))state=1;
   git_tree_entry_free(base);
  }
  /* One conflict row per literal name; stage flags must not hide conflicts. */
  if(i&&strcmp(entry->path,git_index_get_byindex(index,i-1)->path)==0)continue;
  if((result=finder_emit(&ctx,entry->path,state,(entry->flags_extended&GIT_INDEX_ENTRY_SKIP_WORKTREE)!=0,(entry->flags&GIT_INDEX_ENTRY_VALID)!=0&&(entry->flags_extended&GIT_INDEX_ENTRY_SKIP_WORKTREE)==0))<0)goto done;
 }
 finder_walk walk={&ctx,repo,index,tree,full,(caps&GIT_INDEX_CAPABILITY_IGNORE_CASE)!=0,0};
 if(tree&&(result=git_tree_walk(tree,GIT_TREEWALK_PRE,finder_deleted,&walk))<0)goto done;
 if((result=finder_worktree(&walk,root,"",0))<0)goto done;
 if(index_path){int exists=lstat(index_path,&index_after)==0;if(exists!=had_index||(exists&&!finder_same_stat(&index_before,&index_after))){git_error_set_str(GIT_ERROR_INDEX,"Finder index changed during collection; retry required");result=-1;goto done;}}
 if(full){git_object *current=NULL;result=git_revparse_single(&current,repo,"HEAD^{tree}");if(!head&&(result==GIT_ENOTFOUND||result==GIT_EUNBORNBRANCH)){git_error_clear();result=0;}else if(result==0&&(!head||!git_oid_equal(git_object_id(head),git_object_id(current)))){git_error_set_str(GIT_ERROR_REFERENCE,"Finder HEAD changed during collection; retry required");result=-1;}git_object_free(current);}
 done:free(index_path);if(root>=0)close(root);git_object_free(head);git_index_free(index);git_repository_free(repo);active_context=NULL;return result;
}
