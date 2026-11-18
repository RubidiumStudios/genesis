#!/usr/bin/env perl
# Merged and deployed manifests stay out of the trace.  A merged manifest
# is unredacted until it is written out redacted, a deployed manifest and
# its create-env state, store, and vars files carry the director's own
# credentials, and the environment handed to every spruce merge carries
# CREDHUB_SECRET.  None of these values is registered with the logger, so
# each site must keep them out itself.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;
use IO::Compress::Gzip qw/gzip/;
use MIME::Base64 qw/encode_base64/;

use Genesis;
use Genesis::Env;
use Genesis::Env::ManifestProvider;

my $dir = tempdir(CLEANUP => 1);

package FakeManifest {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub has_notice { 0 }
	sub type { 'unredacted' }
	sub _generate_file_name { $_[0]{file} }
	sub file { $_[0]{file} }
	sub data { $_[0]{data} }
	sub redacted { $_[0] }
	sub notify { }
}

package FakeEnv {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub notify { }
	sub path { my ($s, $p) = @_; defined($p) ? "$s->{root}/$p" : $s->{root} }
	sub workpath { my ($s, $p) = @_; defined($p) ? "$s->{root}/work/$p" : "$s->{root}/work" }
	sub name { 'fake-env' }
	sub type { 'fake' }
	sub secrets_base { '/secret/fake/env/' }
}

package main;

my $env = FakeEnv->new(root => $dir);
mkdir "$dir/work";
my $provider = bless({env => $env}, 'Genesis::Env::ManifestProvider');

subtest 'a spruce merge keeps its environment and output out of the trace' => sub {
	my $credhub_secret = fake_secret('credhub-secret');
	my $password       = fake_secret('manifest-password');
	put_file("$dir/source.yml", 0644, "---\nproperties:\n  password: $password\n");
	my $manifest = FakeManifest->new(file => "$dir/merged.yml");
	my ($log, $data);
	$log = capture_trace {
		($data) = $provider->merge($manifest, ["$dir/source.yml"], {},
			{CREDHUB_SECRET => $credhub_secret, GENESIS_ENVIRONMENT => 'fake-env'});
	};
	is($data->{properties}{password}, $password, 'the caller still gets the merged manifest');
	unlike($log, qr/\Q$credhub_secret\E/, 'CREDHUB_SECRET is absent from the trace');
	unlike($log, qr/\Q$password\E/, 'the merged manifest is absent from the trace');
	like($log, qr/CREDHUB_SECRET: <redacted:\d+ bytes>/, 'the key is still named');
	like($log, qr/GENESIS_ENVIRONMENT: fake-env/, 'an allowlisted value is still shown');
};

for my $case (
	['load_yaml',      sub { Genesis::load_yaml("---\npassword: $_[0]\n")->{password} }],
	['load_yaml_file', sub { put_file("$dir/load.yml", 0644, "password: $_[0]\n"); Genesis::load_yaml_file("$dir/load.yml")->{password} }],
	['to_yaml',        sub { Genesis::to_yaml({password => $_[0]}) }],
) {
	my ($name, $code) = @$case;
	subtest "$name keeps the converted data out of the trace" => sub {
		my $value = fake_secret($name);
		my ($log, $out);
		$log = capture_trace { $out = $code->($value) };
		like($out, qr/\Q$value\E/, 'the caller still gets the data');
		unlike($log, qr/\Q$value\E/, 'the data is absent from the trace');
	};
}

