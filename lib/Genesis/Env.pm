package Genesis::Env;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis; # TODO: specify exact imports to not pollute namespace
use Genesis::State;
use Genesis::Term;
use Genesis::UI;
use Genesis::Commands qw/current_command known_commands/;
use Genesis::Env::ManifestProvider;
use Genesis::Env::Secrets::Plan;
use Genesis::Env::Lifecycle;
use Genesis::Env::Properties;
use Genesis::Env::Configuration;
use Genesis::Env::VaultPaths;
use Genesis::Env::BOSH;
use Genesis::Env::CloudConfig;
use Genesis::Env::CPI;
use Genesis::Env::Deployment;
use Genesis::Env::Validation;
use Genesis::Env::OCFP;
use Genesis::Env::Hooks;
use Genesis::Env::Utils;
use Genesis::Env::Vault;
use Genesis::Env::Vars;
use Genesis::Env::Terminate;

use Service::BOSH::Director;
use Service::BOSH::CreateEnvProxy;
use Service::Vault::Remote;
use Service::Vault::Local;
use Service::Vault::None;

use Archive::Tar;
use Data::Dumper;
use Digest::SHA qw/sha1_hex sha256_hex/;
use Digest::file qw/digest_file_hex/;
use Encode qw/decode_utf8/;
use File::Basename qw/basename dirname/;
use File::Path qw/rmtree/;
use IO::Compress::Gzip qw/gzip $GzipError/;
use IO::Uncompress::Gunzip qw/gunzip $GunzipError/;
use JSON::PP qw/encode_json decode_json/;
use MIME::Base64 qw/encode_base64 decode_base64/;
use POSIX qw/strftime/;
use Time::Piece;
use Time::Seconds;
use Time::HiRes qw/gettimeofday/;

use constant {
	EXODUS_TIME_FORMAT => "%Y-%m-%d %H:%M:%S %z",
	EXODUS_TIME_FORMAT_SHORT => "%Y%m%d%H%M%S",
};

### Class Methods {{{

# Import class methods from Lifecycle module
*new = \&Genesis::Env::Lifecycle::new;
*load = \&Genesis::Env::Lifecycle::load;
*from_envvars = \&Genesis::Env::Lifecycle::from_envvars;
*create = \&Genesis::Env::Lifecycle::create;
*exists = \&Genesis::Env::Lifecycle::exists;
*search_for_env_file = \&Genesis::Env::Lifecycle::search_for_env_file;
*_env_name_errors = \&Genesis::Env::Lifecycle::_env_name_errors;
*_genesis_inherits = \&Genesis::Env::Lifecycle::_genesis_inherits;
*_init_yaml_file = \&Genesis::Env::Lifecycle::_init_yaml_file;
*_cap_yaml_file = \&Genesis::Env::Lifecycle::_cap_yaml_file;
# }}}
### Instance Methods {{{

# Import instance methods from Properties module
*name = \&Genesis::Env::Properties::name;
*file = \&Genesis::Env::Properties::file;
*kit = \&Genesis::Env::Properties::kit;
*top = \&Genesis::Env::Properties::top;
*type = \&Genesis::Env::Properties::type;
*path = \&Genesis::Env::Properties::path;
*signature = \&Genesis::Env::Properties::signature;
*deployment_name = \&Genesis::Env::Properties::deployment_name;
*manifest_store = \&Genesis::Env::Properties::manifest_store;
*deployment_state = \&Genesis::Env::Properties::deployment_state;
*is_bosh_director = \&Genesis::Env::Properties::is_bosh_director;
*use_create_env = \&Genesis::Env::Properties::use_create_env;
*can_build_cloud_configs = \&Genesis::Env::Properties::can_build_cloud_configs;
*feature_compatibility = \&Genesis::Env::Properties::feature_compatibility;
*get_call_path = \&Genesis::Env::Properties::get_call_path;
*get_call_path_with_env = \&Genesis::Env::Properties::get_call_path_with_env;
*workpath = \&Genesis::Env::Properties::workpath;
*potential_environment_files = \&Genesis::Env::Properties::potential_environment_files;
*actual_environment_files = \&Genesis::Env::Properties::actual_environment_files;
*relate = \&Genesis::Env::Properties::relate;
*relate_by_name = \&Genesis::Env::Properties::relate_by_name;
*format_yaml_files = \&Genesis::Env::Properties::format_yaml_files;

