#!/usr/bin/env bash

set -o errexit -o errtrace -o noclobber -o nounset -o pipefail

trap 'e=$?; if [ "$e" -ne "0" ]; then printf "LINE %s: exit %s <- %s%s\\n" "$BASH_LINENO" "$e" "${BASH_COMMAND}" "$(printf " <- %s" "${FUNCNAME[@]:-main}")" 1>&2; fi' EXIT


PROGNAME="${0##*/}"

log_debug() {
	(>&2 printf '%sDEBUG%s: %s\n' "$(tput setaf 7)" "$(tput sgr0)" "$@")
}

log_info() {
	(>&2 printf '%sINFO%s: %s\n' "$(tput setaf 2)" "$(tput sgr0)" "$@")
}

log_warn() {
	(>&2 printf '%sWARNING%s: %s\n' "$(tput setaf 3)" "$(tput sgr0)" "$@")
}

log_error() {
	(>&2 printf '%sERROR%s: %s\n' "$(tput setaf 1)" "$(tput sgr0)" "$@")
}

get_context() {
	local line
	local subroutine
	local filename
	line="$1"
	subroutine='call'
	if [ "$#" -eq "2" ]; then
		filename="$2"
	elif [ "$#" -eq "3" ]; then
		subroutine="$2"
		filename="$3"
	else
		log_error 'incorrect number of arguments!'
		exit 1
	fi
	printf '%s%s on line %d of %s:%s\n' "$(tput setaf 1)" "$subroutine" "$line" "$filename" "$(tput sgr0)"
	awk 'NR>L-4 && NR<L+4 { printf "%-5d%3s%s\n",NR,(NR==L?">>>":""),$0 }' L="$line" "$filename"
}

log_stack_trace() {
	local last_exit=$?
	local max_depth
	local depth
	if [ "$last_exit" -ne "0" ]; then
		depth=0
		max_depth="${1:-3}"
		while [ "$depth" -le "$max_depth" ] && caller "$depth" 1>/dev/null 2>&1 ; do
			log_error "$(get_context $(caller "$depth"))"
			depth+=1
		done
		log_error "$(printf '%s(%d) -> exit %d\n' $(caller 0 | awk '{ print $3,$1 }') "$last_exit")"
	fi
}

append_trap () {
	local trap_cmd
	local trap_sig
	local old_trap_cmd

	trap_cmd="$1"
	trap_sig="$2"

	old_trap_cmd="$(trap -p "$trap_sig" | sed -E -e "s/^[^'\"]*['\"]//" -e "s/['\"][[:space:]]*${trap_sig}\$//")"
	if [[ -n "$old_trap_cmd" ]]; then
		trap_cmd="$old_trap_cmd; $trap_cmd"
	fi
	trap "$trap_cmd" "$trap_sig"
}

trap 'log_stack_trace' EXIT

get_script_dir() {
	## resolve the directory of the given script
	# example:
	# 	get_script_dir "${BASH_SOURCE[0]}"
	SOURCE="${1}"
	#SOURCE="${BASH_SOURCE[0]}"
	while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
		SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
		SOURCE="$(readlink "$SOURCE")"
		[[ $SOURCE != /* ]] && SOURCE="$SCRIPTDIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
	done
	SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
	printf '%s\n' "${SCRIPTDIR}"
}

contains_value() {
	local value
	value="$1"
	shift
	for arg in "$@"; do
		if [ "$value" == "$arg" ]; then
			return 0
		fi
	done
	return 1
}

main() {
	local OPTIND
	local OPTARG
	local func_name
	local usage
	local required_opts
	local additive_opts
	local min_positional_args
	local max_positional_args
	local provided_opts
	local missing_opts

	local verbosity
	local null_sep
	local repository
	local tree

	verbosity=()
	null_sep=""
	repository="$(pwd -P)"
	tree="HEAD"

	func_name="$PROGNAME"

	usage() {
		cat <<EOF | sed 's/^\t\t//' >&2
		NAME
			${func_name} -- CLI utility for listing the files in a local or remote git repository.

		SYNOPSIS
			${func_name} [-hvz] [-r <REPOSITORY>] [-t <TREE-ISH>] [<PATH>]...

		DESCRIPTION
			git-list-files is a CLI utility for listing the files in a local or remote git repository.

			The options are as follows:

			-h	print this help and exit

			-v	increase verbosity
				may be given more than once

			-z	separate files with NUL byte

			-r <REPOSITORY>
				repository URL or directory path (default: $(pwd -P))

			-t <TREE-ISH>
				git tree-ish for which to list the files (default: HEAD)


			[<PATH>] (optional) path patterns for which to list matching files
EOF
	}

	# options which must be given
	required_opts=()
	# options which may be given more than once
	additive_opts=("v")
	# minimum number of positional arguments allowed (ignored if empty)
	min_positional_args=""
	# maximum number of positional arguments allowed (ignored if empty)
	max_positional_args=""

	# tracks which options have been provided
	provided_opts=()
	while getopts 'hvzr:t:' opt; do
		if ! contains_value "$opt" "${additive_opts[@]:-}" && contains_value "$opt" "${provided_opts[@]:-}"; then
			log_error "option cannot be given more than once: $opt"
			usage
			exit 1
		fi

		case "$opt" in
			h)
				usage
				exit 0
				;;
			v)
				verbosity+=("y")
				;;
			z)
				null_sep="y"
				;;
			r)
				repository="$OPTARG"
				;;
			t)
				tree="$OPTARG"
				;;
			*)
				usage
				exit 1
				;;
		esac
		provided_opts+=("$opt")
	done
	shift $((OPTIND - 1))

	if [ -n "$min_positional_args" ] && [ "$#" -lt "$min_positional_args" ]; then
		log_error "at least ${min_positional_args} positional argument(s) needed but got only $#: $*"
		usage
		exit 1
	fi
	if [ -n "$max_positional_args" ] && [ "$#" -gt "$max_positional_args" ]; then
		log_error "up to ${max_positional_args} positional argument(s) allowed but got $#: $*"
		usage
		exit 1
	fi

	if [ "${#required_opts[@]}" -gt "0" ]; then
		missing_opts=()
		for opt in "${required_opts[@]}"; do
			if ! contains_value "$opt" "${provided_opts[@]:-}"; then
				missing_opts+=("${opt}")
			fi
		done
		if [ "${#missing_opts[@]}" -gt "0" ]; then
			log_error "missing required options: ${missing_opts[*]}"
			usage
			exit 1
		fi
	fi

	# log_debug "verbosity: ${verbosity[*]:-}"
	# log_debug "null_sep: ${null_sep:-}"
	# log_debug "repository: ${repository:-}"
	# log_debug "tree: ${tree:-}"
	# if [[ "$#" -gt "0" ]]; then
	# 	log_debug "positional args: $(printf '\n\t"%s"' "$@")"
	# else
	# 	log_debug 'no positional args given'
	# fi
}

main "$@"

