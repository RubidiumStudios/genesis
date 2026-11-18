#!/usr/bin/env perl
# move_secrets_to_credhub copies a value from vault into CredHub and then
# deletes the vault original, so the copy must be exact, and nothing that
# might be newer than the copy may be deleted.  The value travels byte
# for byte, trailing newlines included; CredHub is read back and compared
# before any delete; the vault value is read again and left in place if it
# changed; and the only delete is of the kv v2 version that was copied,
# so a value written after the last read survives it.  Where no delete can
# be limited that way -- a kv v1 mount, a mount or version lookup that
# fails, a version holding other keys -- the vault copy is left in place
# and the operator is told why.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;
use POSIX ();

use Genesis;
use Genesis::Helpers;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
Genesis::Helpers->write("$dir/.helper");

# A fake vault kept on disk: $dir/vault/<version>/<key> holds each value
# exactly, and a deleted version is renamed <version>.deleted, as kv v2
# keeps it listed.  FAKE_KV says what the mounts endpoint answers: 2 or 1
# for a kv v2 or v1 mount, old for a vault from before kv v2 (404), and
# fail for no answer.  FAKE_VERSIONS_FAIL makes `safe versions` fail.  A
# value in $dir/vault/next/<key> becomes a new version after the first
# read, or with FAKE_ROTATE_AT=rm just before a delete, after the last
# read.  Every failure says FAKE_SAFE_SAYS on stderr.
put_file("$dir/bin/safe", 0755, <<'SH');
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/safe-calls"
vault="$FAKE_DIR/vault"
latest() { ls "$vault" | grep -E '^[0-9]+$' | sort -n | tail -1; }
newest() { ls "$vault" | sed -e 's/\.deleted$//' | grep -E '^[0-9]+$' | sort -n | tail -1; }
rotate() {
  [[ -d "$vault/next" ]] || return 0
  new=$(( $(newest) + 1 )); cp -R "$vault/$(latest)" "$vault/$new"
  cp "$vault/next/"* "$vault/$new/"; rm -rf "$vault/next"
}
fail() { echo >&2 "error: $FAKE_SAFE_SAYS"; exit 1; }
case "$1" in
  curl)
    case "${FAKE_KV:-1}" in
      1|2) printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"data":{"path":"secret/","type":"kv","options":{"version":"%s"}}}\n' "${FAKE_KV:-1}" ;;
      old) printf 'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"errors":[]}\n' ;;
      *)   fail ;;
    esac ;;
  versions)
    [[ -n "${FAKE_VERSIONS_FAIL:-}" ]] && fail
    printf 'version  status  created at\n'
    for v in $(ls "$vault" | grep -E '^[0-9]+(\.deleted)?$' | sort -n); do
      [[ $v == *.deleted ]] && st=deleted || st=alive
      printf '%s        %s   17 Nov 26 10:00 EST\n' "${v%.deleted}" "$st"
    done ;;
  get)
    [[ -n "${FAKE_GET_FAILS:-}" ]] && fail
    if [[ "$2" == --keys ]]; then
      spec="$3"; ver="$(latest)"
      [[ "$spec" == *^* ]] && ver="${spec##*^}"
      ls "$vault/$ver"; exit 0
    fi
    spec="$2"; key="${spec##*:}"; path="${spec%:*}"; ver="$(latest)"
    [[ "$path" == *^* ]] && ver="${path##*^}"
    [[ -f "$vault/$ver/$key" ]] || fail
    cat "$vault/$ver/$key"; printf '\n'
    if [[ "${FAKE_ROTATE_AT:-read}" == read ]]; then rotate; fi ;;
  rm)
    [[ "${FAKE_ROTATE_AT:-read}" == rm ]] && rotate
    spec="$2"
    if [[ "$spec" == *^* ]]; then
      ver="${spec##*^}"; [[ -d "$vault/$ver" ]] || fail
      mv "$vault/$ver" "$vault/$ver.deleted"
    else
      echo >&2 "the fake supports only version deletes"; exit 2
    fi ;;
esac
SH

