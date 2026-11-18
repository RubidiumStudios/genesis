package Genesis::Helpers;

my $SCRIPT;

sub write {
	my ($class, $file) = @_;

	open my $fh, ">", $file
		or die "Could not open $file for writing the helpers script: $!\n";

	if (!$SCRIPT) {
		$SCRIPT = do { local $/, <DATA> };
		close(DATA);
	}

	print $fh $SCRIPT;
	close $fh;
}

sub log_from_script {

	require Genesis;
	require Genesis::Config;
	require Genesis::Log;
	$Genesis::RC ||= Genesis::Config->new($ENV{HOME}."/.genesis/config");
	Genesis::Log->setup_from_configs($Genesis::RC->get("logs",[]));

	binmode STDOUT, ":encoding(UTF-8)";
	binmode STDERR, ":encoding(UTF-8)";

	my $log_cmd = \&Genesis::info;

	if ($_[0] =~ /^@/) {
		(my $log_level = lc(shift)) =~ s/^@//;
		$log_cmd = 'Genesis'->can($log_level);
		Genesis::bug(
			"$log_level is not a valid log command for Genesis"
		) unless $log_cmd;
	}
	$log_cmd->({show_stack => 'none'},Genesis::fix_wrap(join("\n",@_)));
	return;
}


1;

__DATA__

if [[ "${GENESIS_TRACE:-}" == "y" ]] ; then
  # Names only: the values include the credentials Genesis hands the hook.
  echo >&2 "TRACE> Helper script environment variables (values not shown):"
  compgen -e | sort | sed 's/^/  /' >&2
fi

genesis() {
  [[ -z "${GENESIS_CALLBACK_BIN}" ]] \
    && echo >&2 "Genesis command not specified - this is a bug in Genesis, or you are running $0 outside of Genesis" \
    && exit 2
  command "${GENESIS_CALLBACK_BIN}" -C "$GENESIS_ROOT" "$@"
  return $?
}
export -f genesis

describe() {
  /usr/bin/perl -I$GENESIS_LIB -MGenesis::Term -e 'binmode STDOUT, ":encoding(UTF-8)"; printf csprintf("%s\n",$_) for @ARGV' "$@"
}

export -f describe

genesis_log() {
	/usr/bin/perl -I$GENESIS_LIB -MGenesis::Helpers -e 'Genesis::Helpers::log_from_script(@ARGV)' "$@"
}

export -f genesis_log

