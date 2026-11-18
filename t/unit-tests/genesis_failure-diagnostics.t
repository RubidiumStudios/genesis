#!/usr/bin/env perl
# A failed command that handles credentials can print them: a failed
# merge can quote a resolved value, a failed credential write can echo
# the value it was given, and a parser can quote the input it choked on.
# Each failure here is staged by a fake command that writes a distinct
# made-up marker to both stdout and stderr.  The failure must report its
# exit status and a diagnostic that is safe to show, and neither marker
# may reach the error, the terminal, or the log.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Env::ManifestProvider;
use Service::Credhub;
use Service::BOSH::Director;
use Service::Vault;
use Genesis::Env;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
mkdir "$dir/work";
for my $name (qw/spruce credhub bosh safe/) {
	put_file("$dir/bin/$name", 0755, <<"EOS");
#!/bin/bash
printf 'stdout: \$.properties.password: %s\\n' "\$FAKE_OUT"
printf 'stderr: permission denied for %s\\n' "\$FAKE_ERR" >&2
exit 2
EOS
}

package FakeManifest {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub has_notice { 0 }
	sub type { 'unredacted' }
	sub _generate_file_name { $_[0]{file} }
	sub file { $_[0]{file} }
	sub notify { }
}
package FakeEnv {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub notify { }
	sub path { my ($s, $p) = @_; defined($p) ? "$s->{root}/$p" : $s->{root} }
	sub workpath { my ($s, $p) = @_; defined($p) ? "$s->{root}/work/$p" : "$s->{root}/work" }
	sub name { 'fake-env' }
	sub type { 'fake' }
}
package main;

my $provider = bless({env => FakeEnv->new(root => $dir)}, 'Genesis::Env::ManifestProvider');
put_file("$dir/source.yml", 0644, "---\nproperties: {}\n");

