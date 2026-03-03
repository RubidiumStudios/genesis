package Genesis::Commands::Ocfp;

use strict;
use warnings;

use Genesis;
use Genesis::State;
use Genesis::Term;
use Genesis::Commands;
use Genesis::Top;

=head1 NAME

Genesis::Commands::Ocfp - Command dispatch for OCFP environment management

=head1 SYNOPSIS

  # Registered in bin/genesis via define_command:
  genesis <env> ocfp show network [options]

=head1 DESCRIPTION

Provides the top-level command dispatch for OCFP (Open Cloud Foundry Platform)
environment management and inspection commands.  The dispatch follows a
two-level topic/action pattern:

  ocfp <topic> <action>

Currently supported:

=over 4

=item C<show network>

Display network configuration, IP reservations, allocations, and
availability.  See L<Genesis::Commands::Ocfp::ShowNetwork> for details.

=back

=head1 FUNCTIONS

=head2 ocfp($env_name, $topic, $action, @extra_args)

Top-level entry point registered with C<define_command>.  Validates the
environment is OCFP-enabled, then dispatches to the appropriate topic handler.

B<Parameters:>

=over 4

=item C<$env_name> - Environment name string

=item C<$topic> - The topic (currently only C<show>)

=item C<$action> - The action within the topic (currently only C<network>)

=item C<@extra_args> - Any additional arguments (currently rejected)

=back

Calls C<bail()> if the environment is not OCFP-enabled or if the topic/action
is invalid.

=head2 ocfp_show($env, $action, %options)

Dispatches C<show> topic actions.  Currently supports:

=over 4

=item C<network> - Delegates to L<Genesis::Commands::Ocfp::ShowNetwork/run>

=back

=head1 ENVIRONMENT REQUIREMENTS

The target environment must have the C<ocfp> feature enabled
(C<< $env->is_ocfp >> returns true).  Non-OCFP environments produce a clear
error message.

For create-env environments where the BOSH director exodus data is not
available, commands degrade gracefully by showing OCFP configuration data
without BOSH IP claims.

=head1 SEE ALSO

L<Genesis::Commands::Ocfp::ShowNetwork>, L<Genesis::Commands::Bosh>,
L<Genesis::Env>

=head1 AUTHOR

FiveTwenty, LLC

=cut

# ocfp - Top-level OCFP command dispatch {{{
sub ocfp {
	my %options = %{get_options()};
	my ($env_name, $topic, $action, @extra_args) = @_;

	$topic  //= '';
	$action //= '';

	bail("Too many arguments provided") if @extra_args > 0;

	my @valid_topics = qw(show);
	bail(
		"Invalid topic: '%s' - expected one of: %s",
		$topic, sentence_join(@valid_topics)
	) unless $topic && grep {$_ eq $topic} @valid_topics;

	my $env = Genesis::Top->new('.')->load_env($env_name)->with_vault();

	bail(
		"Environment '%s' is not an OCFP environment.\n".
		"The 'ocfp' command requires an environment with the 'ocfp' feature enabled.",
		$env->name
	) unless $env->is_ocfp;

	if ($topic eq 'show') {
		return ocfp_show($env, $action, %options);
	}
}

# }}}
# ocfp_show - Dispatch 'show' topic actions {{{
sub ocfp_show {
	my ($env, $action, %options) = @_;

	$action //= '';
	my @valid_actions = qw(network);
	bail(
		"Invalid show action: '%s' - expected one of: %s",
		$action, sentence_join(@valid_actions)
	) unless $action && grep {$_ eq $action} @valid_actions;

	if ($action eq 'network') {
		require Genesis::Commands::Ocfp::ShowNetwork;
		return Genesis::Commands::Ocfp::ShowNetwork::run($env, %options);
	}
}

# }}}

1;
