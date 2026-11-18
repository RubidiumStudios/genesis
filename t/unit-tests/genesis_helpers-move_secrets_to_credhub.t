#!/usr/bin/env perl
# move_secrets_to_credhub copies a value from vault into CredHub and then
# deletes the vault original, so the copy must be exact before anything
# is deleted.  The value travels byte for byte, trailing newlines
# included; CredHub is read back and compared before the delete; the
# vault value is read again just before the delete and left in place if
# it changed; and on a versioned (kv v2) mount, the version that was
# copied is the one read and the one removed.
use strict;
use warnings;

use lib 't';
use lib 'lib';
use helper;
use TraceCapture;
use Test::More;
use File::Temp qw/tempdir/;

use Genesis;
use Genesis::Helpers;

my $dir = tempdir(CLEANUP => 1);
mkdir "$dir/bin";
Genesis::Helpers->write("$dir/.helper");

# A fake vault kept on disk: $dir/vault/<version>/<key> holds each value
# exactly, and FAKE_KV=2 makes `safe versions` report the versions.  A
# value in $dir/vault/next/<key> replaces the current one after the first
# read, which is how a test changes the secret under the move.
put_file("$dir/bin/safe", 0755, <<'SH');
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/safe-calls"
vault="$FAKE_DIR/vault"
latest() { ls "$vault" | grep -E '^[0-9]+$' | sort -n | tail -1; }
case "$1" in
  versions)
    [[ "${FAKE_KV:-1}" == 2 ]] || { echo >&2 "not a versioned mount"; exit 1; }
    printf 'version  status  created at\n'
    for v in $(ls "$vault" | grep -E '^[0-9]+$' | sort -n); do
      printf '%s        alive   17 Nov 26 10:00 EST\n' "$v"
    done ;;
  get)
    if [[ "$2" == --keys ]]; then
      spec="$3"; ver="$(latest)"
      [[ "$spec" == *^* ]] && ver="${spec##*^}"
      ls "$vault/$ver"; exit 0
    fi
    spec="$2"; key="${spec##*:}"; path="${spec%:*}"; ver="$(latest)"
    [[ "$path" == *^* ]] && ver="${path##*^}"
    [[ -f "$vault/$ver/$key" ]] || { echo >&2 "no such key"; exit 1; }
    cat "$vault/$ver/$key"; printf '\n'
    if [[ -d "$vault/next" ]]; then
      new=$(( $(latest) + 1 )); cp -R "$vault/$(latest)" "$vault/$new"
      cp "$vault/next/"* "$vault/$new/"; rm -rf "$vault/next"
    fi ;;
  rm) exit 0 ;;
esac
SH

# A fake CredHub that stores what `set -v` is given, or with
# FAKE_CREDHUB_TRIMS a value with its trailing newlines dropped, and
# answers `get -j` with that value as JSON.
put_file("$dir/bin/credhub", 0755, <<'SH');
#!/bin/bash
printf '%s\n' "$1" >> "$FAKE_DIR/credhub-calls"
case "$1" in
  set)
    while [[ $# -gt 0 ]]; do [[ "$1" == -v ]] && { value="$2"; break; }; shift; done
    [[ -n "${FAKE_CREDHUB_TRIMS:-}" ]] && value="$(printf '%s' "$value")"
    printf '%s' "$value" > "$FAKE_DIR/credhub-value" ;;
  get)
    perl -MJSON::PP -0777 -e 'print JSON::PP->new->encode({value => scalar <STDIN>})' < "$FAKE_DIR/credhub-value" ;;
esac
SH

# move - run move_secrets_to_credhub on fake/path:password with the vault
# holding %$versions ({version => {key => value}}); returns what happened.
sub move {
	my ($versions, %env) = @_;
	my $next = delete $env{next};
	system('rm', '-rf', "$dir/vault", "$dir/safe-calls", "$dir/credhub-calls", "$dir/credhub-value");
	put_file("$dir/vault/next/password", $next) if defined($next);
	for my $v (keys %$versions) {
		for my $k (keys %{$versions->{$v}}) {
			put_file("$dir/vault/$v/$k", $versions->{$v}{$k});
		}
	}
	local %ENV = (%ENV,
		PATH => "$dir/bin:$ENV{PATH}", FAKE_DIR => $dir,
		GENESIS_LIB => "$ENV{GENESIS_TOPDIR}/lib",
		SAFE_TARGET => 'fake-vault', GENESIS_TARGET_VAULT => 'fake-vault',
		GENESIS_SECRETS_BASE => 'secret/fake/', GENESIS_CREDHUB_ROOT => 'fake-bosh/fake',
		%env,
	);
	my $out = qx{cd "$dir" && bash -c 'source .helper; move_secrets_to_credhub "path:password" "password"' 2>&1};
	my $rc = $? >> 8;
	return {
		rc => $rc, out => $out,
		stored => (-f "$dir/credhub-value" ? slurp("$dir/credhub-value") : undef),
		safe => (-f "$dir/safe-calls" ? slurp("$dir/safe-calls") : ''),
	};
}

# move_with_change - move a value that is replaced right after it is read
sub move_with_change {
	my ($version, $before, $after, %env) = @_;
	return move({$version => {password => $before}}, next => $after, %env);
}

my $multiline = "fake-line-one\nfake-line-two\n\n";

subtest 'a value is moved byte for byte, trailing newlines included' => sub {
	my $r = move({1 => {password => $multiline}});
	is($r->{rc}, 0, 'the move succeeds') or diag $r->{out};
	is($r->{stored}, $multiline, 'CredHub holds exactly the vault value');
	like($r->{safe}, qr/^rm secret\/fake\/path:password$/m, 'and then the vault original is removed');
};

subtest 'a value CredHub does not hold exactly is never deleted' => sub {
	my $r = move({1 => {password => $multiline}}, FAKE_CREDHUB_TRIMS => 1);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{safe}, qr/^rm /m, 'the vault original is kept');
	like($r->{out}, qr/does not match/, 'the mismatch is reported');
	unlike($r->{out}, qr/fake-line/, 'without the value');
};

subtest 'a value that changes in vault during the move is not deleted' => sub {
	# The fake applies vault/next after the first read, as a rotation would.
	my $r = move_with_change(1, 'fake-original-value', 'fake-rotated-value');
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

subtest 'a versioned secret with other keys loses only this key' => sub {
	my $r = move({3 => {password => 'fake-pw', username => 'fake-user'}}, FAKE_KV => 2);
	is($r->{rc}, 0, 'the move succeeds') or diag $r->{out};
	like($r->{safe}, qr/^rm secret\/fake\/path:password$/m, 'the key is removed, keeping the others');
};

subtest 'a new version written during the move stops the delete' => sub {
	my $r = move_with_change(4, 'fake-v4-value', 'fake-v5-value', FAKE_KV => 2);
	isnt($r->{rc}, 0, 'the move fails');
	unlike($r->{safe}, qr/^rm /m, 'nothing is removed');
	unlike($r->{out}, qr/fake-v[45]-value/, 'and neither value is printed');
};

done_testing;
