package Service::Github;
use strict;
use warnings;

use Genesis;
use Genesis::UI;
use Genesis::Term qw/csprintf/;

use JSON::PP;
use Time::HiRes qw/gettimeofday/;
use Digest::SHA qw/sha1_hex/;

use constant {
	DEFAULT_DOMAIN => 'github.com',
	DEFAULT_ORG    => 'genesis-community',
	DEFAULT_TLS    => 'yes'
};
### Class Methods {{{

# new - create a default github kit provider {{{
sub new {
	my ($class, %config) = @_;
	my $tls = $config{tls} || DEFAULT_TLS;
	$tls = "skip" unless $tls =~ /^(no|yes|skip)$/;

	my $creds;
	if ($ENV{GITHUB_USER} && $ENV{GITHUB_AUTH_TOKEN}) {
		$creds = "$ENV{GITHUB_USER}:$ENV{GITHUB_AUTH_TOKEN}";
	} elsif ($ENV{GITHUB_AUTH_TOKEN}) {
		$creds ="Bearer $ENV{GITHUB_AUTH_TOKEN}"
	}
	bless({
		domain => $config{domain} || DEFAULT_DOMAIN,
		org    => $config{org}    || DEFAULT_ORG,
		creds  => $creds,
		tls    => $tls,
		label  => $config{label}
	}, $class);
}

# }}}
# }}}

### Instance Methods {{{

# get_authorized_user - returns the authorized user for the PAT {{{
sub get_authorized_user {
	my ($self) = @_;
	return unless $self->{creds};
	if ($self->{creds} =~ /^Bearer (.+)$/ || $self->{creds} =~ /^([^:]+):(.+)$/) {
		my ($code,$msg,$data) = curl(
			"GET", $self->base_url . "/user",
			undef, undef, 0, $self->{creds}
		);
		bail("Failed to retrieve user information from Github: %s", $code)
			unless $code == 200;
		my $user_info = undef;
		eval {
			$user_info = load_json($data); 1
		} or bail("Failed to read user information from Github: %s", $@);
		return $user_info->{login};
	} else {
		return '';
	}
}

# }}}
# check - checks the availability of this provider {{{
sub check {
	my ($self, $url, $ref) = @_;
	my $status;
	$url ||= $self->repos_url;
	$ref ||= $url;
	my ($code, $msg) = curl("HEAD", $url, undef, undef, 0, $self->{creds});
	if ($code == 404) {
		$status =  "Could not find $ref; are you able to route to the Internet?\n";
	} elsif ($code == 403) {
		$status = "Access forbidden trying to reach $ref; throttling may be in effect.  Set your GITHUB_USER and GITHUB_AUTH_TOKEN to prevent throttling.\n";
	} elsif ($code != 200) {
		$status = "Could not read $ref at $url; returned ($code):\n ".$msg."\n";
	}
	return wantarray ? ($code,$status) : $status;
}

# }}}
# label - description of the current github connection, defaults to domain/org {{{
sub label {
	return $_[0]->{label} || $_[0]->{domain}."/".$_[0]->{org};
}

# }}}
# repos_url - The url required to fetch the repos for this provider {{{
sub repos_url {
	my ($self, $page) = @_;
	my $url = sprintf("%s/users/%s/repos", $self->base_url, $self->{org});
	$url .= "?page=$page" if $page;
	return $url;
}

# }}}
# releases_url - The url required to fetch the list of releases for a given kit on this provider {{{
sub releases_url {
	my ($self, $name, $page) = @_;
	my $url = sprintf("%s/repos/%s/%s/releases",$self->base_url,$self->{org},$name);
	$url .= "?page=$page" if $page;
	return $url;
}
# }}}
# release_version_urls - The urls required to fetch the release information for a specific version of a kit on this provider {{{
sub release_version_urls {
	my ($self, $name, $version) = @_;
	# Iterate over release tag urls, with and without the 'v' prefix
	$version =~ s/^v//;
	return [
		map {
			sprintf("%s/repos/%s/%s/releases/tags/%s",$self->base_url,$self->{org},$name,$_)
		} ($version, "v$version")
	];
}
# }}}
# base_url - the base url under which all requests are made {{{
sub base_url {
	my ($self) = @_;
	sprintf("%s://api.%s", ($self->{tls} eq 'no' ? "http" : "https"), $self->{domain});
}

