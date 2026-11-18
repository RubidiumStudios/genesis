#!/usr/bin/env perl
# What credhub prints is credential data, so it never reaches a log:
# not on success, not with any debugging switch set, and not when the
# command fails.  Each test uses a fake credhub that prints a made-up
# value on stdout and stderr, and checks that the caller still gets what
# it needs while the logs get neither stream.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Service::Credhub;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
put_file("$dir/bin/credhub", 0755, <<"EOS");
#!/bin/bash
for a in "\$@"; do printf '%s\\n' "\$a"; done >> "$dir/argv"
[[ -n \$FAKE_OUT ]] && printf '%s\\n' "\$FAKE_OUT"
[[ -n \$FAKE_ERR ]] && printf '%s\\n' "\$FAKE_ERR" >&2
exit \${FAKE_RC:-0}
EOS
$ENV{PATH} = "$dir/bin:$ENV{PATH}";

sub received { my $got = -f "$dir/argv" ? Genesis::slurp("$dir/argv") : ''; unlink "$dir/argv"; $got }
sub credhub {
	bless({
		name => 'fake', base => '/fake/', url => 'https://10.0.0.6:8844',
		username => 'credhub-admin', password => 'not-under-test', ca_cert => 'ca',
	}, 'Service::Credhub');
}

subtest 'GENESIS_SHOW_CREDHUB_SECRETS no longer puts values in the trace' => sub {
	my $value = fake_secret('credhub-shown');
	local $ENV{GENESIS_SHOW_CREDHUB_SECRETS} = 1;
	my $ch = credhub();
	for my $case (
		[get     => sub { local $ENV{FAKE_OUT} = qq({"value":"$value"}); $ch->get('x') }],
		[export  => sub { local $ENV{FAKE_OUT} = qq({"Credentials":[{"Name":"/fake/x","Value":"$value"}]}); $ch->preload; $ch->get('x') }],
		[set     => sub { local $ENV{FAKE_OUT} = qq({"value":"$value"}); my @r = $ch->set('x', {password => $value}, 'password'); $r[0] }],
	) {
		my ($what, $code) = @$case;
		my $got;
		my $log = capture_trace { $got = $code->() };
		like($got // '', qr/\Q$value\E/, "$what: the caller still gets the value");
		unlike($log, qr/\Q$value\E/, "$what: the value is absent from the trace");
	}
	received();
};

done_testing;