# A fake CredHub that stores what `set --value=` is given, or with
# FAKE_CREDHUB_TRIMS a value with its trailing newlines dropped, and
# counts the versions written.  `get --output-json` answers with the
# newest value, or with --versions=2 the newest two, and a name with no
# value gets CredHub's "does not exist" answer.  FAKE_CREDHUB_RACE is a
# value something else writes just before the fake's own write, and
# FAKE_CREDHUB_GET_FAILS makes every read fail some other way.  With
# FAKE_CREDHUB_NOISE, every read first writes more to stderr than a pipe
# holds, as a CLI full of warnings could.  A name with no value gets
# FAKE_CREDHUB_SAYS on stderr, CredHub's own answer by default, and ends
# with FAKE_CREDHUB_SAYS_RC, 1 by default.  FAKE_CREDHUB_FLAT answers a
# request for versions with the newest value alone.
put_file("$dir/bin/credhub", 0755, <<'SH');
#!/bin/bash
store="$FAKE_DIR/credhub-value"; count="$FAKE_DIR/credhub-count"
cmd="$1"; shift
if [[ -n "${FAKE_CREDHUB_NOISE:-}" && $cmd == get ]]; then
  head -c 1048576 /dev/zero | tr '\0' 'n' >&2; echo >&2
fi
attached=''; value=''; versions=''
for a in "$@"; do
  case "$a" in
    --value=*)    value="${a#--value=}"; attached=' value-attached' ;;
    --versions=*) versions="${a#--versions=}" ;;
  esac
done
printf '%s%s\n' "$cmd" "$attached" >> "$FAKE_DIR/credhub-calls"
bump() { echo $(( $(cat "$count" 2>/dev/null || echo 0) + 1 )) > "$count"; }
case "$cmd" in
  set)
    if [[ -n "${FAKE_CREDHUB_RACE:-}" ]]; then printf '%s' "$FAKE_CREDHUB_RACE" > "$store"; bump; fi
    [[ -n "${FAKE_CREDHUB_TRIMS:-}" ]] && value="$(printf '%s' "$value")"
    printf '%s' "$value" > "$store"; bump ;;
  get)
    [[ -n "${FAKE_CREDHUB_GET_FAILS:-}" ]] && { echo >&2 "error: fake-credhub-diagnostic"; exit 1; }
    [[ -f "$store" ]] || {
      printf >&2 '%s\n' "${FAKE_CREDHUB_SAYS-The request could not be completed because the credential does not exist or you do not have sufficient authorization.}"
      exit "${FAKE_CREDHUB_SAYS_RC:-1}"
    }
    [[ -n "${FAKE_CREDHUB_FLAT:-}" ]] && versions=''

    perl -MJSON::PP -0777 -e '
      my ($versions, $count, $type) = @ARGV;
      my $v = {type => $type, value => scalar(<STDIN>)};
      my $n = $versions ? ($count < $versions ? $count : $versions) : 0;
      print JSON::PP->new->encode($n ? {versions => [$v, ({type => $type, value => "fake-older"}) x ($n - 1)]} : $v);
    ' "$versions" "$(cat "$count")" "${FAKE_CREDHUB_TYPE:-value}" < "$store" ;;
esac
SH

# within - run a bash command in its own process group, with its output
# kept, and kill the whole group if it has not ended within $secs seconds,
# so a move that hangs fails its test instead of the run.
sub within {
	my ($secs, $cmd) = @_;
	my $pid = fork() // die "cannot fork: $!";
	if (!$pid) {
		setpgrp(0, 0);
		open(STDOUT, '>', "$dir/out") or exit 127;
		open(STDERR, '>&', \*STDOUT) or exit 127;
		exec('bash', '-c', $cmd) or exit 127;
	}
	my $deadline = time + $secs;
	while (time < $deadline) {
		return ($? >> 8, slurp("$dir/out"), 0) if waitpid($pid, POSIX::WNOHANG()) > 0;
		select(undef, undef, undef, 0.1);
	}
	kill('KILL', -$pid);
	waitpid($pid, 0);
	return (undef, slurp("$dir/out"), 1);
}

