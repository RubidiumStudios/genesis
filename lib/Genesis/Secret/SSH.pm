package Genesis::Secret::SSH;
use strict;
use warnings;

use base "Genesis::Secret";

use Genesis qw(run bug debug);

### Construction arguments {{{
# size:  <positive integer>
# path:  <relative location in secrets-store under the base>
# fixed: <boolean to specify if the secret can be overwritten>
# }}}

### Polymorphic Instance Methods {{{
# label - specific label for this derived class {{{
sub label {'SSH key pair'}

# }}}
# vault_operator - get the vault operator string for the given key {{{
sub vault_operator {
	my ($self, $key) = @_;
	my $path = $self->path;
	if (!defined($key)) {
		return {map {($_, $self->vault_operator($_))} qw/public_key private_key public_key_fingerprint/};
	} elsif ($key =~ /^public(_key)?$/) {
		$path .= ':public'
	} elsif ($key =~ /^private(_key)?$/) {
		$path .= ':private';
	} elsif ($key =~ /^(public_key_)?fingerprint$/) {
		$path .= ':fingerprint';
	} else {
		bug(
			"Invalid key for vault_operator on %s secret (%s): %s",
			$self->type, $path, $key
		)
	}
	return $self->_assemble_vault_operator($path);
}
# }}}
# }}}

### Parent-called Support Instance Methods {{{
# _description - return label and features to build describe output {{{
sub _description {
	my $self = shift;

	return (
		uc($self->type)." public/private keypair",
		$self->{definition}{size} . ' bits',
		$self->{definition}{fixed} ? 'fixed' : undef
	);
}

# }}}
# _validate_constructor_opts - make sure secret definition is valid {{{
sub _validate_constructor_opts {
  my ($self,$path,%opts) = @_;

  my $orig_opts = {%opts};
	my ($args, @errors);

  $args->{size} = delete($opts{size}) or
    push @errors, "Missing required 'size' argument";
	push(@errors, "Invalid size argument: expecting 1024-16384, got $args->{size}")
		if ($args->{size} && ($args->{size} !~ /^\d+$/ || $args->{size} < 1024 ||  $args->{size} > 16384));

  $args->{fixed} = !!delete($opts{fixed});
  push(@errors, "Invalid '$_' argument specified") for grep {defined($opts{$_})} keys(%opts);
  return @errors
    ? ($orig_opts, \@errors)
    : ($args)

}

# }}}
# _required_value_keys - list of required keys in value store {{{
sub _required_value_keys {
	qw/private public fingerprint/
}

# }}}
# _validate_value - validate an SSH secret value {{{
sub _validate_value {
	my ($self, %opts) = @_;
	my $values = $self->value;
	my %results;

	# ssh-keygen needs `-f <path>` and refuses to load private keys
	# from regular files with broad permissions or from /dev/stdin
	# (pipe perms 0660).  Use a NAMED PIPE in a private temp dir:
	# - data flows through memory, not disk
	# - mkfifo -m 600 yields 0600 perms on the fifo node
	# - ssh-keygen's permission check is skipped for non-regular files
	# - bash background-writer handles the open/open rendezvous so we
	#   don't deadlock the way the older inline pipe construct did
	require File::Temp;
	my $tmpdir = File::Temp->newdir('genesis-ssh-XXXXXXXX', TMPDIR => 1);
	chmod 0700, "$tmpdir";

	my $counter = 0;
	my $with_fifo = sub {
		my ($content, @cmd) = @_;
		my $fifo = "$tmpdir/key-" . (++$counter) . ".fifo";
		# bash -c: mkfifo with 0600, background-write, run command
		# reading from the fifo, then unlink.  The single-quoted
		# heredoc-style content goes via env var to avoid argv length
		# limits and to keep it out of the trace_args formatting.
		local $ENV{__GENESIS_SSH_FIFO} = $fifo;
		local $ENV{__GENESIS_SSH_KEY}  = $content;
		return run(
			'mkfifo -m 600 "$__GENESIS_SSH_FIFO" && '.
			'{ printf %s\\\\n "$__GENESIS_SSH_KEY" > "$__GENESIS_SSH_FIFO" & } && '.
			'"$@" -f "$__GENESIS_SSH_FIFO"; '.
			'rc=$?; wait; rm -f "$__GENESIS_SSH_FIFO"; exit $rc',
			@cmd
		);
	};

	my ($rendered_public, $priv_rc) = $with_fifo->(
		$values->{private}, 'ssh-keygen', '-y'
	);
	$results{priv} = [ !$priv_rc, "Valid private key" ];

	my ($pub_sig, $pub_rc) = $with_fifo->(
		$values->{public}, 'ssh-keygen', '-B'
	);
	$results{pub} = [ !$pub_rc, "Valid public key" ];

	if (!$priv_rc) {
		my ($rendered_sig, $rendered_rc) = $with_fifo->(
			$rendered_public, 'ssh-keygen', '-B'
		);
		$results{agree} = [
			$rendered_sig eq $pub_sig,
			"Public/Private key Agreement"
		];
	}
	if (!$pub_rc) {
		my ($bits) = $pub_sig =~ /^\s*([0-9]*)/;
		my $size_diff = $bits - $self->get('size');
		my $size_ok = $opts{allow_oversized} ? $size_diff >= 0 : $size_diff == 0;

		$results{size} = [
			$size_ok ? 'ok' : 'warn',
			sprintf(
				"%s bits%s%s",
				$self->get('size'),
				$opts{allow_oversized} ? ' minimum' : '',
				($bits == $self->get('size')) ? '' : " (found $bits bits)"
			)
		];
	}

	return (\%results, qw/priv pub agree size/)
}

# }}}
# __get_safe_command_for_generate - get command components to add or rotate secret {{{
sub __get_safe_command_for_generate {
	my ($self, $action, %opts) = @_;
	debug("%s __get_safe_command_for_generate: unconsumed opts: %s", ref($self), join(', ', sort keys %opts)) if %opts;
	my @cmd = ('ssh', $self->get('size'), $self->full_path);
	push(@cmd, '--no-clobber') if $action eq 'add' || $self->get(fixed => 0);
	return @cmd;
}

sub _get_safe_command_for_add    {shift->__get_safe_command_for_generate('add',@_)}
sub _get_safe_command_for_rotate {shift->__get_safe_command_for_generate('rotate',@_)}

# }}}
# _import_from_credhub - import secret values from credhub {{{
sub _import_from_credhub {
	my ($self,$value) = @_;

	return ('error', 'expecting a hash, got a '.ref($value)//'string') if ref($value) ne 'HASH';
	my @missing = grep {!exists($value->{$_})} qw/private_key public_key public_key_fingerprint/;
	return ('error', "missing keys in credhub secret: ".join(", ", @missing))
		if @missing;

	$self->set_value({
		private     => $value->{private_key},
		public      => $value->{public_key},
		fingerprint => $value->{public_key_fingerprint}
	});
	$self->save;

	return ('ok');
}

# }}}
# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