# }}}
# repos - contents of the github orgs repos {{{
sub repos {
	my ($self,$refresh) = @_;
	unless (defined($self->{_repos}) && !$refresh) {
		my $status = $self->check;
		bail $status."\n" if $status;

		$self->{_repos} = [];
		my $page = 1;
		while (1) {
			my ($code, $msg, $data) = curl("GET", $self->repos_url($page), undef, undef, 0, $self->{creds});
			my $results;
			eval {
				$results = load_json($data);
				1
			} or bail("Failed to read repository information from #M{%s} org: %s", $self->label, $@);
			last unless ref($results) eq "ARRAY" && scalar(@$results) > 0;
			push @{$self->{_repos}}, @$results;
			$page++;
		}
	}
	return $self->{_repos};
}

# }}}
# repo_names - return a list of repositories under the organization {{{
sub repo_names {
	my ($self, $filter) = @_;
	$filter ||= qr/.*/;
	return [
		grep {$_ =~ $filter}
		map  {$_->{name}}
		@{$self->repos}
	];
}

# }}}
# releases - retrieves a list of releases for a repository {{{
sub releases {
	my ($self, $name, $prefix) = @_;

	bail("Missing repository name") unless $name;

	$prefix //='';

	$self->{_releases} ||= {};
	unless (defined($self->{_releases}{$name})) {
		my $url = $self->releases_url($name);
		my ($code, $status) = $self->check($url);
		if ($code == 404) {
			# Check if kit exists, for a better error message
			bail("No repository named #C{%s} exists under #M{%s}", $name, $self->label)
				if (! grep {$_ eq $name} @{$self->repo_names});
		}
		bail "$status"."\n" if $status;
		trace "About to get releases from Github";

		$self->get_release_info($name, label => $self->label, prefix => $prefix);
	}

	return @{$self->{_releases}{$name}};
}