# move - run move_secrets_to_credhub on fake/path:password with the vault
# holding %$versions ({version => {key => value}}); returns what happened.
sub move {
	my ($versions, %env) = @_;
	my $next = delete $env{next};
	my $holds = delete $env{holds};
	my $history = delete($env{history}) // 1;
	my $src = delete($env{src}) // 'path:password';
	system('rm', '-rf', "$dir/vault", "$dir/safe-calls", "$dir/credhub-calls", "$dir/credhub-value", "$dir/credhub-count");
	if (defined($holds)) {
		put_file("$dir/credhub-value", $holds);
		put_file("$dir/credhub-count", "$history\n");
	}
	put_file("$dir/vault/next/password", $next) if defined($next);
	for my $v (keys %$versions) {
		for my $k (keys %{$versions->{$v}}) {
			# Written as raw bytes, since put_file encodes what it writes.
			mkdir "$dir/vault"; mkdir "$dir/vault/$v";
			open(my $fh, '>:raw', "$dir/vault/$v/$k") or die "cannot write the fake vault: $!";
			print $fh $versions->{$v}{$k};
			close($fh);
		}
	}
	local %ENV = (%ENV,
		PATH => "$dir/bin:$ENV{PATH}", FAKE_DIR => $dir,
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		SAFE_TARGET => 'fake-vault', GENESIS_TARGET_VAULT => 'fake-vault',
		GENESIS_SECRETS_BASE => 'secret/fake/', GENESIS_CREDHUB_ROOT => 'fake-bosh/fake',
		%env,
	);
	local $ENV{FAKE_SAFE_SAYS} = $env{FAKE_SAFE_SAYS} // 'fake-safe-diagnostic-quoting-a-value';
	local $ENV{FAKE_SRC} = $src;
	my ($rc, $out, $hung) = within(60, qq{cd "$dir" && source .helper && move_secrets_to_credhub "\$FAKE_SRC" "password"});
	return {
		rc => $rc, out => $out, hung => $hung,
		stored => (-f "$dir/credhub-value" ? slurp("$dir/credhub-value") : undef),
		safe => (-f "$dir/safe-calls" ? slurp("$dir/safe-calls") : ''),
		credhub => (-f "$dir/credhub-calls" ? slurp("$dir/credhub-calls") : ''),
		vault => {map {my $v = $_; ($v => {map {($_ => slurp("$dir/vault/$v/$_"))} grep {-f "$dir/vault/$v/$_"} map {s{.*/}{}r} glob("$dir/vault/$v/*")})} grep {!/next/} map {s{.*/}{}r} glob("$dir/vault/*")},
	};
}

# move_with_change - move a value that is replaced right after it is read
sub move_with_change {
	my ($version, $before, $after, %env) = @_;
	return move({$version => {password => $before}}, next => $after, %env);
}

my $multiline = "fake-line-one\nfake-line-two\n\n";

subtest 'a value is moved byte for byte, trailing newlines included' => sub {
	my $r = move({1 => {password => $multiline}}, FAKE_KV => 2);
	is($r->{rc}, 0, 'the move succeeds') or diag $r->{out};
	is($r->{stored}, $multiline, 'CredHub holds exactly the vault value');
	like($r->{safe}, qr/^rm secret\/fake\/path\^1$/m, 'and then the vault original is removed');
};

# A shell value and a command argument cannot hold a NUL byte, and CredHub
# stores text, so a value either would change is refused before anything
# is written or removed.
for my $case (
	['a NUL byte', "fake-before\0fake-after", qr/holds a NUL byte/],
	['bytes that are not UTF-8', "fake-latin1-\xff\xfe", qr/is not valid UTF-8/],
) {
	my ($what, $value, $why) = @$case;
	subtest "a value with $what is refused before anything changes" => sub {
		my $r = move({1 => {password => $value}}, FAKE_KV => 2);
		isnt($r->{rc}, 0, 'the move fails');
		ok(!defined($r->{stored}), 'nothing is written to CredHub');
		unlike($r->{credhub}, qr/^set/m, 'credhub set is never run');
		unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
		is($r->{vault}{1}{password}, $value, 'which still holds the value exactly');
		like($r->{out}, qr/cannot be moved to CredHub exactly, because/, 'the operator is told it was refused');
		like($r->{out}, $why, 'and why');
		like($r->{out}, qr/path:password/, 'naming the secret');
		unlike($r->{out}, qr/fake-(?:before|after|latin1)/, 'without the value');
	};
}

