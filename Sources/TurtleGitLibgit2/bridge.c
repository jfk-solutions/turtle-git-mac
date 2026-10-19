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