titleize() {
	if [[ $# -gt 0 ]] ; then
		echo "$@" | /usr/bin/perl -e "while (<STDIN>) { s/([\\w']+)/\\u\\L\$1/g; print }"
	fi
}
export -f titleize

humanize_path() {
  /usr/bin/perl -I$GENESIS_LIB -MGenesis -e 'binmode STDOUT, ":encoding(UTF-8)"; print humanize_path("$ARGV[0]")' "$1"
}
export -f humanize_path

__bail() {
  local rc=1
  [[ "$1" == "--rc" ]] && rc="$2" && shift 2
  genesis_log @fatal "$@" >&2
  exit $rc
}
export -f __bail

# Make __bail available as bail because internal functions shouldn't be used by non-helpers
bailfunc="$(declare -f "__bail")"
eval "${bailfunc/__bail/bail}"
export -f bail

# Protect safe calls if safe target is not set correctly
if [[ -z "$SAFE_TARGET" || "$SAFE_TARGET" != "$GENESIS_TARGET_VAULT" ]] ; then
  safe() {
    __bail "Safe target not associated with Genesis Vault -- this is a bug in Genesis, or you are running $0 outside of Genesis"
  }
  export -f safe
fi

###
###   Exodus Data Exfiltration Functions
###

# exodus - lookup exodus data about this or other deployments / envs.
#
# USAGE:  exodus some-key
#         exodus other-env/type their-key
#
# Examples:
#
#    # what version was I last deployed with?
#    exodus kit_version
#
#    # what is the TSA URL of my Concourse?
#    exodus my-proto/concourse tsa_url
#
#    # what is the CF URL of my local instance?
#    exodus $GENESIS_ENVIRONMENT/cf api_url
#
exodus() {
  # movement of the people
  local __env __key
  __env="$GENESIS_ENVIRONMENT/$GENESIS_TYPE"
  __key=${1:?exodus() must provide at least an exodus key}
  if [[ -n ${2:-} ]]; then
    __key=$2
    __env=$1
  fi
  if [[ "$__key" == "--all" ]] ; then
    if safe exists "${GENESIS_EXODUS_MOUNT}${__env}"; then
      safe get ${GENESIS_EXODUS_MOUNT}${__env} | spruce json | jq -r .
    fi
  else
    if safe exists "${GENESIS_EXODUS_MOUNT}${__env}:${__key}"; then
      safe get "${GENESIS_EXODUS_MOUNT}${__env}:${__key}"
    fi
  fi
}
export -f exodus

# have_exodus_data_for env/type - return true if exodus data exists
have_exodus_data_for() {
  local __env=${1:?have_exodus_data_for() must provide an environment/type}
  safe exists "${GENESIS_EXODUS_MOUNT}${__env}"
  return $?
}
export -f have_exodus_data_for

have_exodus_data() {
  have_exodus_data_for "${GENESIS_ENVIRONMENT}/${GENESIS_TYPE}"
  return $?
}
export -f have_exodus_data

###
### new_enough - Check semantic versions
###
### USAGE: new_enough $have $minimum
###
new_enough() {
  check_errors="$(printf %s\\n "$-" | grep 'e' 2>/dev/null)";
  set +e
  local __have=${1:?new_enough() requires an actual version as the first argument}
  local __min=${2:?new_enough() requires an actual version as the second argument}
  genesis ui-semver "$__have" ge "$__min"
  rc=$?
  [[ -z "$check_errors" ]] || set -e
  return $rc # stop -e in the calling scope from failing
}
export -f new_enough

###
###   Environment File Inspection Functions
###

# lookup key [default]
#
# Looks up the key in the environment files, taken as
# an skip-eval'd spruce merge.
#
# If the key is not found, $default is returned as a
# value.  If $default is not set, the empty string will
# be used instead.
#
lookup() {
  genesis lookup "$GENESIS_ENVIRONMENT" "$@"
}
export -f lookup

deployed() {
  lookup --exodus dated --defined
  return $?
}
export -f deployed

typeof() {
  local __key=${1:?typeof() - must specify a key to look up}
  local __val
  __val="$(genesis lookup "$GENESIS_ENVIRONMENT" "$__key" "" | sed -e 's/\(.\).*/\1/')"
  if [[ $__val == "{" ]]; then
    echo "map"
  elif [[ $__val == "[" ]]; then
    echo "list"
  elif [[ $__val == "" ]]; then
    echo ""
  else
    echo "scalar"
  fi
}
export -f typeof

###
###   BOSH Inspection Functions
###

bosh() {
  if [[ -f ${GENESIS_ROOT}/${GENESIS_ENVIRONMENT}.yml ]] ; then
    command "${GENESIS_CALLBACK_BIN}" "${GENESIS_ROOT}/${GENESIS_ENVIRONMENT}.yml" bosh "$@"
    rc="$?"
    [[ "$rc" == "0" ]] && export GENESIS_BOSH_VERIFIED="$BOSH_ALIAS"
    return "$rc"
  fi

  # Do things the old way if there is no environment yaml for any reason...
  [[ -z "${GENESIS_BOSH_COMMAND:-}" ]] && \
    __bail "" "#R{[ERROR]} BOSH CLI command not specified - this is a bug in Genesis, or you are running $0 outside of Genesis"

  if [[ -z "${BOSH_ENVIRONMENT:-}" || -z "${BOSH_CA_CERT:-}" ]] ; then
    # Try to get the env vars...
    if [[ -n "${BOSH_ALIAS}" ]] ; then
      perl_script="$(cat <<'      EOF'
      my $bosh=(
        Service::BOSH::Director->from_exodus($ENV{BOSH_ALIAS}) ||
        Service::BOSH::Director->from_alias($ENV{BOSH_ALIAS})
      );
      unless ($bosh) {
        print "__bail 'Could not connect to $ENV{BOSH_ALIAS}'\n";
        exit 0;
      }
      my %vars = $bosh->environment_variables;
      for (keys %vars) {
        next unless /^[A-Za-z_][A-Za-z0-9_]*$/;
        my $val = defined $vars{$_} ? $vars{$_} : '';
        $val =~ s/'/'\"'\"'/g;
        print "export $_='$val'\n";
      }
      EOF
      )"
      eval "$(/usr/bin/perl -I$GENESIS_LIB -MService::BOSH::Director -e "$perl_script")"
    fi
    [[ -z "${BOSH_ENVIRONMENT:-}" || -z "${BOSH_CA_CERT:-}" ]] && \
      __bail "" "#R{[ERROR]} Environment not found for BOSH Director -- please ensure you've configured your BOSH alias used by this environment"
  fi

  if [[ -z "${GENESIS_BOSH_VERIFIED:-}" || "$GENESIS_BOSH_VERIFIED" != "${BOSH_ALIAS:-}" ]] ; then
    # Genesis has not yet validate the BOSH director's availability, so we need to
    if /usr/bin/perl -I$GENESIS_LIB -MService::BOSH::Director -e 'exit(Service::BOSH::Director->from_environment()->connect_and_validate()?0:1)' ; then
      GENESIS_BOSH_VERIFIED="$BOSH_ALIAS"
    else
      __bail "" "#R{[ERROR]} Could not connect to BOSH director '#M{$BOSH_ALIAS}' (#M{$BOSH_ENVIRONMENT})"
    fi
  fi

  # The same launcher Genesis uses turns bosh's debug logging off, since it
  # writes director requests and tokens to BOSH_LOG_PATH or the output.
  # GENESIS_BOSH_COMMAND is split into words as it always was; the rest of
  # the arguments reach bosh exactly as given.
  # shellcheck disable=SC2086
  /usr/bin/perl -I"$GENESIS_LIB" -MService::BOSH -e 'Service::BOSH::exec_managed(@ARGV)' -- ${GENESIS_BOSH_COMMAND} "$@"
  return $?
}
export -f bosh

bosh_cpi() {
  local __have_env
  if [[ -n "${GENESIS_TESTING_BOSH_CPI:-}" ]] ; then
    genesis_log @TRACE "Using supplied CPI of '$GENESIS_TESTING_BOSH_CPI' instead of fetching from BOSH director" >&2
    echo "$GENESIS_TESTING_BOSH_CPI"
    return 0
  fi
  __have_env="$(bosh env --json 2>/dev/null | jq -r '.Tables[0].Rows[0].cpi')"
  if [[ "$?" != "0" ]] ; then
    __bail "Cannot determine CPI from BOSH director - failed to communicate with BOSH director"
  fi
  [[ -z "${__have_env}" || "${__have_env}" == "null" ]] && \
    __bail "Cannot determine CPI from BOSH director - no response from BOSH director"

  echo "${__have_env%_cpi}"
  return 0
}
export -f bosh_cpi

use_create_env() {
	if ! new_enough "${GENESIS_MIN_VERSION_FOR_KIT:-0.0.0}" "2.8.6-rc1" ; then
		if [[ -z "${GENESIS_REQUESTED_FEATURES+x}" ]] ; then
			return 1 # We don't know what features are requested, so assume not
		fi
		want_feature "proto" # bosh kit is the only pre-v2.8.0 use-create-env kit
	else
		[[ "${GENESIS_USE_CREATE_ENV:-false}" == "true" ]]
	fi
}
export -f use_create_env

###
###   Cloud-Config Inspection Functions
###
export __cloud_config_ok="yes"

# Support function for cloud_config_needs static_ips
__ip2dec() {
  local __acc=0 IFS='.' __b __ip="$1"
  # this doesn't work if __ip[@] is quoted (using IFS to split on .) - shellcheck warns that it's not quoted
  # https://github.com/koalaman/shellcheck/wiki/SC2068
  # shellcheck disable=SC2068
  for __b in ${__ip[@]} ; do
    (( __acc = (__acc << 8) + __b ))
  done
  unset IFS
  echo $__acc
}
export -f __ip2dec

declare -a __checked_cloud_config
__checked_cloud_config=( '' )
__in_cloudconfig_check=''
cloud_config_needs() {
  local __type=${1:?cloud_config_needs() - must specify a type}; shift
  local __name
  local __unbound_check=0
  if [[ $- =~ 'u' ]] ; then
    set +u
    __unbound_check=1
  fi

  if [[ -z "$__in_cloudconfig_check" ]] ; then
    describe "  #C{[Checking cloud config]}"
    __in_cloudconfig_check=1
  fi

  # Special check for static_ips
  if [[ "${__type}" == "static_ips" ]] ; then
    local __network=${1:?cloud_config_needs(static_ips) - must supply network name}; shift
    local __count=${1:?cloud_config_needs(static_ips) - must supply static_ip count} ; shift

    local __ips __sum=0 __f __x __l
    __ips=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
      jq -r --arg network "$__network" '.networks[]| select(.name == $network) | .subnets[] | .static[]')

    while read -r __range ; do
      [[ -z "$__range" ]] && continue # blank line
      if echo "$__range" | grep -q '^\s*[\.0-9]*\(\s*-\s*[0-9\.]*\)\{0,1\}\s*$' ; then
        read -r __f __x __l < <(
          echo "$__range" | \
          sed 's/^[[:space:]]*\([^-[:space:]]*\)[[:space:]]*\(\(-\)[[:space:]]*\(.*\) \)\{0,1\}/\1 \3 \4/' | \
          sed -e 's/[[:space:]]$//' )
        if [[ -z "$__x" && -z "$__l" ]] ; then
          (( __sum++ )) # Single ip
        elif [[ "$__x" == '-' ]] ; then
          (( __sum += $(__ip2dec "$__l") - $(__ip2dec "$__f") + 1 )) # Range
        fi
        __cloud_config_error_messages+=( "    [#G@{+}] network '$__network' has valid static ips #G{('$__range')} ")
      else
        __cloud_config_error_messages+=( "    [#R@{-}] network '$__network' has valid static ips #R{(parse error on '$__range')} ")
        __cloud_config_ok=no
        break
      fi
    done < <(echo "${__ips}")
    if [[ "$__sum" -lt "$__count" ]] ; then
      __cloud_config_error_messages+=( "    [#R@{-}] network '$__network' has sufficient static ips #R{(found $__sum, need $__count)} ")
      __cloud_config_ok=no
    else
      __cloud_config_error_messages+=( "    [#G{+}] network '$__network' has sufficient static ips #G{(found $__sum, need $__count)} ")
    fi
    if [[ -n "$__in_cloudconfig_check" ]] ; then
      describe "${__cloud_config_error_messages[@]}"
      __cloud_config_error_messages=()
    fi
  fi

  # Generic pattern
  case "${__type}" in
  vm_type|vm_types)            __type=vm_types;      __name=vm_type      ;;
  vm_extension|vm_extensions)  __type=vm_extensions; __name=vm_extension ;;
  network|networks)            __type=networks;      __name=network      ;;
  disk_type|disk_types)        __type=disk_types;    __name=disk_type    ;;
  az|azs)                      __type=azs;           __name=az           ;;
  *) __bail --rc 77
            "cloud_config_needs(): invalid cloud-config object type '$__type'; must be one of" \
            "                      'vm_type', 'vm_extension', 'disk_type', 'network', or 'az'" ;;
  esac

  local __want __have __token
  for __want in "$@"; do
    __token="$__name:$__want"
    if ! (IFS=$'\n'; echo "${__checked_cloud_config[*]}") | grep '^'$__token'$' >/dev/null 2>&1 ; then
      __checked_cloud_config+=("$__token")
      __have=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
        jq -r "if ((.${__type}//[])[] | select(.name == \"$__want\")) then 1 else 0 end")
      if [[ -z "$__have" ]]; then
        __cloud_config_ok=no
        __cloud_config_error_messages+=( "    [#R@{-}] $__name '#Y{$__want}' exists" )
      else
        __cloud_config_error_messages+=( "    [#G@{+}] $__name '#Y{$__want}' exists" )
      fi
    fi
  done
  if [[ -n "$__in_cloudconfig_check" ]] ; then
    describe "${__cloud_config_error_messages[@]}"
    __cloud_config_error_messages=( )
  fi

  [[ "$__unbound_check" = '1' ]] && set -u
}
export -f cloud_config_needs