subtest 'a secret with no key is refused before anything changes' => sub {
	my $r = move({1 => {password => 'fake-value'}}, FAKE_KV => 2, src => 'path');
	isnt($r->{rc}, 0, 'the move fails');
	ok(!defined($r->{stored}), 'nothing is written to CredHub');
	unlike($r->{safe}, qr/^(?:get|rm) /m, 'and vault is neither read nor changed');
	like($r->{out}, qr/names no key/, 'the operator is told to name the key');
};

subtest 'a value that starts with a hyphen is given to credhub attached' => sub {
	my $r = move({1 => {password => '-fake-hyphen-value'}}, FAKE_KV => 2);
	is($r->{rc}, 0, 'the move succeeds') or diag $r->{out};
	is($r->{stored}, '-fake-hyphen-value', 'CredHub holds the value exactly');
	like($r->{credhub}, qr/^set value-attached$/m, 'it was passed as --value=, so it is never taken for an option');
};

subtest 'a CredHub read is not stalled by what credhub says on stderr' => sub {
	my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, holds => 'fake-vault-value', FAKE_CREDHUB_NOISE => 1);
	ok(!$r->{hung}, 'the move does not hang');
	is($r->{rc}, 0, 'it succeeds') or diag substr($r->{out} // '', -400);
	like($r->{safe}, qr/^rm secret\/fake\/path\^1$/m, 'and the vault original is removed');
	unlike($r->{out}, qr/nnnn/, 'without passing on what credhub said');
};

subtest 'a destination already holding the same value is a retry' => sub {
	my $r = move({1 => {password => $multiline}}, FAKE_KV => 2, holds => $multiline);
	is($r->{rc}, 0, 'the move succeeds') or diag $r->{out};
	unlike($r->{credhub}, qr/^set/m, 'the value is not written again');
	is($r->{stored}, $multiline, 'CredHub still holds it');
	like($r->{safe}, qr/^rm secret\/fake\/path\^1$/m, 'and the vault original is removed');
};

subtest 'a retry after a collision keeps the vault copy' => sub {
	# A move that found CredHub written meanwhile left it holding its value
	# as the newest of two versions, and the older one is someone else's.
	my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, holds => 'fake-vault-value', history => 2);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{credhub}, qr/^set/m, 'nothing is written to CredHub');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
	like($r->{out}, qr/holds\s+more\s+than\s+one\s+version\s+under/, 'the operator is told CredHub has more than one version');
	unlike($r->{out}, qr/fake-(?:vault|older)-value/, 'without any value');
};

# CredHub gives a name the caller cannot read the same answer as one that
# does not exist, so only that exact answer, alone and with the CLI's own
# exit status, counts as a name the move may write.
my $not_found = 'The request could not be completed because the credential does not exist or you do not have sufficient authorization.';
for my $case (
	['an authorization error that mentions a missing name', 'error: insufficient_scope: the credential does not exist', 1],
	['the not-found answer with more besides', "$not_found\nerror: the token for fake-client has expired", 1],
	['the not-found answer with another exit status', $not_found, 2],
	['nothing at all', '', 1],
) {
	my ($what, $says, $status) = @$case;
	subtest "a read that gives $what is not taken for a missing name" => sub {
		my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2,
			FAKE_CREDHUB_SAYS => $says, FAKE_CREDHUB_SAYS_RC => $status);
		isnt($r->{rc}, 0, 'the move fails');
		unlike($r->{credhub}, qr/^set/m, 'nothing is written to CredHub');
		unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
		like($r->{out}, qr/could\s+not\s+tell\s+whether\s+CredHub\s+already\s+holds\s+a\s+credential/, 'the operator is told why');
		unlike($r->{out}, qr/insufficient_scope|fake-client|fake-vault-value/, 'without what credhub said or the value');
	};
}