# }}}
# get_release_info - fetch all release information for the given repository {{{
sub get_release_info {
	my ($self, $name, %opts) = @_;
	my ($code,$msg,$data,$headers,@results);
	my $prefix = $opts{prefix} // '';
	my $label =  $opts{label} || $self->label || "repository #C{$name}";
	my $fatal = $opts{fatal} if defined($opts{fatal});
	my $get_versions = exists($opts{versions});
	my $versions = ($opts{versions}//[]) if $get_versions;
	my $suppress_output = exists($opts{msg}) && ! defined($opts{msg});
	my $suppress_errors = $opts{suppress_errors} // 0;

	return $self->{_releases}{$name}
		if (defined($self->{_releases}{$name}) && !$get_versions);

	bug(
		"Must specify at least one version to retrieve when using the 'versions' option"
	) if $get_versions && !@$versions;

	my $time = gettimeofday;
	if (exists($opts{msg})) {
		info {pending=>1}, $opts{msg} unless $suppress_output;
	} else {
		info({pending=>1},
			"%s%setrieving list of %s releases for #M{%s} kit on #C{%s}",
			$prefix, $prefix ? 'r' : 'R',
			$get_versions ? 'requested' : 'available',
			$name, $label
		)
	}

	my $urls = $get_versions
		? $self->release_version_urls($name, $versions->[0])
		: [$self->releases_url($name)];

	my $pages = 0;
	my @retrieved_versions = ();
	my @errors;
	while (1) {
		if ($get_versions && $self->{_release_versions}{$name}{$versions->[0]}) {
			push @retrieved_versions, shift @$versions;
			last unless @$versions;
			next;
		}

		last unless @$urls;
		my $url = shift @$urls;

		($code, $msg, $data, $headers) = curl("GET", $url, undef, undef, 0, $self->{creds});
		$msg =~ s/\s*$//;
		if ($code != 200) {
			if ($code == 404 && $get_versions) {
				if ($url =~ /v\Q$versions->[0]\E/) {
					next;
				}
			}
			bail(
				"Failed to retrieve release information for #M{%s}; Github responded with a #R{%s} status:\n#y{%s}\n\nURL: %s",
				$get_versions ? $name.'/'.$versions->[0] : $name,
				$code, $msg, $url
			) if $fatal;

			error(
				"Could not find %s release information - got %s status from Github.",
				$get_versions ? $name.'/'.$versions->[0] : $name, $code
			) unless $suppress_output || $suppress_errors;
			push @errors, {
				code => $code,
				data => $data,
				url  => $url,
				msg  => $msg eq $code
					? csprintf(
						"Failed to retrieve release information for #M{%s}; Github responded with a #R{%s} status:\n#y{%s}\n\nURL: %s",
						$get_versions ? $name.'/'.$versions->[0] : $name,
						$code,  $data, $url
					): $msg
				}
		}
		my $results;
		eval {$results = load_json($data); 1};
		if (my $err = $@) {
			my $err_msg = "Failed to read releases information from Github: $err";
			bail($err_msg) if $fatal;
			push @errors, $err_msg;
		}

		info({pending=>1}, '.') unless $suppress_output;
		$pages++;
		if ($get_versions) {
			$self->{_release_versions}{$name}{$versions->[0]} = $results;
			push @retrieved_versions, shift @$versions;
			last unless @$versions;
			$urls = $self->release_version_urls($name, $versions->[0] =~ s/^v?/v/r);
			next
		} else {
			if (ref($results) eq 'ARRAY') {
				push(@results, @{$results});
			} elsif (defined $results) {
				push @errors, {
					code => $code,
					data => $data,
					url  => $url // '',
					msg  => "Unexpected non-array response from Github"
				};
			}
			my ($links) = grep {$_ =~ s/^Link: //i} split(/[\r\n]+/, $headers);
			last unless $links;
			$url = (grep {$_ =~ s/^<(.*)>; rel="next"/$1/} split(', ', $links))[0];
			last unless $url;
			push @$urls, $url;
		}

	}
	info(
		"#G{ done}".pretty_duration(gettimeofday - $time, 0.5*$pages, 1.5*$pages)
	) unless $suppress_output;

	return ($get_versions
		? [map {$self->{_release_versions}{$name}{$_}} @retrieved_versions]
		: ($self->{_releases}{$name} = \@results),
		\@errors
	)
}

# }}}
# versions - retrieves a list of versions for the given repository name{{{
sub versions {
	my ($self, $name, %opts) = @_;

	# If specific version is specified, normalize it, and don't filter out drafts
	# or prereleases
	if ($opts{version}) {
		if ($opts{version} eq 'latest') {
			$opts{latest} = 1;
			$opts{version} = undef;
		} else {
			$opts{version} =~ s/^v//;
			$opts{include_drafts} = $opts{include_prereleases} = 1;
		}
	}

	my @releases =
		grep {!$opts{version}   || $_->{tag_name} =~qr/^v?$opts{version}$/}
		grep {!$_->{draft}      || $opts{'include_drafts'}}
		grep {!$_->{prerelease} || $opts{'include_prereleases'}}
		$self->releases($name);

	if (defined $opts{latest}) {
		my $latest = $opts{latest} || 1;
		my @versions = (reverse sort by_semver (map {$_->{tag_name}} @releases))[0..($latest-1)];
		@releases = grep {my $v = $_->{tag_name}; grep {$_ eq $v} @versions} @releases;
	}
	my $asset_filter=$opts{"asset_filter"} || qr/^$name$/;
	return map {
		my $r = $_;
		(my $v = $r->{tag_name}) =~ s/^v//;
		(my $af = $asset_filter) =~ s/\[#version#\]/$v/;
		my $asset = (grep {$_->{name} =~ $af} @{$r->{assets}})[0];
		scalar({
			version    => $v,
			body       => $r->{body},
			draft      => !!$r->{draft},
			prerelease => !!$r->{prerelease},
			date       => $r->{published_at} || $r->{created_at},
			url        => $asset->{browser_download_url} || "",
			filename   => $asset->{name} || ""
		});
	} @releases;
}
# fetch_release - fetches the release tarball for the specified version of the given repository {{{
sub fetch_release {
	my ($self, $name, $version, $path, $force) = @_;

	if (!defined($version) || $version eq 'latest') {
		# Better to call `latest_version` prior to this, but this is a safety valve.
		$version = $self->latest_version_of($name);
		bail("No latest version of $name repository found with a downloadable release")
			unless $version;
	} else {
		$version =~ s/^v//;
	}

	my $version_info = (
		grep {$_->{version} eq $version}
		$self->versions($name, include_drafts => 1, include_prereleases => 1)
	)[0];
	bail(
		"Release %s/%s was not found",
		$name, $version
	) unless $version_info && ref($version_info) eq 'HASH';

	my $url = $version_info->{url};
	bail(
		"Release %s/%s was found but is missing its resource url.\n".
		"It may have been revoked (see release notes below):\n\n%s\n",
		$name, $version, $version_info->{body}
	) unless $url;

	info({pending => 1},
		"Downloading v%s of #M{%s} from #C{%s} ... ",
		$version,$name,$self->label
	);
	my ($code, $msg, $data) = curl("GET", $url);
	bail(
		"Failed to download %s/%s from %s: returned a %s status code\n",
		$name, $version, $self->label, $code
	) unless $code == 200;
	info "#G{done.}";

	my $file = "$path/$version_info->{filename}";
	if (-f $file) {
		if (! $force) {
			my $old_data = slurp($file);
			if (sha1_hex($data) eq sha1_hex($old_data)) {
				warning(
					"Exact same release already exists under #C{%s} - no change.\n",
					humanize_path($path)
				);
				exit 0
			} else {
				error "Release $name/$version already exists, but is different!";
				die_unless_controlling_terminal;
				my $overwrite = prompt_for_boolean("Do you want to overwrite the existing file with the content downloaded from\n$self->{label}",0);
				bail "Aborted!\n" unless $overwrite;
			}
		}
		chmod_or_fail(0600, $file);
	}
	mkfile_or_fail($file, 0444, $data);

	# TODO: Add to gt
	debug("downloaded release #M{%s}/#C{%s}: %s bytes", $name, $version, length($data));

	return ($name,$version,$file);
}
# }}}
# latest_version_of - The actual version for the latest release of the given repository {{{
sub latest_version_of {
	my ($self, $name, %opts) = @_;
	bail("Missing name for retrieving release") unless $name;
	my $version = (
		grep {$_->{url}}
		$self->versions($name, latest => 1, include_drafts => $opts{include_drafts}, include_prereleases => $opts{include_prereleases})
	)[0];
	return $version && $version->{version};
}

# }}}
# get_user_ssh_keys - fetch SSH public keys for a user {{{
sub get_user_ssh_keys {
	my ($self, $username) = @_;
	bail("Missing username for SSH key retrieval") unless $username;

	# Validate username format (GitHub/GitLab compatible)
	# GitHub: 1-39 chars, alphanumeric or hyphens, cannot start/end with hyphen
	# GitLab: more permissive, but we use stricter GitHub rules for safety
	bail("Invalid username format: $username")
		unless $username =~ /^[a-zA-Z0-9](?:[a-zA-Z0-9]|-(?=[a-zA-Z0-9])){0,38}$/;

	# Construct URL for .keys endpoint (works for GitHub, GitLab, Gitea, etc.)
	my $url = sprintf("%s://%s/%s.keys",
		($self->{tls} eq 'no' ? "http" : "https"),
		$self->{domain},
		$username
	);

	my ($code, $msg, $data) = curl(
		"GET", $url, undef, undef,
		$self->{tls} eq 'skip' ? 1 : 0,
		$self->{creds}
	);

	# Handle HTTP errors
	return (undef, "User '$username' not found on $self->{domain}") if $code == 404;
	return (undef, "Rate limit exceeded (HTTP 403). Set GITHUB_AUTH_TOKEN to increase limit.") if $code == 403;
	return (undef, "HTTP Error $code: $msg") if $code != 200;

	# Parse and validate SSH keys
	my @valid_keys =
		grep { $self->validate_ssh_key($_) }
		grep { /\S/ }
		split /\n/, $data;

	return (\@valid_keys, undef);
}

# }}}
# validate_ssh_key - validate SSH public key format {{{
sub validate_ssh_key {
	my ($self, $key) = @_;
	return 0 unless defined $key;
	return $key =~ /^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)\s+[A-Za-z0-9+\/]+[=]{0,3}(\s+.+)?$/;
}

# }}}
# pulls_url - URL for the GitHub pull requests API {{{
#
#   $gh->pulls_url('org/repo')         # list endpoint
#   $gh->pulls_url('org/repo', 42)     # single-PR endpoint
sub pulls_url {
	my ($self, $owner_repo, $number) = @_;
	my $url = sprintf("%s/repos/%s/pulls", $self->base_url, $owner_repo);
	$url .= "/$number" if defined $number;
	return $url;
}

# }}}
# list_prs - list pull requests for a repository {{{
#
# Options:
#   state  - 'open' (default), 'closed', or 'all'
#   head   - filter by head branch (bare branch name; owner: prefix added automatically)
#   base   - filter by base (target) branch
#
# Returns an arrayref of PR objects from the GitHub API.
sub list_prs {
	my ($self, $owner_repo, %opts) = @_;
	bail("Missing owner/repo for list_prs") unless $owner_repo;

	my $state = $opts{state} || 'open';
	my $url   = $self->pulls_url($owner_repo) . "?state=$state&per_page=100";
	$url .= "&base=" . $opts{base} if $opts{base};
	# GitHub requires owner:branch format for cross-fork head filter
	if ($opts{head}) {
		my ($owner) = split m{/}, $owner_repo;
		$url .= "&head=$owner:$opts{head}";
	}

	my @all_prs;
	while ($url) {
		my ($code, $msg, $data, $headers) = curl("GET", $url, undef, undef, 0, $self->{creds});
		bail(
			"Failed to list pull requests for #C{%s}: HTTP %s - %s",
			$owner_repo, $code, $msg
		) unless $code == 200;

		my $page;
		eval { $page = load_json($data); 1 }
			or bail("Failed to parse pull request list from GitHub: %s", $@);
		push @all_prs, @$page if ref($page) eq 'ARRAY';

		# Follow Link: <url>; rel="next" pagination header
		$url = undef;
		if ($headers) {
			my ($link_hdr) = grep { s/^Link:\s*//i } split /[\r\n]+/, $headers;
			if ($link_hdr) {
				($url) = grep { s/^<(.*)>; rel="next"$/$1/ } split /,\s*/, $link_hdr;
			}
		}
	}
	return \@all_prs;
}

# }}}
# open_prs - list open PRs against a base branch (head optional) {{{
#
# Semantic wrapper around list_prs for the rolling-branch PR
# propagation flow.  Caller decides what 0/1/many means; this
# method just returns the filtered list with state=open enforced.
#
#   $gh->open_prs($owner_repo, $base)           # all open PRs targeting $base
#   $gh->open_prs($owner_repo, $base, $head)    # filtered to PRs from $head
#
# Returns an arrayref.  When $head is provided the server-side
# filter is applied AND a defensive grep filters the response (in
# case the API surfaces unrelated results from pagination edge cases
# or fork heads).
sub open_prs {
	my ($self, $owner_repo, $base, $head) = @_;
	bail("Missing owner/repo for open_prs") unless $owner_repo;
	bail("Missing base branch for open_prs") unless defined $base && length $base;

	my %opts = (state => 'open', base => $base);
	$opts{head} = $head if defined $head && length $head;

	my $prs = $self->list_prs($owner_repo, %opts);
	return $prs unless defined $head && length $head;

	# Defensive: ensure every returned PR actually has head=$head.
	# Pagination, fork heads, or future API changes could surface
	# unrelated PRs; this grep keeps the contract tight.
	return [ grep { ($_->{head}{ref} // '') eq $head } @$prs ];
}

# }}}
# create_pr - create a pull request {{{
#
# Required options: head (source branch), base (target branch), title
# Optional:         body
#
# Returns the PR object (hashref) from the GitHub API.
sub create_pr {
	my ($self, $owner_repo, %opts) = @_;
	bail("Missing owner/repo for create_pr")  unless $owner_repo;
	bail("Missing head branch for create_pr") unless $opts{head};
	bail("Missing base branch for create_pr") unless $opts{base};
	bail("Missing title for create_pr")       unless $opts{title};

	my $payload = JSON::PP->new->encode({
		title => $opts{title},
		body  => $opts{body} // '',
		head  => $opts{head},
		base  => $opts{base},
	});

	my ($code, $msg, $data) = curl(
		"POST", $self->pulls_url($owner_repo),
		{'Content-Type' => 'application/json'}, $payload, 0, $self->{creds}
	);
	bail(
		"Failed to create pull request for #C{%s}: HTTP %s - %s",
		$owner_repo, $code, $msg
	) unless $code == 201;

	my $pr;
	eval { $pr = load_json($data); 1 }
		or bail("Failed to parse create_pr response from GitHub: %s", $@);
	return $pr;
}

# }}}
# update_pr - update an existing pull request {{{
#
# opts: title, body, state ('open' or 'closed')
#
# Returns the updated PR object.
sub update_pr {
	my ($self, $owner_repo, $number, %opts) = @_;
	bail("Missing owner/repo for update_pr") unless $owner_repo;
	bail("Missing PR number for update_pr")  unless defined $number;

	my %update;
	$update{title} = $opts{title} if defined $opts{title};
	$update{body}  = $opts{body}  if defined $opts{body};
	$update{state} = $opts{state} if defined $opts{state};

	my $payload = JSON::PP->new->encode(\%update);
	my ($code, $msg, $data) = curl(
		"PATCH", $self->pulls_url($owner_repo, $number),
		{'Content-Type' => 'application/json'}, $payload, 0, $self->{creds}
	);
	bail(
		"Failed to update pull request #%d for #C{%s}: HTTP %s - %s",
		$number, $owner_repo, $code, $msg
	) unless $code == 200;

	my $pr;
	eval { $pr = load_json($data); 1 }
		or bail("Failed to parse update_pr response from GitHub: %s", $@);
	return $pr;
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
