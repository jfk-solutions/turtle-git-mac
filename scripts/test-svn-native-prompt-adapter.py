#!/usr/bin/env python3
"""Exercise the shipped Perl callback bridge without a public SVN server or secrets."""
import argparse, os, platform, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('runtime',type=Path);a=p.parse_args()
slice=a.runtime.resolve()/'libexec/git-svn-runtime'/platform.machine()
code=r'''
use strict;
use warnings;
use JSON::PP;
use MIME::Base64;
require SVN::Core;
require Git::SVN::Prompt;
package FakeCredential;
sub new { bless {}, shift }
sub username { my $s=shift; $s->{username}=shift if @_; $s->{username} }
sub password { my $s=shift; $s->{password}=shift if @_; $s->{password} }
sub may_save { my $s=shift; $s->{save}=shift if @_; $s->{save} }
sub cert_file { my $s=shift; $s->{file}=shift if @_; $s->{file} }
sub accepted_failures { my $s=shift; $s->{failures}=shift if @_; $s->{failures} }
package FakeCertificate;
sub hostname { 'fixture.invalid' } sub valid_from { 'from' } sub valid_until { 'until' }
sub issuer_dname { 'private fixture issuer' } sub fingerprint { 'AA:BB:CC' }
package main;
our ($request, $decision) = (undef, 'temporary');
{ no warnings 'redefine'; *Git::prompt = sub {
    my ($text)=@_; return 'legacy-name' if $text eq 'Username: ';
    die 'Protocol prefix absent' unless index($text, 'TurtleGit SVN prompt v1:') == 0;
    $request=decode_json(decode_base64(substr($text,length('TurtleGit SVN prompt v1:'))));
    die 'Protocol version' unless $request->{version}==1;
    return encode_base64(encode_json({version=>1,username=>'fixture-name',password=>'fixture-response',save=>JSON::PP::true,decision=>$decision,file=>'/private/owned/fixture.p12'}),'');
}; }
$ENV{TURTLEGIT_SVN_NATIVE_PROMPTS}=1;
my $cred=FakeCredential->new;
Git::SVN::Prompt::simple($cred,'fixture realm','default',1,undef);
die 'Credentials mapping' unless $cred->{username} eq 'fixture-name' && $cred->{password} eq 'fixture-response' && $cred->{save};
{ local $Git::SVN::Prompt::_no_auth_cache=1; Git::SVN::Prompt::simple($cred,'fixture realm','default',1,undef); die 'No-cache mapping' if $cred->{save} || $request->{maySave}; }
my $info=bless {}, 'FakeCertificate';
Git::SVN::Prompt::ssl_server_trust($cred,'fixture realm',0x40000008,$info,1,undef);
die 'Trust mapping' unless $cred->{failures}==0x40000008 && !$cred->{save} && $request->{fingerprint} eq 'AA:BB:CC';
$decision='permanent';Git::SVN::Prompt::ssl_server_trust($cred,'fixture realm',8,$info,1,undef);die 'Permanent mapping' unless $cred->{save};
$decision='reject';die 'Reject mapping' unless Git::SVN::Prompt::ssl_server_trust($cred,'fixture realm',8,$info,1,undef)==-1;
Git::SVN::Prompt::ssl_client_cert($cred,'fixture realm',1,undef);die 'Ephemeral file mapping' unless $cred->{file} eq '/private/owned/fixture.p12' && !$cred->{save};
Git::SVN::Prompt::ssl_client_cert_pw($cred,'fixture realm',1,undef);die 'Certificate password mapping' unless $request->{kind} eq 'secret' && $cred->{password} eq 'fixture-response';
Git::SVN::Prompt::username($cred,'fixture realm',1,undef);die 'Username mapping' unless $request->{kind} eq 'username';
delete $ENV{TURTLEGIT_SVN_NATIVE_PROMPTS};Git::SVN::Prompt::username($cred,'',0,undef);die 'Legacy fallback' unless $cred->{username} eq 'legacy-name';
print "PASS shipped SVN prompt callbacks: credentials, no-cache, certificate details/flags/temporary/permanent/reject, ephemeral client certificate, passphrase, username and legacy fallback\n";
'''
env=os.environ.copy();env['PERL5LIB']=str(slice/'GitPerl');env.pop('PERL5OPT',None);env.pop('PERLLIB',None)
with tempfile.TemporaryDirectory(prefix='TurtleGitSVNPromptAdapter-') as work:
 script=Path(work)/'callbacks.pl';script.write_text(code)
 subprocess.run([str(slice/'Perl/bin/perl'),str(script)],env=env,check=True,timeout=60)