check_cloud_config() {
  # check_cloud_config - outputs errors found by cloud_config_needs.  Returns 1
  # if any errors were found.
  # Usage:
  #   check_cloud_config || exit 1  # exit if errors found
  #   check_cloud_config && describe "  cloud config [#G{OK}] # report ok if no errors
  if [[ -z "$__in_cloudconfig_check" ]] ;then
    describe "  #C{[Checking cloud config]}"
    describe "${__cloud_config_error_messages[@]}"
  fi
  if [[ ${__cloud_config_ok} != "yes" ]]; then
    return 1
  fi
}
export -f check_cloud_config

cloud_config_has() {
  local __type=${1:?cloud_config_has() - must specify a type}
  local __want=${2:?cloud_config_has() - must specify a name}
  local __name
  case "${__type}" in
  vm_type|vm_types)            __type=vm_types;      __name=vm_type      ;;
  vm_extension|vm_extensions)  __type=vm_extensions; __name=vm_extension ;;
  network|networks)            __type=networks;      __name=network      ;;
  disk_type|disk_types)        __type=disk_types;    __name=disk_type    ;;
  az|azs)                      __type=azs;           __name=az           ;;
  *) __bail --rc 77
            "cloud_config_has(): invalid cloud-config object type '$__type'; must be one of" \
            "                    'vm_type', 'vm_extension', 'disk_type', 'network', or 'az'" ;;
  esac

  __have=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
    jq -r "if ((.${__type}//[])[] | select(.name == \"$__want\")) then 1 else 0 end")
  if [[ -n "$__have" ]]; then
    return 0
  else
    return 1
  fi
}
export -f cloud_config_has

