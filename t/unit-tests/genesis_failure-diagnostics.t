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

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
mkdir "$dir/work";
for my $name (qw/spruce credhub bosh/) {
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

done_testing;
