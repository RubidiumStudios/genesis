package Genesis::Commands::Dev;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;

use JSON::PP;

### Constants {{{

# Stages renderable from a stored AST.  'parsed' is absent by design: it
# precedes AST construction, so a stored AST cannot reproduce it.
my @STAGES  = qw(ast descriptor output);
my @FORMATS = qw(yaml json);

# }}}
### Command Entry Points {{{

# dev_pipeline_compile - render one CI compiler stage from a stored AST {{{
sub dev_pipeline_compile {
	my $opts = get_options;

	my $file = $opts->{from} or bail(
		"#C{--from <file>} is required.\n".
		"Produce one with #C{genesis pipeline-apply --dry-run --skip-vault ".
		"--debug-dir <dir>} and pass #C{<dir>/02-ast-source.json}."
	);

	print render(
		stage_data(
			load_ast_file($file),
			$opts->{stage}    || 'descriptor',
			$opts->{platform} || 'concourse',
		),
		$opts->{format} || 'yaml',
	);

	return 1;
}

# }}}
# }}}
### Public Methods {{{

# load_ast_file - rebuild an AST object from a debug-dir source dump {{{
sub load_ast_file {
	my ($file) = @_;

	bail("Cannot read AST file #C{%s}: no such file", $file)
		unless defined $file && -f $file;

	my $data = eval { JSON::PP->new->decode(slurp($file)) };
	bail("Cannot parse AST file #C{%s}: %s", $file, $@) if $@;
	bail("AST file #C{%s} must contain a JSON object", $file)
		unless ref($data) eq 'HASH';

	require Genesis::CI::Compiler::AST;
	return Genesis::CI::Compiler::AST->new(%$data);
}

# }}}
# stage_data - render a single compiler stage as a plain data structure {{{
sub stage_data {
	my ($ast, $stage, $platform) = @_;

	$stage    ||= 'descriptor';
	$platform ||= 'concourse';

	bail("Unknown stage #C{%s}: expected one of %s", $stage, join(', ', @STAGES))
		unless grep {$_ eq $stage} @STAGES;

	return _source_data($ast) if $stage eq 'ast';

	require Genesis::CI::Compiler::PipelineDescriptor;
	my $pipeline = Genesis::CI::Compiler::PipelineDescriptor->new(ast => $ast)
		->describe();

	return $pipeline if $stage eq 'descriptor';

	# 'output' realizes the descriptor through the provider, so the generic
	# pipeline has to be published onto the AST first -- providers read only
	# the generic half.
	$ast->set_pipeline($pipeline);
	return _provider_output($ast, $platform);
}

# }}}
# render - serialize a data structure for stdout {{{
sub render {
	my ($data, $format) = @_;

	$format ||= 'yaml';
	bail("Unknown format #C{%s}: expected one of %s", $format, join(', ', @FORMATS))
		unless grep {$_ eq $format} @FORMATS;

	return JSON::PP->new->pretty->canonical->encode($data)
		if $format eq 'json';

	require Genesis::CI::Compiler::PipelineProvider;
	return Genesis::CI::Compiler::PipelineProvider->dump_yaml($data);
}

# }}}
# }}}
### Private Methods {{{

# _source_data - the AST's Genesis-semantic half, as a plain hash {{{
sub _source_data {
	my ($ast) = @_;

	my %source = (
		metadata => $ast->metadata,
		scripts  => $ast->scripts,
	);
	for my $key (qw(branches integrations targets workflows configuration
	                provider_config triggers resources)) {
		my $accessor = $ast->can($key) or next;
		$source{$key} = $accessor->($ast);
	}

	return \%source;
}

# }}}
# _provider_output - run a provider over a resolved AST {{{
sub _provider_output {
	my ($ast, $platform) = @_;

	require Genesis::CI::Compiler;
	my $info = eval {Genesis::CI::Compiler->_resolve_provider_class($platform)};
	bail(
		"Unknown CI provider #C{%s}.  Valid types: %s",
		$platform, join(', ', Genesis::CI::Compiler::PipelineProvider->known_providers())
	) if $@ || !$info;

	eval {require $info->{file}} ## no critic
		or bail("Failed to load CI provider '%s': %s", $platform, $@);

	# No 'top': a stored AST carries no repository, so providers that need
	# repo state (the legacy Concourse bridge) are out of reach here.
	my $output = $info->{class}->new(ast => $ast, provider_opts => {})
		->generate_from_ast($ast);

	return ref($output) eq 'HASH' ? $output : {'pipeline.yml' => $output};
}

# }}}
# }}}

1;

=head1 NAME

Genesis::Commands::Dev

=head1 DESCRIPTION

Developer-only commands for inspecting the CI compiler pipeline.  See the
companion POD in F<Dev.pod> for full documentation.

=cut

# vim: fdm=marker:foldlevel=1:noet