# Import instance methods from Configuration module
*features = \&Genesis::Env::Configuration::features;
*has_feature = \&Genesis::Env::Configuration::has_feature;
*params = \&Genesis::Env::Configuration::params;
*defines = \&Genesis::Env::Configuration::defines;
*lookup = \&Genesis::Env::Configuration::lookup;
*lookup_unevaled = \&Genesis::Env::Configuration::lookup_unevaled;
*partial_manifest_lookup = \&Genesis::Env::Configuration::partial_manifest_lookup;
*manifest_lookup = \&Genesis::Env::Configuration::manifest_lookup;
*last_deployed_lookup = \&Genesis::Env::Configuration::last_deployed_lookup;
*exodus_lookup = \&Genesis::Env::Configuration::exodus_lookup;
*director_exodus_lookup = \&Genesis::Env::Configuration::director_exodus_lookup;
*deployment_lookup = \&Genesis::Env::Configuration::deployment_lookup;
*dereferenced_kit_metadata = \&Genesis::Env::Configuration::dereferenced_kit_metadata;
*vault_paths = \&Genesis::Env::Configuration::vault_paths;
*scale = \&Genesis::Env::Configuration::scale;
*iaas = \&Genesis::Env::Configuration::iaas;
*prunable_keys = \&Genesis::Env::Configuration::prunable_keys;
*_yaml_files = \&Genesis::Env::Configuration::_yaml_files;

# Import instance methods from VaultPaths module
*env_vault_slug = \&Genesis::Env::VaultPaths::env_vault_slug;
*secrets_mount = \&Genesis::Env::VaultPaths::secrets_mount;
*default_secrets_mount = \&Genesis::Env::VaultPaths::default_secrets_mount;
*secrets_slug = \&Genesis::Env::VaultPaths::secrets_slug;
*default_secrets_slug = \&Genesis::Env::VaultPaths::default_secrets_slug;
*secrets_base = \&Genesis::Env::VaultPaths::secrets_base;
*exodus_mount = \&Genesis::Env::VaultPaths::exodus_mount;
*default_exodus_mount = \&Genesis::Env::VaultPaths::default_exodus_mount;
*exodus_slug = \&Genesis::Env::VaultPaths::exodus_slug;
*exodus_base = \&Genesis::Env::VaultPaths::exodus_base;
*ci_mount = \&Genesis::Env::VaultPaths::ci_mount;
*default_ci_mount = \&Genesis::Env::VaultPaths::default_ci_mount;
*ci_base = \&Genesis::Env::VaultPaths::ci_base;
*ocfp_config_mount = \&Genesis::Env::VaultPaths::ocfp_config_mount;
*default_ocfp_config_mount = \&Genesis::Env::VaultPaths::default_ocfp_config_mount;
*ocfp_config_slug = \&Genesis::Env::VaultPaths::ocfp_config_slug;
*ocfp_config_base = \&Genesis::Env::VaultPaths::ocfp_config_base;
*root_ca_path = \&Genesis::Env::VaultPaths::root_ca_path;

# Import instance methods from BOSH module
*with_bosh = \&Genesis::Env::BOSH::with_bosh;
*bosh_env = \&Genesis::Env::BOSH::bosh_env;
*bosh_alias = \&Genesis::Env::BOSH::bosh_alias;
*bosh = \&Genesis::Env::BOSH::bosh;
*get_target_bosh = \&Genesis::Env::BOSH::get_target_bosh;
*credhub = \&Genesis::Env::BOSH::credhub;
*credhub_connection_env = \&Genesis::Env::BOSH::credhub_connection_env;
*connect_required_endpoints = \&Genesis::Env::BOSH::connect_required_endpoints;
*bosh_logs = \&Genesis::Env::BOSH::bosh_logs;
*logs = \&Genesis::Env::BOSH::logs;
*_parse_bosh_env = \&Genesis::Env::BOSH::_parse_bosh_env;

