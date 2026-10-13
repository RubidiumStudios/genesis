package Service::Github::Host;
use strict;
use warnings;

# Whether a host speaks GitHub's API, judged from its own answers (D119, noted
# 2026-10-13).  Nothing is asked to find out: the first real call's headers
# say it, so a run whose home starts empty pays no call for the question.
# github.com is known, and every other host is called at its /api/v3 and
# remembered in ~/.genesis/cache/github-hosts.yml with the kind and version
# it answered with.

use Genesis;
use Genesis::Exit qw/CONFIG/;

use POSIX qw/strftime/;

my %CACHE;       # the cache file's hosts, as last read or written
my $CACHE_STAMP; # the file's identity when they were, to tell a change

# base_for - the API a host is called at {{{
sub base_for {
	my ($host) = @_;
	$host = lc($host // '');
	return $host eq 'github.com'
		? 'https://api.github.com'
		: "https://$host/api/v3";
}

# }}}
# is_github - whether an answer's headers are GitHub's {{{
#
# GitHub sends both on every answer, a 404 included, on github.com and on
# GitHub Enterprise Server, and a proxy or another forge sends neither.  Over
# HTTP/2 they arrive in lower case.
sub is_github {
	my ($headers) = @_;
	return 0 unless defined $headers;
	return $headers =~ /^X-GitHub-(?:Request-Id|Media-Type):/mi ? 1 : 0;
}

# }}}
# enterprise_version - the GitHub Enterprise Server version an answer names {{{
sub enterprise_version {
	my ($headers) = @_;
	return undef unless defined $headers;
	return $headers =~ /^X-GitHub-Enterprise-Version:\s*(\S+)/mi ? $1 : undef;
}

# }}}
# cache_path - where the hosts seen are remembered {{{
sub cache_path {
	return "$ENV{HOME}/.genesis/cache/github-hosts.yml";
}

# }}}
# known - what a host is known to be, or undef {{{
sub known {
	my ($host) = @_;
	$host = lc($host // '');
	return {base => base_for($host), kind => 'github'} if $host eq 'github.com';
	my $entry = _hosts()->{$host};
	return $entry ? {%$entry} : undef;
}

# }}}
# record - remember a host from an answer that was GitHub's {{{
#
# github.com is never recorded, because there is nothing to learn about it.
# The file is written only when what it says of the host would change, so a
# run's calls after its first cost no write.
sub record {
	my ($host, $headers) = @_;
	$host = lc($host // '');
	return if $host eq 'github.com' || !length $host;

	my $version = enterprise_version($headers);
	my $kind    = defined $version ? 'enterprise' : 'github';
	my $base    = base_for($host);

	my $hosts = _hosts();
	my $was   = $hosts->{$host};
	return if $was
		&& ($was->{kind} // '') eq $kind
		&& ($was->{base} // '') eq $base
		&& ($was->{version} // '') eq ($version // '');

	$hosts->{$host} = {
		base => $base,
		kind => $kind,
		(defined $version ? (version => $version) : ()),
		seen => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
	};
	_write($hosts);
	return;
}

# }}}
# forget - stop remembering one host {{{
sub forget {
	my ($host) = @_;
	$host = lc($host // '');
	my $hosts = _hosts();
	return unless exists $hosts->{$host};
	delete $hosts->{$host};
	_write($hosts);
	return;
}

# }}}
# refused - whether an error is this module's refusal {{{
sub refused {
	my ($error) = @_;
	return ref($error) && ref($error) eq 'Service::Github::Host::Refusal' ? 1 : 0;
}

# }}}
# refuse - a host that answered twice, and neither time as GitHub {{{
#
# Outside an eval the refusal is raised as any other is, at CONFIG.  Inside
# one it is an object that carries its exit code, so a reader that catches
# every failure and refuses at UNAVAILABLE can tell this one apart and keep
# its code, because what the operator has to change is the repository's host
# or the provider and not the state of an API.
sub refuse {
	my ($host, $url, $answered) = @_;
	my $message = sprintf(
		"#C{%s} does not answer as GitHub: asked at #C{%s}, it answered #C{%s} ".
		"without GitHub's response headers, and the same again when asked once ".
		"more.\n\nThe pipeline calls GitHub's API, on github.com or on GitHub ".
		"Enterprise Server, whose API is at #C{%s}.  Check that ".
		"#C{pipeline.source_control.repository} names the repository on its ".
		"GitHub host, or use the #C{manual} provider, which calls no API.",
		$host, $url, $answered, base_for($host));
	bail({exitcode => CONFIG}, '%s', $message) unless $^S;
	die bless({exitcode => CONFIG, message => $message, host => $host},
		'Service::Github::Host::Refusal');
}

# }}}
# _hosts - the cache file's hosts, read again only when the file changed {{{
sub _hosts {
	my $path  = cache_path();
	my @stat  = stat($path);
	my $stamp = @stat ? join(':', @stat[0, 1, 7, 9]) : '';
	return \%CACHE if defined $CACHE_STAMP && $CACHE_STAMP eq $stamp;

	my $read = $stamp ? load_yaml_file($path) : undef;
	%CACHE = ref($read) eq 'HASH' ? %$read : ();
	$CACHE_STAMP = $stamp;
	return \%CACHE;
}

# }}}
# _write - put the hosts in the cache file, whole {{{
#
# Written beside the file and renamed over it, so a reader in another process
# meets the old file or the new one and never half of either.
sub _write {
	my ($hosts) = @_;
	my $path = cache_path();
	(my $dir = $path) =~ s{/[^/]+$}{};
	mkdir_or_fail($dir) unless -d $dir;

	my $tmp = "$path.$$.tmp";
	save_to_yaml_file({%$hosts}, $tmp);
	rename($tmp, $path)
		or bail("Could not write the GitHub host cache #C{%s}: %s", $path, $!);

	%CACHE = %$hosts;
	my @stat = stat($path);
	$CACHE_STAMP = join(':', @stat[0, 1, 7, 9]);
	return;
}

# }}}

package Service::Github::Host::Refusal;
use overload '""' => sub {$_[0]{message}}, fallback => 1;

1;
# vim: fdm=marker:foldlevel=1:noet