export __cc_data=
ccq() {
  [[ -z "${GENESIS_CLOUD_CONFIG+x}" ]] && bail "Cloud config contents not available - cannot continue"
  [[ -z "${__cc_data}" ]] && __cc_data="$(spruce json "$GENESIS_CLOUD_CONFIG")"
  echo "$__cc_data" | jq -r "$@"
}
export -f ccq

export __rc_data=
rcq() {
  [[ -z "${GENESIS_RUNTIME_CONFIG+x}" ]] && bail "Runtime config contents not available - cannot continue"
  [[ -z "${__rc_data}" ]] && __rc_data="$(spruce json "$GENESIS_RUNTIME_CONFIG")"
  echo "$__rc_data" | jq -r "$@"
}
export -f rcq

###
###   Feature Flag Functions
###

# want_feature X
#
# Returns true (0) if the named feature was specified in the
# list of feature flags for the current environment.
#
# Example usage:
#
#    if want_feature uaa-auth; then
#      uaa --something or-other
#    fi
#
want_feature() {
  local __want=${1:?want_feature() -- must specify a feature}
  local __feature
  for __feature in $GENESIS_REQUESTED_FEATURES; do
    [[ "$__want" == "$__feature" ]] && return 0
  done
  return 1
}
export -f want_feature

# invalid_features
#
# Prints a list of requested features that were not listed
# in the (given) list of defined / valid features.
#
# Example:
#
#    for bad in $(invalid_features x y z); then
#      echo "ERROR: $bad is not a valid feature (not one of x, y, or z)"
#    done
#
invalid_features() {
  local __found
  local __valid
  local __have
  declare -a __invalid
  for __have in $GENESIS_REQUESTED_FEATURES; do
    [[ "$__have" =~ ^\+ ]] && continue
    __found='';
    for __valid in "$@"; do
      [[ "$__have" == "$__valid" ]] && __found=1 && break
    done
    [[ -n $__found ]] || __invalid+=("$__have")
  done
  [[ "${#__invalid[@]}" -gt 0 ]] && \
    echo "${__invalid[@]}"
  return 0
}
export -f invalid_features

valid_features() {
  local __have
  local __found
  local __valid
  for __have in $GENESIS_REQUESTED_FEATURES; do
    [[ "$__have" =~ ^\+ ]] && continue
    __found=''
    for __valid in "$@"; do
      [[ "${__have}" = "${__valid}" ]] && __found=1 && break
    done
    [[ -n $__found ]] || return 1
  done
  return 0
}
export -f valid_features

validate_features() {
  local __bad
  if ! valid_features "$@"; then
    __bail "#R{[ERROR]} $GENESIS_KIT_ID does not understand the following feature flags:" \
      "$(for __bad in $(invalid_features "$@"); do echo " - $__bad"; done; echo)"
  fi
}
export -f validate_features

prompt_for() {
  local __var="$1" __type="$2"; shift 2;
  if [[ "$__type" =~ ^secret- ]] ; then
    genesis ui-prompt-for "$__type" "$__var" "$@"
    local __rc="$?"
    [[ $__rc -ne 0 ]] && echo "Error encountered - cannot continue" && exit $__rc
  else
    local __tmpfile
    __tmpfile=$(mktemp);
    [[ $? -ne 0 ]] && echo >&2 "Failed to create tmpfile: $__tmpfile" && exit 2
    genesis ui-prompt-for "$__type" "$__tmpfile" "$@"
    local __rc="$?"
    if [[ $__rc -ne 0 ]] ; then
      # error
      rm -f "$__tmpfile"
      __bail --rc "$__rc" "Error encountered - cannot continue";
    fi
    if [[ $__type =~ ^multi- ]] ; then
      eval "unset $__var; ${__var}=()"
      # __block is escaped in eval, shellcheck thinks its unused
      # https://github.com/koalaman/shellcheck/wiki/SC2034
      # shellcheck disable=SC2034
      while IFS= read -rd '' __block; do
        eval "${__var}+=( \"\$__block\" )"
      done < "$__tmpfile"
    else
      eval "$__var=\$(<\"$__tmpfile\")"
    fi
    rm -f "$__tmpfile"
  fi
  return 0
}
export -f prompt_for

param_entry() {
  local __disabled=""
  local __varname="${1:?param_entry - missing variable name}"
  local     __key="${2:?param_entry - missing key}"
  local     __opt="${3:-}"
  shift 3 || true
  if [[ "$__opt" == "-d" ]] ; then
    __disabled="#"
    __opt="${1:-}" ; shift || true
  fi
  if [[ "$__opt" == "-a" ]] ; then
    if [[ "${#@}" -eq 0 ]] ; then
      eval "$__varname+=\"  $__disabled\$__key: []\\n\""
    else
      eval "$__varname+=\"  $__disabled\$__key:\\n\""
      local __line
      for __line in "$@" ; do
        if [[ "$(echo "$__line" | wc -l)" -gt 1 ]] ; then
          __line="|-"$'\n'"$(echo "$__line" | sed -e "s/^\\(.\\)/  $__disabled  \\1/")"
        fi
        eval "$__varname+=\"  \$__disabled- \$__line\\n\""
      done
    fi
  else
    if [[ -z "$__opt" ]] ; then
      __opt="$(eval "echo \"\$$__key\"")"
    fi
    if [[ "$(echo "$__opt" | wc -l)" -gt 1 ]] ; then
      __opt="|-"$'\n'"$(echo "$__opt" | sed -e "s/^\\(.\\)/  $__disabled  \\1/")"
    fi
    eval "$__varname+=\"  $__disabled\$__key: \$__opt\\n\""
  fi
}
export -f param_entry