# Import instance methods from CloudConfig module
*configs = \&Genesis::Env::CloudConfig::configs;
*required_configs = \&Genesis::Env::CloudConfig::required_configs;
*missing_required_configs = \&Genesis::Env::CloudConfig::missing_required_configs;
*has_required_configs = \&Genesis::Env::CloudConfig::has_required_configs;
*download_required_configs = \&Genesis::Env::CloudConfig::download_required_configs;
*download_configs = \&Genesis::Env::CloudConfig::download_configs;
*use_config = \&Genesis::Env::CloudConfig::use_config;
*has_config = \&Genesis::Env::CloudConfig::has_config;
*config_file = \&Genesis::Env::CloudConfig::config_file;
*config_contents = \&Genesis::Env::CloudConfig::config_contents;
*download_cloud_config = \&Genesis::Env::CloudConfig::download_cloud_config;
*use_cloud_config = \&Genesis::Env::CloudConfig::use_cloud_config;
*cloud_config = \&Genesis::Env::CloudConfig::cloud_config;
*download_runtime_config = \&Genesis::Env::CloudConfig::download_runtime_config;
*use_runtime_config = \&Genesis::Env::CloudConfig::use_runtime_config;
*runtime_config = \&Genesis::Env::CloudConfig::runtime_config;
*_check_cloud_config = \&Genesis::Env::CloudConfig::_check_cloud_config;
*_fix_cloud_config = \&Genesis::Env::CloudConfig::_fix_cloud_config;
*director_config_overrides = \&Genesis::Env::CloudConfig::director_config_overrides;
*get_network_claims = \&Genesis::Env::CloudConfig::get_network_claims;

# Import instance methods from CPI module
*bosh_config_name = \&Genesis::Env::CPI::bosh_config_name;
*bosh_config_names = \&Genesis::Env::CPI::bosh_config_names;
*cpi_enabled = \&Genesis::Env::CPI::cpi_enabled;
*cpi_config = \&Genesis::Env::CPI::cpi_config;
*cpi_name = \&Genesis::Env::CPI::cpi_name;
*cpi_credhub_base = \&Genesis::Env::CPI::cpi_credhub_base;
*_check_cpi_config = \&Genesis::Env::CPI::_check_cpi_config;
*_fix_cpi_config = \&Genesis::Env::CPI::_fix_cpi_config;

# Import instance methods from Deployment module
*has_hook = \&Genesis::Env::Deployment::has_hook;
*run_hook = \&Genesis::Env::Deployment::run_hook;
*shell = \&Genesis::Env::Deployment::shell;
*manifest_provider = \&Genesis::Env::Deployment::manifest_provider;
*deployment_manifest_type = \&Genesis::Env::Deployment::deployment_manifest_type;
*last_deployed_manifest = \&Genesis::Env::Deployment::last_deployed_manifest;
*deployment_cache_setup = \&Genesis::Env::Deployment::deployment_cache_setup;
*deployment_cache_cleanup = \&Genesis::Env::Deployment::deployment_cache_cleanup;
*deployment_cache_path_lookup = \&Genesis::Env::Deployment::deployment_cache_path_lookup;
*deploy = \&Genesis::Env::Deployment::deploy;
*extract_manifest_exodus = \&Genesis::Env::Deployment::extract_manifest_exodus;
*notify = \&Genesis::Env::Deployment::notify;
*add_secrets = \&Genesis::Env::Deployment::add_secrets;
*check_secrets = \&Genesis::Env::Deployment::check_secrets;
*rotate_secrets = \&Genesis::Env::Deployment::rotate_secrets;