subtest 'a failed spruce merge still reports why' => sub {
	put_file("$dir/broken.yml", 0644, "---\nproperties:\n  password: (( grab meta.does-not-exist ))\n");
	my $manifest = FakeManifest->new(file => "$dir/broken-merged.yml");
	my $err;
	capture_trace { eval { $provider->merge($manifest, ["$dir/broken.yml"], {}, {}); 1 } or $err = $@ };
	like($err // '', qr/Unable to merge unredacted manifest for fake-env\/fake environment/, 'the failure is reported');
	like($err // '', qr/spruce exited \d+ \(.*could not resolve a reference.*\)/, 'with the kind of failure');
	like($err // '', qr/\$\.properties\.<key> \(in \Q$dir\E\/broken\.yml, line 3\)/,
		'and where the node spruce could not resolve is');
};

subtest 'an adaptive merge keeps its output out of the trace' => sub {
	my $password = fake_secret('adaptive-password');
	put_file("$dir/adaptive.yml", 0644, "---\nproperties:\n  password: $password\n");
	my ($log, $out);
	$log = capture_trace { $out = $provider->_adaptive_merge({}, "$dir/adaptive.yml") };
	like($out, qr/\Q$password\E/, 'the caller still gets the merged manifest');
	unlike($log, qr/\Q$password\E/, 'the merged manifest is absent from the trace');
};

subtest 'spruce_diff keeps both manifests out of the trace' => sub {
	my $old = fake_secret('diff-old');
	my $new = fake_secret('diff-new');
	# A script(1) that also prints the transcript as plain text, as
	# util-linux script does, so the output is not skipped as binary.
	mkdir "$dir/bin";
	put_file("$dir/bin/script", 0755, <<'SH');
#!/bin/bash
while [[ "$1" == -* ]]; do shift; done
file="$1"; shift
"$@" 2>&1 | tee "$file"
exit "${PIPESTATUS[0]}"
SH
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	local $^O = 'darwin';
	my ($log, $out);
	$log = capture_trace {
		# An added entry: spruce marks a changed value with a non-ASCII
		# character, which run() skips as binary, and that hides the leak.
		($out) = Genesis::spruce_diff(
			{object => {name => 'x', password => $old}},
			{object => {name => 'x', password => $old, new_password => $new}},
		);
	};
	like($out, qr/\Q$new\E/, 'the caller still gets the diff');
	unlike($log, qr/\Q$old\E|\Q$new\E/, 'neither value is in the trace');
};

subtest 'the BOSH variables file is traced by key only' => sub {
	my $value = fake_secret('bosh-var');
	no warnings qw/redefine once/;
	local *Genesis::Env::manifest_provider = sub {
		bless({}, 'FakeProvider')
	};
	local *FakeProvider::deployment = sub {
		FakeManifest->new(file => "$dir/vars.yml", data => {admin_password => $value})
	};
	# bosh interpolate is covered by service_bosh-trace_redaction.t.
	local *Genesis::Env::bosh = sub { bless({}, 'FakeBosh') };
	local *FakeBosh::execute = sub { (Genesis::slurp($_[2]), 0, '') };
	my $log = capture_trace { bless({}, 'Genesis::Env')->vars_file(0, "$dir/vars-out.yml") };
	unlike($log, qr/\Q$value\E/, 'the value is absent from the trace');
	like($log, qr/admin_password/, 'the variable is still named');
};

# last_deployed_manifest reads the director's deployed manifest and its
# create-env files; with the repository store those are local files.
my $mdir = "$dir/repo/.genesis/manifests";
system('mkdir', '-p', $mdir) == 0 or die;

sub deployed_env {
	my (%exodus) = @_;
	my $e = bless({}, 'Genesis::Env');
	no warnings qw/redefine once/;
	return ($e, sub {
		my $code = shift;
		local *Genesis::Env::manifest_store = sub { $exodus{_store} // 'repository' };
		local *Genesis::Env::exodus_lookup  = sub { $exodus{$_[1]} };
		local *Genesis::Env::deployments    = sub { bless({}, 'FakeDeployments') };
		local *FakeDeployments::latest      = sub { undef };
		local *Genesis::Env::notify         = sub { };
		local *Genesis::Env::path           = sub { "$dir/repo/$_[1]" };
		local *Genesis::Env::workpath       = sub { "$dir/work/".($_[1]//'') };
		local *Genesis::Env::name           = sub { 'fake-env' };
		local *Genesis::Env::use_create_env = sub { 1 };
		local *Genesis::Env::prunable_keys  = sub { qw/genesis meta/ };
		$code->();
	});
}

subtest 'deployed create-env files are traced by size only' => sub {
	my $store = fake_secret('store-value');
	my $vars  = fake_secret('vars-value');
	my $state = fake_secret('state-value');
	put_file("$mdir/fake-env.yml", 0644, "---\nname: fake-env\n");
	put_file("$mdir/fake-env-store.yml", 0644, "---\nadmin_password: $store\n");
	put_file("$mdir/fake-env.vars", 0644, "---\nadmin_password: $vars\n");
	put_file("$mdir/fake-env-state.json", 0644, "{\"key\":\"$state\"}\n");
	my ($e, $with) = deployed_env(manifest_type => 'redacted');
	my (%results, $log);
	$log = capture_trace { $with->(sub { %results = $e->last_deployed_manifest(pruned => 0) }) };
	like($results{store}{data}, qr/\Q$store\E/, 'the caller still gets the store contents');
	like($log, qr/Compound Results/, 'the results are still traced');
	unlike($log, qr/\Q$_\E/, 'a create-env value is absent from the trace') for ($store, $vars, $state);
};

subtest 'a deployed manifest from exodus stays out of the trace' => sub {
	my $value = fake_secret('exodus-manifest-value');
	my $manifest = "---\ngenesis:\n  env: fake-env\nmeta:\n  x: y\nproperties:\n  password: $value\n";
	gzip(\$manifest => \my $gz) or die;
	my ($e, $with) = deployed_env(
		_store => 'vault', manifest => encode_base64($gz), manifest_type => 'unredacted',
		manifest_sha1 => 'fake',
	);
	for my $just ('contents', '') {
		my ($log, @results, $scalar);
		$log = capture_trace { $with->(sub { @results = $e->last_deployed_manifest(just => $just) }) };
		unlike($log, qr/\Q$value\E/, "list context, just => '$just': the manifest is absent from the trace");
		next unless $just;
		is($results[0], $manifest =~ s/^---\n//r =~ s/genesis:\n  env: fake-env\nmeta:\n  x: y\n//r =~ s/\n$//r,
			"list context, just => '$just': the caller still gets the pruned manifest");
		$log = capture_trace { $with->(sub { $scalar = $e->last_deployed_manifest(just => $just) }) };
		unlike($log, qr/\Q$value\E/, "scalar context, just => '$just': the manifest is absent from the trace");
		like($scalar, qr/\Q$value\E/, "scalar context: the caller still gets the manifest");
	}
};

done_testing;
