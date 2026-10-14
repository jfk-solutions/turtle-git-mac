"""Apply the native askpass bridge to the pinned Git::SVN::Prompt source."""
from pathlib import Path

ADAPTER = r'''
# TurtleGit native SVN prompt adapter, GPL-2.0-or-later.
sub _turtlegit_prompt {
    my ($kind, %data) = @_;
    require JSON::PP;
    require MIME::Base64;
    my $json = JSON::PP->new->utf8->canonical;
    my $request = { version => 1, kind => $kind, %data };
    my $answer = Git::prompt('TurtleGit SVN prompt v1:' . MIME::Base64::encode_base64($json->encode($request), ''), 1);
    die "SVN authentication cancelled\n" unless defined($answer) && length($answer);
    my $response = eval { $json->decode(MIME::Base64::decode_base64($answer)) };
    die "Invalid native SVN response\n" unless ref($response) eq 'HASH' && $response->{version} == 1;
    return $response;
}
'''

def patch(source: str) -> str:
    if '# TurtleGit native SVN prompt adapter' in source: return source
    replacements = [
        ('sub simple {', '''sub simple {
    if ($ENV{TURTLEGIT_SVN_NATIVE_PROMPTS}) {
        my ($cred, $realm, $default, $may_save, $pool) = @_;
        $default = $_username if defined $_username;
        my $answer = _turtlegit_prompt('credentials', realm => ($realm // ''), username => ($default // ''), maySave => (($may_save && !$_no_auth_cache) ? JSON::PP::true() : JSON::PP::false()));
        die "Invalid SVN credentials\\n" unless defined($answer->{username}) && defined($answer->{password});
        $cred->username($answer->{username}); $cred->password($answer->{password});
        $cred->may_save(($answer->{save} && $may_save && !$_no_auth_cache) ? $may_save : undef);
        return $SVN::_Core::SVN_NO_ERROR;
    }'''),
        ('sub ssl_server_trust {', '''sub ssl_server_trust {
    if ($ENV{TURTLEGIT_SVN_NATIVE_PROMPTS}) {
        my ($cred, $realm, $failures, $info, $may_save, $pool) = @_;
        my $answer = _turtlegit_prompt('trust', realm => ($realm // ''), failures => 0 + $failures, hostname => $info->hostname, validFrom => $info->valid_from, validUntil => $info->valid_until, issuer => $info->issuer_dname, fingerprint => $info->fingerprint, maySave => (($may_save && !$_no_auth_cache) ? JSON::PP::true() : JSON::PP::false()));
        return -1 if ($answer->{decision} // '') eq 'reject';
        die "Invalid SVN trust response\\n" unless ($answer->{decision} // '') eq 'temporary' || (($answer->{decision} // '') eq 'permanent' && $may_save && !$_no_auth_cache);
        $cred->accepted_failures($failures); $cred->may_save($answer->{decision} eq 'permanent' ? $may_save : undef);
        return $SVN::_Core::SVN_NO_ERROR;
    }'''),
        ('sub ssl_client_cert {', '''sub ssl_client_cert {
    if ($ENV{TURTLEGIT_SVN_NATIVE_PROMPTS}) {
        my ($cred, $realm, $may_save, $pool) = @_;
        my $answer = _turtlegit_prompt('clientCertificate', realm => ($realm // ''), maySave => JSON::PP::false());
        die "Invalid SVN client certificate\\n" unless defined($answer->{file}) && $answer->{file} =~ m{^/};
        $cred->cert_file($answer->{file}); $cred->may_save(undef);
        return $SVN::_Core::SVN_NO_ERROR;
    }'''),
        ('sub ssl_client_cert_pw {', '''sub ssl_client_cert_pw {
    if ($ENV{TURTLEGIT_SVN_NATIVE_PROMPTS}) {
        my ($cred, $realm, $may_save, $pool) = @_;
        my $answer = _turtlegit_prompt('secret', realm => ($realm // ''), maySave => (($may_save && !$_no_auth_cache) ? JSON::PP::true() : JSON::PP::false()));
        die "Invalid SVN certificate password\\n" unless defined($answer->{password});
        $cred->password($answer->{password}); $cred->may_save(($answer->{save} && $may_save && !$_no_auth_cache) ? $may_save : undef);
        return $SVN::_Core::SVN_NO_ERROR;
    }'''),
        ('sub username {', '''sub username {
    if ($ENV{TURTLEGIT_SVN_NATIVE_PROMPTS}) {
        my ($cred, $realm, $may_save, $pool) = @_;
        my $answer = _turtlegit_prompt('username', realm => ($realm // ''), username => ($_username // ''), maySave => (($may_save && !$_no_auth_cache) ? JSON::PP::true() : JSON::PP::false()));
        die "Invalid SVN username\\n" unless defined($answer->{username});
        $cred->username($answer->{username}); $cred->may_save(($answer->{save} && $may_save && !$_no_auth_cache) ? $may_save : undef);
        return $SVN::_Core::SVN_NO_ERROR;
    }''')]
    for original, replacement in replacements:
        if source.count(original) != 1: raise ValueError('Pinned SVN prompt source changed: ' + original)
        source = source.replace(original, replacement, 1)
    # JSON booleans in call-site arguments must be available before the call itself.
    source = source.replace('require SVN::Core;', 'require SVN::Core;\nrequire JSON::PP;', 1)
    return source.replace('\n1;\n', ADAPTER + '\n1;\n', 1)

def apply(path: Path) -> None:
    path.write_text(patch(path.read_text()))