param_comment() {
  # Usage: param_comment <var> [-e] [line ...]
  #
  # Adds the lines specified to the contents of the variable passed by
  # reference.  If `-e` is specified, also echos the lines to the users screen
  # so it can be used as a preamble in front of a prompt for a value (see
  # param_entry)

  local __line __echo __varname=$1; shift
  if [[ "$1" == '-e' ]] ; then
    __echo="true"; shift
  fi
  eval "$__varname+=\"\\n\""
  [[ -n $__echo ]] && echo ""
  # __line is escaped in eval, shellcheck thinks its unused
  # https://github.com/koalaman/shellcheck/wiki/SC2034
  # shellcheck disable=SC2034
  for __line in "$@" ; do
    eval "$__varname+=\"  # \$__line\\n\""
    [[ -n $__echo ]] && echo "$__line"
  done
}
export -f param_comment

# Helper to inject new Genesis configuration (v2.6.13+)
genesis_config_block() {
	config_block="$(
	if [[ "${GENESIS_USE_CREATE_ENV:-}" == "true" ]] ; then
		cat <<EOF
  bosh_env:       ((prune))
EOF
	elif [[ "${BOSH_ALIAS:-}" != "${GENESIS_ENVIRONMENT:-}" && -n "${BOSH_ALIAS:-}" ]] ; then
		cat <<EOF
  bosh_env:       $BOSH_ALIAS
EOF
	fi
	if [[ -n "${GENESIS_ENV_VAULT_DESCRIPTOR:-}" ]] ; then
		# The alias is a safe target name, which may hold characters YAML reads
		# as a comment or a mapping, so anything but a plain URL and plain words
		# is quoted.
		vault_desc="$GENESIS_ENV_VAULT_DESCRIPTOR"
		plain_desc='^https?://[A-Za-z0-9._/:+!@=%~-]*[A-Za-z0-9._/+!@=%~-]( [A-Za-z0-9._/+!@=%~-]+)*$'
		if ! [[ $vault_desc =~ $plain_desc ]] ; then
			vault_desc="'$(printf '%s' "$vault_desc" | sed "s/'/''/g")'"
		fi
		cat <<EOF
  vault:          $vault_desc
EOF
	fi
	if [[ -n "${GENESIS_MIN_VERSION:-}" && $GENESIS_MIN_VERSION != '0.0.0' ]] ; then
		cat <<EOF
  min_version:    $GENESIS_MIN_VERSION
EOF
	fi
	if [[ -n "${GENESIS_SECRETS_SLUG_OVERRIDE:-}" ]] ; then
		cat <<EOF
  secrets_path:   $GENESIS_SECRETS_SLUG
EOF
	fi
	if [[ -n "${GENESIS_SECRETS_MOUNT_OVERRIDE:-}" ]] ; then
		cat <<EOF
  secrets_mount:  $GENESIS_SECRETS_MOUNT
EOF
	fi
	if [[ -n "${GENESIS_EXODUS_MOUNT_OVERRIDE:-}" ]] ; then
		cat <<EOF
  exodus_mount:   $GENESIS_EXODUS_MOUNT
EOF
	fi
	if [[ -n "${GENESIS_CI_MOUNT_OVERRIDE:-}" ]] ; then
		cat <<EOF
  ci_mount:       $GENESIS_CI_MOUNT
EOF
	fi
	if [[ -n "${GENESIS_ROOT_CA_PATH:-}" ]] ; then
		cat <<EOF
  root_ca_path:   $GENESIS_ROOT_CA_PATH
EOF
	fi
	if [[ -n "${GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE:-}" ]] ; then
		cat <<EOF
  credhub_env:    $GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE
EOF
	fi
	)"
	echo ""
	echo "genesis:"
	padding=""

	if use_create_env || [[ -n $config_block ]] ; then
		padding="           "
	fi
	echo "  env: ${padding}$GENESIS_ENVIRONMENT"

	if use_create_env ; then
		echo "  use_create_env: true"
	fi
	if [[ -n $config_block ]] ; then
		echo "$config_block"
	fi
	echo ""
}
export -f genesis_config_block

offer_environment_editor() {
  local __edit_query="${1:-''}"
  local __file __tmpdir __editor __editor_cmd
  if [[ "$__edit_query" != 'true' ]] ; then
    prompt_for __edit_query boolean \
      "Would you like to edit the '$GENESIS_ENVIRONMENT.yml' environment file?" \
      --inline
  fi

  if [[ $__edit_query == 'true' ]] ; then
    local __unbound_check=0
    if [[ $- =~ 'u' ]] ; then
      set +u
      __unbound_check=1
    fi
    __file="$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml"
    # Shellcheck doesn't know that GENESIS_KIT_VERSION is always supplied.
    # https://github.com/koalaman/shellcheck/wiki/SC2153
    # shellcheck disable=SC2153
    __tmpdir="$(mktemp -d)/$GENESIS_KIT_NAME-$GENESIS_KIT_VERSION"
    mkdir -p "$__tmpdir"
    [[ -n $EDITOR ]] || EDITOR="vim"
    if $GENESIS_CALLBACK_BIN -C $GENESIS_ROOT man --raw "$(basename "$__file")" > "$__tmpdir/manual.md" ; then
      __editor="$(basename $EDITOR)"
      [[ $__editor =~ ^.*vim?$ ]] && \
        __editor_cmd="$EDITOR -O '$__file' '$__tmpdir/manual.md'"
      [[ $__editor == "emacs" ]] && \
        __editor_cmd="$EDITOR -nw '$__file' -f split-window-horizontally '$__tmpdir/manual.md' -f other-window"
    fi
    [[ -n "$__editor_cmd" ]] || __editor_cmd="$EDITOR '$__file'"
    env -i HOME="$HOME" SHELL="$(which bash)" USER="$USER" COLORTERM="$COLORTERM" TERM="$TERM" bash -l -c "cd \"$GENESIS_ROOT\" && $__editor_cmd"
    [[ -f $__tmpdir/manual.md ]] && rm "$__tmpdir/manual.md"
    rmdir "$__tmpdir"
    rmdir "$(dirname "$__tmpdir")"
    [[ "$__unbound_check" = '1' ]] && set -u
  fi
}
export -f offer_environment_editor