subtest 'a read with no version history is not trusted' => sub {
	my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, FAKE_CREDHUB_FLAT => 1);
	isnt($r->{rc}, 0, 'the move fails when the readback has no version history');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
	like($r->{out}, qr/did\s+not\s+return\s+the\s+versions\s+of\s+\S*password/, 'the operator is told why');
	unlike($r->{out}, qr/fake-vault-value/, 'without the value');

	$r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, FAKE_CREDHUB_FLAT => 1, holds => 'fake-vault-value');
	isnt($r->{rc}, 0, 'and when the check before the write has none');
	unlike($r->{credhub}, qr/^set/m, '... nothing is written to CredHub');
	unlike($r->{safe}, qr/^rm /m, '... nothing is removed from vault');
};

subtest 'a destination holding a different credential is never replaced' => sub {
	for my $case (['a different value', 'fake-live-value', 'value'], ['another type', 'fake-live-value', 'password']) {
		my ($what, $live, $type) = @$case;
		my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, holds => $live, FAKE_CREDHUB_TYPE => $type);
		isnt($r->{rc}, 0, "the move fails when CredHub holds $what");
		unlike($r->{credhub}, qr/^set/m, '... nothing is written to CredHub');
		is($r->{stored}, $live, '... which still holds its live credential');
		unlike($r->{safe}, qr/^rm /m, '... nothing is removed from vault');
		like($r->{out}, qr/already holds a different credential under\s+\S*password/, '... and the operator is told why');
		unlike($r->{out}, qr/fake-(?:live|vault)-value/, '... without either value');
	}
};

subtest 'a destination that cannot be read is not written' => sub {
	my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, FAKE_CREDHUB_GET_FAILS => 1);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{credhub}, qr/^set/m, 'nothing is written to CredHub');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
	like($r->{out}, qr/could\s+not\s+tell\s+whether\s+CredHub\s+already\s+holds\s+a\s+credential/, 'the operator is told why');
	unlike($r->{out}, qr/fake-credhub-diagnostic|fake-vault-value/, 'without what credhub said or the value');
};

subtest 'a write that races another keeps the vault copy' => sub {
	# Something else writes the name between the check and the write.
	my $r = move({1 => {password => 'fake-vault-value'}}, FAKE_KV => 2, FAKE_CREDHUB_RACE => 'fake-racing-value');
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
	like($r->{out}, qr/holds\s+more\s+than\s+one\s+version\s+under/, 'the operator is told CredHub was written meanwhile');
	unlike($r->{out}, qr/fake-(?:racing|vault)-value/, 'without either value');
};

subtest 'a value CredHub does not hold exactly is never deleted' => sub {
	my $r = move({1 => {password => $multiline}}, FAKE_KV => 2, FAKE_CREDHUB_TRIMS => 1);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{safe}, qr/^rm /m, 'the vault original is kept');
	like($r->{out}, qr/does not match/, 'the mismatch is reported');
	unlike($r->{out}, qr/fake-line/, 'without the value');
};

subtest 'a value that changes in vault during the move is not deleted' => sub {
	# The fake applies vault/next after the first read, as a rotation would.
	my $r = move_with_change(1, 'fake-original-value', 'fake-rotated-value', FAKE_KV => 2);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{safe}, qr/^rm /m, 'the changed vault value is kept');
	like($r->{out}, qr/changed/, 'the change is reported');
	unlike($r->{out}, qr/fake-(?:original|rotated)-value/, 'without either value');
};

subtest 'on a versioned mount, the copied version is the one read and removed' => sub {
	my $r = move({1 => {password => 'fake-old-value'}, 2 => {password => $multiline}}, FAKE_KV => 2);
	is($r->{rc}, 0, 'the move succeeds') or diag $r->{out};
	is($r->{stored}, $multiline, 'CredHub holds the newest version');
	like($r->{safe}, qr/^get secret\/fake\/path\^2:password$/m, 'version 2 is read by number');
	like($r->{safe}, qr/^rm secret\/fake\/path\^2$/m, 'and only version 2 is removed');
	unlike($r->{safe}, qr/^rm secret\/fake\/path(?::password)?$/m, 'not the newest version, whatever it is by then');
};

