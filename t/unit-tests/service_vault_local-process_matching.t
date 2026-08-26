#!/usr/bin/env perl
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use File::Temp qw/tempdir/;

use_ok 'Service::Vault::Local';
use Genesis;

# Shadow `ps` with a canned process table so the filters can be exercised
# against a known set of processes rather than whatever is on the box.  Only
# `ps` is shadowed; the grep/sed/head in the pipeline stay real, which is the
# point -- the bug lives in how the filter reads against real grep.
sub with_fake_ps {
	my ($table, $code) = @_;
	my $dir = tempdir(CLEANUP => 1);
	open(my $fh, '>', "$dir/ps") or die "could not write fake ps: $!";
	print $fh "#!/bin/sh\ncat <<'PSEOF'\n$table\nPSEOF\n";
	close($fh);
	chmod(0755, "$dir/ps") or die "could not chmod fake ps: $!";
	local $ENV{PATH} = "$dir:$ENV{PATH}";
	return $code->();
}

# safe >= 1.20.0 resolves the server binary before spawning it, so ps reports
# the vault child by its absolute path.  This is the table a real safe 1.20
# produces: genesis ran a bare `safe`, safe exec'd a resolved `vault`.
my $RESOLVED = <<'EOT';
  PID  PPID COMMAND
 4241  4240 safe local -m --as local_vault_test_4240 --port 8299
 4242  4241 /home/linuxbrew/.linuxbrew/bin/vault server -config=/tmp/vault-4241.hcl
EOT
chomp $RESOLVED;

# And the same when genesis itself was invoked with a resolved safe on PATH.
my $BOTH_RESOLVED = <<'EOT';
  PID  PPID COMMAND
 6241  6240 /home/linuxbrew/.linuxbrew/bin/safe local -m --as local_vault_test_6240 --port 8299
 6242  6241 /home/linuxbrew/.linuxbrew/bin/vault server -config=/tmp/vault-6241.hcl
EOT
chomp $BOTH_RESOLVED;

my $BARE = <<'EOT';
  PID  PPID COMMAND
 5241  5240 safe local -m --as local_vault_test_5240 --port 8299
 5242  5241 vault server -config=/tmp/vault-5241.hcl
EOT
chomp $BARE;

subtest 'finds the vault child that safe 1.20 exec\'d by absolute path' => sub {
	plan tests => 4;

	# The reported failure: create() starts the vault fine, cannot see it, and
	# bails with "Could not start local memory-backed vault" while printing
	# safe's own success banner as the error body.
	with_fake_ps($RESOLVED, sub {
		my $safe = Service::Vault::Local::_get_safe_process('local_vault_test_4240', 0.2);
		ok($safe, 'the safe process is found') or return;
		is($safe->{pid}, 4241, 'the safe pid is read out of the process table');

		my $vault = Service::Vault::Local::_get_vault_process($safe->{pid}, 0.2);
		ok($vault, 'the vault child is found even though ps reports it by absolute path')
			or return;
		is($vault->{ppid}, $safe->{pid},
			'the vault child is matched to its safe parent, not to some other vault');
	});
};

subtest 'finds safe itself when it too was exec\'d by absolute path' => sub {
	plan tests => 2;

	with_fake_ps($BOTH_RESOLVED, sub {
		my $safe = Service::Vault::Local::_get_safe_process('local_vault_test_6240', 0.2);
		is(($safe||{})->{pid}, 6241, 'a resolved `safe local` still matches');

		my $vault = Service::Vault::Local::_get_vault_process(6241, 0.2);
		is(($vault||{})->{pid}, 6242, 'its vault child still matches');
	});
};

subtest 'still finds them when safe execs a bare vault off PATH' => sub {
	plan tests => 2;

	with_fake_ps($BARE, sub {
		my $safe = Service::Vault::Local::_get_safe_process('local_vault_test_5240', 0.2);
		is(($safe||{})->{pid}, 5241, 'a bare `safe local` still matches');

		my $vault = Service::Vault::Local::_get_vault_process(5241, 0.2);
		is(($vault||{})->{pid}, 5242, 'a bare `vault server` still matches');
	});
};

subtest 'does not match another safe parent vault child' => sub {
	plan tests => 1;

	# The ppid anchor is load-bearing: create() bails when the child it finds
	# is not its own, so a filter loose enough to match a neighbour's vault
	# would hand back a pid that gets shut down out from under them.
	with_fake_ps($RESOLVED, sub {
		my $vault = Service::Vault::Local::_get_vault_process(9999, 0.1);
		is($vault, undef, 'no vault child is reported for an unrelated parent pid');
	});
};

subtest 'retries the target lookup while safe is still writing .saferc' => sub {
	plan tests => 2;

	# safe registers the target in ~/.saferc a moment after the server is up.
	# A single read races that writer and comes back empty, which reaches
	# read_json_from as '' and dies with "malformed JSON string" -- naming
	# nothing an operator can act on.
	my $dir = tempdir(CLEANUP => 1);
	my $counter = "$dir/calls";

	open(my $fh, '>', "$dir/safe") or die "could not write fake safe: $!";
	print $fh <<"EOT";
#!/bin/sh
n=\$(cat '$counter' 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > '$counter'
[ "\$n" -ge 3 ] || exit 0
echo '[{"name":"local_vault_test_1","url":"http://127.0.0.1:8299","verify":false,"namespace":"","strongbox":true,"mount":"/secret/"}]'
EOT
	close($fh);
	chmod(0755, "$dir/safe") or die "could not chmod fake safe: $!";

	my $info = do {
		local $ENV{PATH} = "$dir:$ENV{PATH}";
		Service::Vault::Local::_lookup_vault_target('local_vault_test_1', 20);
	};

	is(($info||{})->{url}, 'http://127.0.0.1:8299',
		'the target is picked up once safe has written it');
	cmp_ok(scalar(do { open(my $c, '<', $counter); my $n = <$c>; chomp $n; $n }), '>=', 3,
		'the lookup kept trying across the empty reads instead of dying on the first');
};

done_testing;