# __genesis_exact_value VAR CMD... - run CMD, and set VAR to what it printed
# byte for byte, less the one newline that safe and the CredHub reader end
# a value with.  Command substitution alone drops every trailing newline,
# which would change a value that ends in one.  Returns CMD's exit status.
__genesis_exact_value() {
  local __var="$1" __got __rc ; shift
  __got="$("$@" && printf x)" && __rc=0 || __rc=$?
  [[ $__rc -eq 0 ]] || return $__rc
  __got="${__got%x}"
  printf -v "$__var" '%s' "${__got%$'\n'}"
}
export -f __genesis_exact_value

# __genesis_vault_kv_version SECRET - the kv version of the mount holding
# SECRET: prints 2 or 1 and returns 0, or returns 1 when it cannot tell,
# which is never taken for either.  It asks the endpoint the vault CLI
# uses; a vault from before kv v2 has no such endpoint, and every kv mount
# it has is a v1 one.  Nothing safe printed on stderr is kept.
__genesis_vault_kv_version() {
  safe curl GET "/sys/internal/ui/mounts/${1#/}" 2>/dev/null \
    | /usr/bin/perl -MJSON::PP -0777 -e '
        my $out = scalar(<STDIN>) // ""; $out =~ s/\A\s+//;
        my ($status) = $out =~ m{\AHTTP/\d+(?:\.\d+)?[ \t]+(\d{3})} or exit 1;
        if ($status == 404) {print "1\n"; exit 0}
        exit 1 unless $status == 200;
        my ($head, $body) = split(/\r?\n\r?\n/, $out, 2);
        $body //= "";
        if ($head =~ /^Transfer-Encoding:[ \t]*chunked[ \t]*\r?$/mi) {
          my $joined = "";
          while ($body =~ s/\A([0-9a-fA-F]+)[^\r\n]*\r?\n//) {
            my $size = hex($1); last unless $size;
            $joined .= substr($body, 0, $size, ""); $body =~ s/\A\r?\n//;
          }
          $body = $joined;
        }
        my $d = eval {JSON::PP->new->decode($body)};
        my $m = ref($d) eq "HASH" && ref($d->{data}) eq "HASH" ? $d->{data} : undef;
        exit 1 unless $m && defined($m->{path}) && ($m->{type} // "") =~ /\A(?:kv|generic)\z/;
        my $o = ref($m->{options}) eq "HASH" ? $m->{options} : {};
        print((($o->{version} // "1") eq "2" ? 2 : 1), "\n");'
}
export -f __genesis_vault_kv_version

# __genesis_vault_version SECRET - the newest version of a kv v2 secret.
# Returns 1, printing nothing, when safe cannot list the versions or lists
# none, so a failed lookup is never read as an unversioned secret.
__genesis_vault_version() {
  local __out
  __out="$(safe versions "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$__out" \
    | sed -e $'s/\x1b\\[[0-9;]*m//g' \
    | awk '$1 ~ /^[0-9]+$/ && $1+0 > v+0 {v=$1} END {if (v+0 > 0) print v; else exit 1}'
}
export -f __genesis_vault_version

# __genesis_safe_read ARGS... - safe get, with what safe says on stderr
# dropped, since a failed read can quote the value it was reading.  What
# safe printed is passed on only when the move can carry it exactly: a
# value with a NUL byte, which no shell value or command argument can
# hold, ends it with 90, and one that is not UTF-8, which CredHub cannot
# store as it is, with 91.  Otherwise it ends with safe's exit status.
__genesis_safe_read() {
  local -a __st
  safe get "$@" 2>/dev/null | /usr/bin/perl -MEncode -0777 -e '
    my $v = scalar(<STDIN>) // "";
    exit 90 if $v =~ /\0/;
    my $copy = $v;
    exit 91 unless eval {Encode::decode("UTF-8", $copy, Encode::FB_CROAK); 1};
    print $v;'
  __st=("${PIPESTATUS[@]}")
  [[ ${__st[0]} -eq 0 ]] || return "${__st[0]}"
  return "${__st[1]}"
}
export -f __genesis_safe_read

# __genesis_credhub_value NAME [versions] - print the value CredHub holds
# under NAME exactly, and a newline.  Ends with 0 when it holds one, 1 when
# CredHub says NAME does not exist, 3 when NAME holds something the move
# cannot compare exactly, such as a credential of another type or a value
# with a NUL byte, and 2 when it cannot tell.  With "versions", it asks
# for the newest two versions, prints the newest, and ends with 4 when
# there are two.  What credhub says on stderr is only matched, to tell a
# missing name apart, and never printed.
__genesis_credhub_value() {
  /usr/bin/perl -MIPC::Open3 -MSymbol=gensym -MJSON::PP -e '
    my ($name, $versions) = @ARGV;
    my @cmd = ("credhub", "get", "--name=$name", "--output-json");
    push @cmd, "--versions=2" if $versions;
    my ($in, $out, $err) = (undef, undef, gensym);
    my $pid = eval {open3($in, $out, $err, @cmd)} or exit 2;
    close($in);
    my $json = do {local $/; <$out>} // "";
    my $said = do {local $/; <$err>} // "";
    waitpid($pid, 0);
    exit(($said =~ /does not exist/i) ? 1 : 2) if $?;
    my $d = eval {JSON::PP->new->utf8->decode($json)};
    my @v = (ref($d) eq "HASH" && ref($d->{versions}) eq "ARRAY") ? @{$d->{versions}} : ($d);
    exit 2 unless @v && ref($v[0]) eq "HASH";
    my $v = $v[0];
    exit 3 unless ($v->{type} // "value") eq "value"
      && defined($v->{value}) && !ref($v->{value}) && $v->{value} !~ /\0/;
    binmode STDOUT, ":utf8"; print $v->{value}, "\n";
    exit(@v > 1 ? 4 : 0);' "$@"
}
export -f __genesis_credhub_value

move_secrets_to_credhub() {
  # The value passes through this function, so it is never traced, even
  # when the operator has asked for the hook's xtrace, and no message
  # below quotes it or anything safe or credhub printed.
  local value check src="$1" dst="$2" rc __xtrace='' secret key='' kv='' version='' now from keys kept='' why=''
  local name="/$GENESIS_CREDHUB_ROOT/$dst" held='' refused='' readback=versions
  { [[ $- == *x* ]] && __xtrace=1 && set +x; } 2>/dev/null
  secret="${GENESIS_SECRETS_BASE}${src%%:*}"
  [[ "$src" == *:* ]] && key=":${src#*:}"

  # A CredHub value is one string, and a whole vault record is a map of
  # keys, so copying one would change its shape.
  if [[ -z $key ]] ; then
    [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} Secret #C{$1} names no key, and a CredHub value holds one key's value, so nothing was written to CredHub or removed from vault.  Name the key to move, as in #C{$1:KEY}."
  fi

  # On a kv v2 mount, the newest version is read by its number, so the
  # copy, the checks, and the delete are all about that one version.  A
  # mount that cannot be identified, or versions that cannot be listed,
  # leave the vault value where it is, since nothing could then limit a
  # delete to the value that was copied.
  if kv="$(__genesis_vault_kv_version "$secret")" ; then
    if [[ $kv == 2 ]] ; then
      version="$(__genesis_vault_version "$secret")" \
        || kept="Genesis could not list the versions of #C{$secret} in vault, so it could not limit a delete to the version it copied"
    else
      kept="its vault mount is kv v1, which keeps no versions, so a delete could not be limited to the value that was copied, and a value written during the move would be lost"
    fi
  else
    kv=''
    kept="Genesis could not tell whether its vault mount keeps versions, so it could not limit a delete to the value it copied"
  fi
  from="$secret${version:+^$version}$key"
  __genesis_exact_value value __genesis_safe_read "$from" && rc=0 || rc=$?
  if [[ $rc -eq 90 || $rc -eq 91 ]] ; then
    value=''; [[ -n $__xtrace ]] && set -x
    [[ $rc -eq 90 ]] \
      && why="it holds a NUL byte, which no shell value or command argument can carry" \
      || why="it is not valid UTF-8, which CredHub cannot store as it is"
    bail "#R{[ERROR]} Secret #C{$1} cannot be moved to CredHub exactly, because $why, so nothing was written to CredHub or removed from vault."
  elif [[ $rc -gt 0 ]] ; then
    [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} Failed to read secret #C{$1} from vault: safe exited $rc"
  fi

  # The CredHub CLI has no write that refuses to replace a value, so what
  # CredHub holds is checked right before the write.  The same value is
  # a retry, and is not written again; any other is refused, since the
  # live credential would change before the move is known to be safe.
  check=''
  __genesis_exact_value check __genesis_credhub_value "$name" && rc=0 || rc=$?
  if [[ $rc -eq 0 && "$check" == "$value" ]] ; then
    held=1; readback=''
  elif [[ $rc -eq 0 || $rc -eq 3 ]] ; then
    refused="CredHub already holds a different credential under #C{$2}, so nothing was written to CredHub or removed from vault.  Decide which of the two is right, and remove the other, before running this again."
  elif [[ $rc -ne 1 ]] ; then
    refused="Genesis could not tell whether CredHub already holds a credential under #C{$2} (credhub read exited $rc), so nothing was written to CredHub or removed from vault."
  fi
  check=''
  if [[ -n $refused ]] ; then
    value=''; [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} Secret #C{$1} was not moved: $refused"
  fi
  if [[ -z $held ]] ; then
    # The value is attached to its option, so one that starts with a
    # hyphen is not taken for another option.
    credhub set --name="$name" --type=value --value="$value" >/dev/null 2>&1 && rc=0 || rc=$?
    if [[ $rc -gt 0 ]] ; then
      value=''; [[ -n $__xtrace ]] && set -x
      # What credhub printed can echo the request, so only its exit status
      # is reported.
      bail "#R{[ERROR]} Failed to store secret #C{$1} under credhub path #C{$2}: credhub exited $rc"
    fi
  fi

  # Nothing is deleted until CredHub is shown to hold the very same bytes,
  # and vault is shown to still hold what was copied.  After a write,
  # CredHub must hold that one version, or something else wrote the name
  # between the check and the write, or after it.
  check=''
  __genesis_exact_value check __genesis_credhub_value "$name" $readback && rc=0 || rc=$?
  if [[ $rc -eq 4 ]] ; then
    value=''; check=''; [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} CredHub holds more than one version under #C{$2}, so something else wrote it while secret #C{$1} was being moved, and the vault secret was left in place.  Check which value CredHub should hold before running this again."
  fi
  if [[ $rc -gt 0 || "$check" != "$value" ]] ; then
    value=''; check=''; [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} The value CredHub holds under #C{$2} does not match secret #C{$1} " \
         "(credhub read exited $rc), so the vault secret was left in place."
  fi
  if [[ -n $version ]] ; then
    now="$(__genesis_vault_version "$secret")" || now=''
  else
    now=''
  fi
  check=''
  __genesis_exact_value check __genesis_safe_read "$secret$key" && rc=0 || rc=$?
  if [[ $rc -gt 0 || "$now" != "$version" || "$check" != "$value" ]] ; then
    value=''; check=''; [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} Secret #C{$1} changed in vault while it was being copied to CredHub " \
         "(or could not be read again), so it was left in place; run this again to copy " \
         "its current value."
  fi
  value=''; check=''

  # Only a delete that names the copied version is safe: a value written
  # after the last read is a newer version, and survives it.  safe can
  # remove one key only by writing the others back with no check-and-set,
  # and its check-and-set request would carry the other keys' values on
  # the command line, so a version holding other keys is left whole.
  if [[ -z $kept && -n $key ]] ; then
    keys="$(safe get --keys "$secret^$version" 2>/dev/null)" && rc=0 || rc=$?
    if [[ $rc -gt 0 ]] ; then
      kept="Genesis could not list the keys of version $version of #C{$secret}, so it could not tell whether a delete would take other keys with it"
    elif [[ "$keys" != "${key#:}" ]] ; then
      kept="version $version of #C{$secret} holds other keys too, and vault offers no way to remove one key that a concurrent write could not race"
    fi
  fi
  if [[ -n $kept ]] ; then
    [[ -n $__xtrace ]] && set -x
    genesis_log @warning "Copied secret #C{$1} to CredHub under #C{$2}, and left the vault copy in place: $kept.  Remove it from vault once nothing else writes it." >&2
    return 0
  fi

  safe rm "$secret^$version" >/dev/null 2>&1 && rc=0 || rc=$?
  if [[ $rc -gt 0 ]] ; then
    [[ -n $__xtrace ]] && set -x
    bail "#R{[ERROR]} Copied secret #C{$1} to CredHub, but failed to remove version $version of it from vault: safe exited $rc"
  fi
  now="$(__genesis_vault_version "$secret")" || now=''
  [[ -n $__xtrace ]] && set -x
  if [[ -z $now ]] ; then
    genesis_log @warning "Copied secret #C{$1} to CredHub under #C{$2} and removed version $version of it from vault, but could not list its versions afterwards to check that no newer one was written meanwhile." >&2
  elif [[ $now -gt $version ]] ; then
    bail "#R{[ERROR]} Secret #C{$1} was written again in vault while it was being moved: CredHub holds version $version, which was removed from vault, and the newer version $now was kept.  Run this again to copy the newer value."
  fi
  return 0
}
export -f move_secrets_to_credhub

version_check() {
  local min_version
  min_version="${1:?"${FUNCNAME[0]} called without specifying minimum version"}"
  if ! [[ "$GENESIS_VERSION" =~ -dev$ ]] && ! new_enough "$GENESIS_VERSION" "$min_version" ; then
    describe >&2 "" "#R{[ERROR]} Genesis v$min_version is required by $GENESIS_KIT_HOOK.  Please upgrade before continuing" ""
    return 1
  fi
  return 0
}
export -f version_check

# Support for extended addon hook scripts
if [[ "$GENESIS_KIT_HOOK" == "addon" ]] ; then
	print_addon_descriptions() {

		local label short msg
		describe "The following addons are defined for the #C{$GENESIS_KIT_ID} kit:"
		while [[ "$#" -gt 0 ]]; do
			label="$(echo "$1" | sed -e 's/\([^~]*\).*/\1/')"
			short="$(echo "$1" | sed -e 's/\([^~]*\)\(~\(.*\)\)\{0,1\}/\3/')"
			[[ -n "$short" ]] && short="|$short"
			describe "" "  #Gu{$label$short}" "$(echo "$2" | sed -e 's/^/    /')"
			shift 2;
		done
		(
			shopt -s nullglob

			for addon in hooks/addon-*; do
				[[ -f "$addon.pm" && -z ${GENESIS_NO_MODULE_HOOKS:-''} ]] && continue # prefer the perl module version
				[[ -x "$addon" ]] || chmod +x "$addon"
				if [[ $addon =~ \.pm$ && -z ${GENESIS_NO_MODULE_HOOKS:-''} ]] ; then
					module="$(grep '^package ' "$addon" | sed -e 's/^package \([^ ]*\).*/\1/;q')"
					msg="$(perl -I $GENESIS_LIB -MGenesis::Term -e "require '$(pwd)/$addon'; print wrap($module->cmd_details, terminal_width, '', 4);")" || continue
				else
					msg="$($addon help)" || continue
					msg="$(echo "$msg" | sed -e 's/^/    /')"
				fi
				label="$(echo "$addon" | sed -e 's/.*\/addon-\([^~\.]*\).*/\1/')"
				short="$(echo "$addon" | sed -e 's/.*\/addon-\([^~\.]*\)\(~\([^\.]*\)\)\{0,1\}.*/\3/')"
				[[ -n "$short" ]] && short="|$short"
				describe "" "  #Gu{$label$short}" "$msg"
			done
		)
		echo ""
	}
	export -f print_addon_descriptions

	run_extended_addon() {
		addon=
		if [[ -f "hooks/addon-$GENESIS_ADDON_SCRIPT" ]] ; then
			addon="hooks/addon-$GENESIS_ADDON_SCRIPT"
		else
			addon="$(compgen -G "hooks/addon-$GENESIS_ADDON_SCRIPT"'~*')"
			if [[ -z "$addon" ]] ; then
				addon="$(compgen -G 'hooks/addon-*~'"$GENESIS_ADDON_SCRIPT")"
				if [[ -n "$addon" ]] ; then
					label="$(echo "$addon" | sed -e 's/.*\/addon-\([^~]*\).*/\1/')"
					describe >&2 "[1ARunning #G{$label ($GENESIS_ADDON_SCRIPT)} addon for #C{$GENESIS_ENVIRONMENT} #M{$GENESIS_KIT_NAME} deployment"
				fi
			fi
		fi

		if [[ -n "$addon" && -f "$addon" ]] ; then
			[[ -x "$addon" ]] || chmod +x "$addon"
			"$addon" run "$@"
			exit $?
		else
			echo "Unrecognized $(titleize $GENESIS_KIT_NAME) Genesis Kit addon."
			list
			exit 1
		fi
	}
	export -f run_extended_addon
fi