# Import instance methods from Validation module
*_check_environment_viability = \&Genesis::Env::Validation::_check_environment_viability;
*_check_secrets = \&Genesis::Env::Validation::_check_secrets;
*_fix_secrets = \&Genesis::Env::Validation::_fix_secrets;
*_check_release_overrides = \&Genesis::Env::Validation::_check_release_overrides;
*_check_stemcells = \&Genesis::Env::Validation::_check_stemcells;
*_fix_stemcells = \&Genesis::Env::Validation::_fix_stemcells;
*_validate_reactions = \&Genesis::Env::Validation::_validate_reactions;
*_process_reactions = \&Genesis::Env::Validation::_process_reactions;
*_reactions = \&Genesis::Env::Validation::_reactions;
*_advise_stemcell_updates = \&Genesis::Env::Validation::_advise_stemcell_updates;
*_get_stemcell_status = \&Genesis::Env::Validation::_get_stemcell_status;

# Import instance methods from OCFP module
*is_ocfp = \&Genesis::Env::OCFP::is_ocfp;
*ocfp_type = \&Genesis::Env::OCFP::ocfp_type;
*ocfp_env = \&Genesis::Env::OCFP::ocfp_env;
*ocfp_config = \&Genesis::Env::OCFP::ocfp_config;
*ocfp_config_lookup = \&Genesis::Env::OCFP::ocfp_config_lookup;

# Import instance methods from Hooks module
*kit_files = \&Genesis::Env::Hooks::kit_files;
*can_be_entombed = \&Genesis::Env::Hooks::can_be_entombed;

# Import instance methods from Utils module
*vars_file = \&Genesis::Env::Utils::vars_file;
*deployment_manifest = \&Genesis::Env::Utils::deployment_manifest;
*exodus = \&Genesis::Env::Utils::exodus;
*secrets_store = \&Genesis::Env::Utils::secrets_store;
*secrets_plan = \&Genesis::Env::Utils::secrets_plan;
*remove_secrets = \&Genesis::Env::Utils::remove_secrets;
*import_secrets = \&Genesis::Env::Utils::import_secrets;
*_cc_yaml_files = \&Genesis::Env::Utils::_cc_yaml_files;
*_reset_last_deployed_manifest = \&Genesis::Env::Utils::_reset_last_deployed_manifest;
*_build_deployment_audit_data = \&Genesis::Env::Utils::_build_deployment_audit_data;
*_build_deployment_artifacts = \&Genesis::Env::Utils::_build_deployment_artifacts;

# Import instance methods from Vault module
*vault = \&Genesis::Env::Vault::vault;
*with_vault = \&Genesis::Env::Vault::with_vault;
*get_ancestral_vault = \&Genesis::Env::Vault::get_ancestral_vault;

# Import instance methods from Vars module
*get_environment_variables = \&Genesis::Env::Vars::get_environment_variables;
*env_config_overrides = \&Genesis::Env::Vars::env_config_overrides;
*is_vaultified = \&Genesis::Env::Vars::is_vaultified;

# Import instance methods from Terminate module
*terminate = \&Genesis::Env::Terminate::terminate;

# Import instance methods from Deployment module (additional methods)
*check = \&Genesis::Env::Deployment::check;
*get_next_deployment_sequence_number = \&Genesis::Env::Deployment::get_next_deployment_sequence_number;
*update_deployment_exodus = \&Genesis::Env::Deployment::update_deployment_exodus;
*_unpack_deployment_artifacts = \&Genesis::Env::Deployment::_unpack_deployment_artifacts;
*_backfill_deployment_audit_data = \&Genesis::Env::Deployment::_backfill_deployment_audit_data;
*_create_deployment_audit_log = \&Genesis::Env::Deployment::_create_deployment_audit_log;


# }}}

1;
# vim: fdm=marker:foldlevel=1:noet