# fails_privately - run $code, which must fail, and check what it exposed
sub fails_privately {
	my ($what, $code, %expect) = @_;
	my ($out_marker, $err_marker) = map {fake_secret("$what-$_")} qw/out err/;
	local $ENV{FAKE_OUT} = $out_marker;
	local $ENV{FAKE_ERR} = $err_marker;
	local $ENV{PATH} = "$dir/bin:$ENV{PATH}";
	my ($died, $result);
	my ($log, $stderr, $stdout) = capture_trace {
		eval { $result = $code->(); 1 } or $died = "$@";
	};
	my $error = $expect{returns} ? ($result // '') : ($died // '');
	ok(length($error), "$what: the failure is reported");
	for my $marker ($out_marker, $err_marker) {
		unlike($error,  qr/\Q$marker\E/, "$what: the error leaves out what the command printed");
		unlike($stderr, qr/\Q$marker\E/, "$what: so does the terminal");
		unlike($stdout, qr/\Q$marker\E/, "$what: and stdout");
		unlike($log,    qr/\Q$marker\E/, "$what: and the log");
	}
	like($error.$stderr, qr/exit(?:ed)? (?:code |status )?2/, "$what: the exit status is reported");
	like($error.$stderr, qr/permission denied/, "$what: with a diagnostic that is safe to show");
}

fails_privately('full merge', sub {
	$provider->merge(FakeManifest->new(file => "$dir/merged.yml"), ["$dir/source.yml"], {}, {});
});

fails_privately('adaptive merge', sub {
	$provider->_adaptive_merge({}, "$dir/source.yml");
});

my $credhub = bless({
	name => 'fake', base => '/fake/', url => 'https://10.0.0.6:8844',
	username => 'credhub-admin', password => 'not-under-test', ca_cert => 'ca',
}, 'Service::Credhub');

fails_privately('yaml conversion', sub {
	Genesis::to_yaml({properties => {password => 'not-the-marker'}});
});

subtest 'exodus write' => sub {
	my $vault = bless({url => 'https://10.0.0.5', name => 'fake'}, 'Service::Vault');
	no warnings qw/redefine once/;
	local *Service::Vault::authenticate = sub { 1 };
	local *Service::Vault::authenticated = sub { 1 };
	local *Service::Vault::read_flattened_secret = sub { {} };
	local *Genesis::Env::vault = sub { $vault };
	local *Genesis::Env::exodus_base = sub { 'secret/exodus/fake-env/fake' };
	local *Genesis::Env::extract_manifest_exodus = sub { {admin_password => 'not-the-marker'} };
	local *Genesis::Env::manifest_store = sub { 'exodus' };
	local *Genesis::Env::deployments = sub { bless({}, 'FakeDeployments') };
	local *FakeDeployments::next_sequence_number = sub { 1 };
	local *Genesis::Env::_create_deployment_audit_log = sub { 1 };
	my $env = bless({name => 'fake-env'}, 'Genesis::Env');
	fails_privately('exodus write', sub {
		$env->update_deployment_exodus('deploy', 'success', quiet => 1);
	});
};

fails_privately('credhub set', sub {
	$credhub->set('x', {password => 'not-the-marker'}, 'password');
});

fails_privately('credhub get', sub {
	my ($value, $error) = $credhub->get('x');
	return $error;
}, returns => 1);

fails_privately('credhub curl', sub {
	$credhub->query('/api/v1/data');
});

my $director = do {
	Service::BOSH->set_command("$dir/bin/bosh");
	Service::BOSH::Director->new('fake',
		url => 'https://127.0.0.1:25555', ca_cert => 'ca', client => 'admin',
		secret => 'not-under-test', exodus_vault => 'none');
};
put_file("$dir/cloud.yml", 0644, "---\nazs: []\n");

fails_privately('bosh update-config', sub {
	$director->upload_config_from_file("$dir/cloud.yml", 'cloud', 'fake');
});

fails_privately('bosh delete-config', sub {
	$director->delete_config('cloud', 'fake');
});

# Configs can carry credentials, such as a CPI's API key, so merging the
# director's configs keeps them out of the trace whether it works or not.
{
	no warnings qw/redefine once/;
	my $contents = {};
	local *Service::BOSH::Director::config_names_of = sub { qw/first second/ };
	local *Service::BOSH::Director::get_config = sub { $contents->{$_[2]} };

	subtest 'merging configs keeps them out of the trace' => sub {
		my $key = fake_secret('config-api-key');
		$contents = {first => "---\nazs:\n- name: z1\n  cloud_properties: {api_key: $key}\n", second => "---\nvm_types: []\n"};
		delete $director->{_config_assembly_cache};
		my $log = capture_trace { $director->download_configs("$dir/assembled.yml", 'cloud') };
		like(Genesis::slurp("$dir/assembled.yml"), qr/\Q$key\E/, 'the caller still gets the merged config');
		unlike($log, qr/\Q$key\E/, 'the config is absent from the trace');
	};

	$contents = {first => "---\nazs: []\n", second => "---\nvm_types: []\n"};
	fails_privately('config merge', sub {
		delete $director->{_config_assembly_cache};
		$director->download_configs("$dir/assembled.yml", 'cloud');
	});
}

subtest 'a parse error does not quote the input' => sub {
	my $marker = fake_secret('parse');
	my ($died, $log, $stderr);
	($log, $stderr) = capture_trace {
		eval { Genesis::read_json_from(qq({"password": $marker}), 0, ''); 1 } or $died = "$@";
	};
	ok(defined($died), 'the bad input is refused');
	unlike($died // '', qr/\Q$marker\E/, 'the error leaves the input out');
	unlike($stderr.$log, qr/\Q$marker\E/, 'so do the terminal and the log');
	like($died // '', qr/offset|character/i, 'it still says where parsing failed');
};

subtest 'a parse error keeps no input even when it looks like the delimiter' => sub {
	my $marker = fake_secret('delimiter');
	my $died;
	eval { Genesis::load_json(qq[{"password": $marker") at $marker-tail}]); 1 } or $died = "$@";
	ok(defined($died), 'the bad input is refused');
	# The test helper loads Carp::Always, whose backtrace quotes arguments;
	# the message is everything before it.
	$died = (split /\n/, $died // '')[0];
	unlike($died // '', qr/fake-delimiter/, 'no part of the input is kept');
	like($died // '', qr/character offset \d+/, 'it says where parsing failed');
	like($died // '', qr/\(expected a literal\)/, 'and what kind of failure it was');
};

subtest 'failure_summary never repeats text from the stream' => sub {
	my $marker = fake_secret('pathlike');
	my $summary = Genesis::failure_summary(" - \$.$marker: permission denied\n\$.a.$marker\n");
	unlike($summary, qr/fake-pathlike/, 'a value shaped like a path is not repeated');
	like($summary, qr/permission denied/, 'the kind of failure is still named');
	unlike(Genesis::failure_summary("fake-unknown-text"), qr/fake-unknown-text/, 'nor is unrecognized text');
	like(Genesis::failure_summary("fake-unknown-text"), qr/withheld/, 'which says why there is no more detail');
};

subtest 'failure_summary names a write that held no data' => sub {
	my $summary = Genesis::failure_summary(
		"POST /secret/x: HTTP status 400\n",
		"{\"errors\":[\"missing data fields\"]}\n",
	);
	like($summary, qr/\bno data was given\b/, 'a kv v1 refusal of an empty record is named');
	unlike($summary, qr/withheld/, 'so the report is not left empty');
};

subtest 'failure_summary names a bosh task and HTTP status' => sub {
	my $marker = fake_secret('task-text');
	my $summary = Genesis::failure_summary(
		"Task 4417 | 10:01:02 | Error: $marker\n",
		"Director responded with non-successful status code '401' response '$marker'\n",
	);
	like($summary, qr/authentication failed/, 'the kind of failure is named');
	like($summary, qr/\btask 4417\b/, 'and the task');
	like($summary, qr/\bHTTP status 401\b/, 'and the HTTP status');
	unlike($summary, qr/\Q$marker\E/, 'but nothing else the stream held');

	$summary = Genesis::failure_summary("Expected task '93' to succeed but state is 'error'\n$marker");
	like($summary, qr/\btask 93\b/, 'a task named in quotes is found too');
	like($summary, qr/withheld/, 'and the rest is still withheld');

	$summary = Genesis::failure_summary("HTTP/1.1 503 Service Unavailable\n");
	like($summary, qr/\bHTTP status 503\b/, 'an HTTP status line is read');
	unlike(Genesis::failure_summary("status code '4011'"), qr/HTTP status/, 'only a three-digit status counts');
	unlike(Genesis::failure_summary("password: Task 12345678901234"), qr/task \d/, 'and a task ID is a plausible number');
};

subtest 'spruce paths are named only when the merged files hold their keys' => sub {
	my $marker = fake_secret('spruce-path');
	put_file("$dir/paths.yml", 0644, <<'YAML');
---
instance_groups:
- name: web
  jobs:
  - name: router
    properties:
      "admin-password": (( vault "secret/x:y" ))
YAML
	my $err = join('',
		"2 error(s) detected:\n",
		" - \$.instance_groups.web.jobs.router.properties.admin-password: secret secret/x:y not found\n",
		" - \$.instance_groups.$marker.properties: could not resolve\n",
		"\$.instance_groups.web: not at the start of an error line\n",
	);
	my @paths = Genesis::spruce_error_paths($err, "$dir/paths.yml");
	is_deeply(\@paths, ['$.instance_groups.web.jobs.router.properties.admin-password'],
		'only the path made of the files\' own keys and names is kept');
	unlike(join(' ', @paths), qr/fake-spruce-path/, 'a component the files do not hold is never repeated');
};

subtest 'spruce paths are walked through the files\' structure, not their text' => sub {
	my $marker = fake_secret('block-scalar');
	put_file("$dir/block.yml", 0644, <<"YAML");
---
properties:
  script: |
    $marker: inside a block scalar
  password: (( vault "secret/x:y" ))
instance_groups:
- name: (( grab params.name ))
  jobs: []
YAML
	my $err = join('',
		" - \$.properties.$marker: could not resolve\n",
		" - \$.properties.instance_groups: could not resolve\n",
		" - \$.instance_groups.(( grab params.name )).jobs: could not resolve\n",
		" - \$.instance_groups.0.jobs: could not resolve\n",
		" - \$.properties.password: secret secret/x:y not found\n",
	);
	is_deeply([Genesis::spruce_error_paths($err, "$dir/block.yml")],
		['$.instance_groups.0.jobs', '$.properties.password'],
		'a key-shaped line in a block scalar, a key from elsewhere, and an operator name are dropped');
};

subtest 'a failed merge names the checked paths spruce could not resolve' => sub {
	my $marker = fake_secret('merge-path');
	mkdir "$dir/spruce-bin";
	# spruce json reads the source files to check the paths, so it is
	# handed to the real spruce.
	chomp(my $real = `command -v spruce`);
	put_file("$dir/spruce-bin/spruce", 0755, <<"EOS".<<'EOS');
#!/bin/bash
[[ \$1 == json ]] && exec '$real' "\$@"
EOS
printf '2 error(s) detected:\n - $.properties.password: secret secret/x:y not found\n - $.properties.%s: %s\n' "$FAKE_ERR" "$FAKE_ERR" >&2
exit 2
EOS
	put_file("$dir/paths-source.yml", 0644, "---\nproperties:\n  password: (( vault \"secret/x:y\" ))\n");
	local $ENV{FAKE_ERR} = $marker;
	local $ENV{PATH} = "$dir/spruce-bin:$ENV{PATH}";
	my $died;
	my ($log, $stderr) = capture_trace {
		eval { $provider->merge(FakeManifest->new(file => "$dir/merged.yml"), ["$dir/paths-source.yml"], {}, {}); 1 }
			or $died = "$@";
	};
	like($died // '', qr/\$\.properties\.password/, 'the path made of the file\'s keys is named');
	like($died // '', qr/not found/, 'with the kind of failure');
	unlike(($died // '').$stderr.$log, qr/\Q$marker\E/, 'a path component the files do not hold is not');
};

done_testing;