subtest 'a value rotated after the last read survives the delete' => sub {
	# The rotation lands after every read and check, just before the
	# delete, which is the last moment one can.
	my $r = move_with_change(4, 'fake-v4-value', 'fake-v5-value', FAKE_KV => 2, FAKE_ROTATE_AT => 'rm');
	like($r->{safe}, qr/^rm secret\/fake\/path\^4$/m, 'the delete names the copied version');
	is($r->{vault}{5}{password}, 'fake-v5-value', 'so the rotated value is still in vault');
	ok(!exists($r->{vault}{4}), 'and only the copied version is gone');
	isnt($r->{rc}, 0, 'the move fails, since CredHub holds the older value');
	like($r->{out}, qr/written again.*newer version 5 was kept/s, 'and says the newer version was kept');
	unlike($r->{out}, qr/fake-v[45]-value/, 'without either value');
};

subtest 'a versioned secret with other keys is left in place' => sub {
	my $r = move({3 => {password => 'fake-pw', username => 'fake-user'}}, FAKE_KV => 2, FAKE_ROTATE_AT => 'rm');
	is($r->{rc}, 0, 'the copy succeeds') or diag $r->{out};
	is($r->{stored}, 'fake-pw', 'CredHub holds the value');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed from vault');
	like($r->{out}, qr/left the vault copy in place: version 3 of\s+\S*secret\/fake\/path\S*\s+holds other keys/s, 'and the operator is told why');
	unlike($r->{out}, qr/fake-(?:pw|user)/, 'without any value');
};

subtest 'a new version written during the move stops the delete' => sub {
	my $r = move_with_change(4, 'fake-v4-value', 'fake-v5-value', FAKE_KV => 2);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed');
	unlike($r->{out}, qr/fake-v[45]-value/, 'and neither value is printed');
};

subtest 'a kv v1 mount keeps the vault copy, and says why' => sub {
	for my $kv (1, 'old') {
		my $r = move({1 => {password => $multiline}}, FAKE_KV => $kv);
		is($r->{rc}, 0, "the copy succeeds (mounts endpoint: $kv)") or diag $r->{out};
		is($r->{stored}, $multiline, '... CredHub holds exactly the vault value');
		unlike($r->{safe}, qr/^rm /m, '... nothing is removed, since kv v1 keeps no versions');
		like($r->{out}, qr/left the vault copy in place: its vault mount is kv v1/, '... and the operator is told why');
		unlike($r->{safe}, qr/^versions /m, '... without asking a v1 mount for versions');
	}
};

subtest 'a failed mount lookup is not taken for kv v1' => sub {
	my $r = move({1 => {password => 'fake-value'}}, FAKE_KV => 'fail');
	is($r->{rc}, 0, 'the copy succeeds') or diag $r->{out};
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed');
	like($r->{out}, qr/could not tell whether its vault mount keeps versions/, 'the operator is told the lookup failed');
	unlike($r->{out}, qr/kv v1/, 'and not that the mount is kv v1');
	unlike($r->{out}, qr/fake-safe-diagnostic/, 'nor anything safe said');
};

subtest 'a failed version lookup keeps the vault copy' => sub {
	my $r = move({2 => {password => 'fake-value'}}, FAKE_KV => 2, FAKE_VERSIONS_FAIL => 1);
	is($r->{rc}, 0, 'the copy succeeds') or diag $r->{out};
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed');
	like($r->{out}, qr/could not list the versions/, 'the operator is told the version lookup failed');
	unlike($r->{out}, qr/kv v1|fake-safe-diagnostic/, 'without calling it kv v1 or quoting safe');
};

subtest 'what safe says about a failed read is kept private' => sub {
	my $r = move({1 => {password => 'fake-value'}}, FAKE_KV => 2, FAKE_GET_FAILS => 1);
	isnt($r->{rc}, 0, 'the move fails');
	like($r->{out}, qr/Failed to read secret .*safe exited 1/s, 'and says how safe ended');
	unlike($r->{out}, qr/fake-safe-diagnostic/, 'not what it said');
	ok(!defined($r->{stored}), 'and nothing reaches CredHub');
};

done_testing;
