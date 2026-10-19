// SPDX-License-Identifier: GPL-2.0-or-later
#include "bridge.h"
#include <git2.h>
#include <git2/sys/config.h>
#include <git2/sys/errors.h>
#include <git2/sys/repository.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
typedef struct {tg_callbacks *callbacks;const char *origin;const char *ssh_command;unsigned int received,indexed,completed;unsigned int recursion;const char *configuration_directory;unsigned int push_rejections;} context;
static int stopped(context *ctx);
static context *active_context;
// Called only by our private static libgit2 HTTP request patch. Strings use
// malloc ownership and are released by the transport before the next request.
int turtlegit_http_configuration(const char *url,char ***headers,size_t *count,char **proxy){
 context *ctx=active_context;if(!ctx||stopped(ctx))return GIT_EUSER;
 if(!ctx->callbacks->http)return 0;
 int result=ctx->callbacks->http(url,ctx->configuration_directory,headers,count,proxy,ctx->callbacks->payload);
 if(result<0)git_error_set_str(GIT_ERROR_CONFIG,"Cannot read captured HTTP transport configuration");return result;
}
int tg_git_init(void){int result=git_libgit2_init();if(result>=0&&getenv("GIT_CONFIG_GLOBAL")){int options=git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH,GIT_CONFIG_LEVEL_XDG,"");if(options<0)return options;}return result;}
void tg_git_shutdown(void){git_libgit2_shutdown();}
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
static void checkout_progress(const char *path,size_t completed,size_t total,void *payload){(void)path;context *ctx=payload;if(!total)return;unsigned int percent=(unsigned int)(completed*100/total);if(percent==ctx->completed)return;ctx->completed=percent;char line[160];snprintf(line,sizeof(line),"Updating files: %u%% (%zu/%zu)\r",percent,completed,total);emit(ctx,line);}
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
static int remote_ready(git_remote *remote,int direction,void *payload){context *ctx=payload;if(stopped(ctx))return GIT_EUSER;const char *url=direction==GIT_DIRECTION_PUSH?git_remote_pushurl(remote):NULL;if(!url)url=git_remote_url(remote);if(ctx->callbacks->url)ctx->callbacks->url(url,ctx->callbacks->payload);return 0;}
static int tips(const char *name,const git_oid *old,const git_oid *new,void *payload){context *ctx=payload;if(stopped(ctx))return GIT_EUSER;char line[1024],a[GIT_OID_MAX_HEXSIZE+1],b[GIT_OID_MAX_HEXSIZE+1];git_oid_tostr(a,sizeof(a),old);git_oid_tostr(b,sizeof(b),new);snprintf(line,sizeof(line)," %.*s..%.*s %s\n",8,a,8,b,name);emit(ctx,line);return 0;}
static void remote_callbacks(git_remote_callbacks *options,context *ctx){git_remote_init_callbacks(options,GIT_REMOTE_CALLBACKS_VERSION);options->sideband_progress=sideband;options->transfer_progress=transfer;options->credentials=credentials;options->certificate_check=certificate;options->remote_ready=remote_ready;options->update_tips=tips;options->payload=ctx;}
static void checkout_options(git_checkout_options *options,context *ctx){options->progress_cb=checkout_progress;options->progress_payload=ctx;options->notify_cb=checkout_notify;options->notify_payload=ctx;options->notify_flags=GIT_CHECKOUT_NOTIFY_ALL;}
// APP-level command configuration is read-only: libgit2 writes still target
// repository config. Never persist transient -c or counted environment options.
static int configure_repository(git_repository *repository,context *ctx){
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
static int update_submodule(git_submodule *submodule,const char *name,void *payload){context *ctx=payload;if(stopped(ctx))return GIT_EUSER;char line[1024];snprintf(line,sizeof(line),"Submodule '%s'\n",name);emit(ctx,line);git_repository *prepared=NULL;int preparation=git_submodule_init(submodule,0);if(preparation<0)return preparation;preparation=git_submodule_repo_init(&prepared,submodule,1);if(preparation<0)return preparation;preparation=configure_repository(prepared,ctx);if(preparation<0){git_repository_free(prepared);return preparation;}git_submodule_update_options options=GIT_SUBMODULE_UPDATE_OPTIONS_INIT;remote_callbacks(&options.fetch_opts.callbacks,ctx);options.fetch_opts.proxy_opts.type=GIT_PROXY_AUTO;options.fetch_opts.proxy_opts.credentials=credentials;options.fetch_opts.proxy_opts.certificate_check=certificate;options.fetch_opts.proxy_opts.payload=ctx;checkout_options(&options.checkout_opts,ctx);int result=git_submodule_update(submodule,1,&options);git_repository_free(prepared);if(result<0)return result;git_repository *child=NULL;if((result=git_submodule_open(&child,submodule))<0)return result;result=recursive_update(child,ctx);git_repository_free(child);return result;}
static int recursive_update(git_repository *repository,context *ctx){if(ctx->recursion>=64){git_error_set_str(GIT_ERROR_SUBMODULE,"Submodule recursion limit exceeded");return -1;}ctx->recursion++;int result=configure_repository(repository,ctx);if(result==0)result=git_submodule_foreach(repository,update_submodule,ctx);ctx->recursion--;return result;}
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
 git_fetch_options options=GIT_FETCH_OPTIONS_INIT;remote_callbacks(&options.callbacks,ctx);options.depth=depth;options.proxy_opts.type=GIT_PROXY_AUTO;options.proxy_opts.credentials=credentials;options.proxy_opts.certificate_check=certificate;options.proxy_opts.payload=ctx;options.download_tags=(git_remote_autotag_option_t)tags;options.prune=(git_fetch_prune_t)prune;git_strarray specs={(char **)refspecs,count};
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
