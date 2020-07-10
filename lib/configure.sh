#!/usr/bin/env bash
# (c) Konstantin Riege

configure::environment(){
	local funcname=${FUNCNAME[0]}
	_usage(){
		commander::printerr {COMMANDER[0]}<<- EOF
			$funcname usage:
			-i <insdir> | path to
			-c <conda>  | true/false activate
		EOF
		return 0
	}

	local OPTIND arg mandatory insdir activate_conda=true
	while getopts 'i:c:' arg; do
		case $arg in
			i)	((mandatory++)); insdir="$OPTARG";;
			c)	activate_conda="$OPTARG";;
			*)	_usage; return 1;;
		esac
	done
	[[ $mandatory -lt 1 ]] && _usage && return 1

	commander::print "setting up environment"

	shopt -s extglob
	shopt -s expand_aliases
	ulimit -n $(ulimit -Hn)

	JAVA_HOME=$(readlink -e $insdir/latest/java)
	[[ $JAVA_HOME ]] && export JAVA_HOME=$(dirname $JAVA_HOME)
	export MALLOC_ARENA_MAX=4
	
	export PATH=$(readlink -e $insdir/latest/* | xargs -echo | sed 's/ /:/g'):$PATH
	export PATH=$(readlink -e $insdir/latest/*/scripts | xargs -echo | sed 's/ /:/g'):$PATH

	$activate_conda && {
		source $insdir/conda/bin/activate py2 &> /dev/null || return 1
	}

	return 0
}

configure::instances_by_threads(){
	local funcname=${FUNCNAME[0]}
	_usage(){
		commander::printerr {COMMANDER[0]}<<- EOF
			$funcname usage:
			-i <instances> | number of all
			-t <threads>   | per instance targeted
			-T <threads>   | available
		EOF
		return 0
	}

	local OPTIND arg mandatory instances ithreads maxthreads
	while getopts 'i:t:T:m:' arg; do
		case $arg in
			i)	((mandatory++)); instances=$OPTARG;;
			t)	((mandatory++)); ithreads=$OPTARG;;
			T)	((mandatory++)); maxthreads=$OPTARG;;
			*)	_usage; return 1;;
		esac
	done
	[[ $mandatory -lt 3 ]] && _usage && return 1

	[[ $ithreads -gt $maxthreads ]] && ithreads=$maxthreads
	[[ $instances -gt $((maxthreads/ithreads)) ]] && instances=$((maxthreads/ithreads))
	ithreads=$((maxthreads/instances))

	echo "$instances $ithreads"
	return 0
}

configure::instances_by_memory(){
	local funcname=${FUNCNAME[0]}
	_usage(){
		commander::printerr {COMMANDER[0]}<<- EOF
			$funcname usage:
			-t <threads> | available
			-m <memory>  | per instance maximum
		EOF
		return 0
	}

	local OPTIND arg mandatory threads memory
	while getopts 'i:t:T:m:' arg; do
		case $arg in
			t)	((mandatory++)); threads=$OPTARG;;
			m)	((mandatory++)); memory=$OPTARG;;
			*)	_usage; return 1;;
		esac
	done
	[[ $mandatory -lt 2 ]] && _usage && return 1

	local maxmemory=$(grep -F -i memavailable /proc/meminfo | awk '{printf("%d",$2*0.9/1024)}')
	local instances=$((maxmemory/memory))
	[[ $instances -gt $threads ]] && instances=$threads
	local ithreads=$((threads/instances))

	echo "$instances $ithreads"
	return 0
}

configure::jvm(){
	local funcname=${FUNCNAME[0]}
	_usage(){
		commander::printerr {COMMANDER[0]}<<- EOF
			$funcname usage:
			-i <instances> | number of all
			-t <threads>   | per instance targeted
			-T <threads>   | available
			-m <memory>    | per instance maximum
		EOF
		return 0
	}

	local OPTIND arg mandatory instances ithreads=1 maxthreads memory=1
	while getopts 'i:t:T:m:' arg; do
		case $arg in
			i)	instances=$OPTARG;;
			t)	ithreads=$OPTARG;;
			T)	((mandatory++)); maxthreads=$OPTARG;;
			m)	memory=$OPTARG;;
			*)	_usage; return 1;;
		esac
	done
	[[ $mandatory -lt 1 ]] && _usage && return 1
	[[ ! $instances ]] && instances=$maxthreads

	local jmem jgct jcgct maxmemory=$(grep -F -i memavailable /proc/meminfo | awk '{printf("%d",$2*0.9/1024)}')
	local maxinstances=$((maxmemory/memory))
	[[ $maxinstances -gt $((maxthreads/ithreads)) ]] && maxinstances=$((maxthreads/ithreads))
	[[ $instances -gt $maxthreads ]] && instances=$maxthreads
	[[ $instances -gt $maxinstances ]] && instances=$maxinstances

	ithreads=$((maxthreads/instances))
	jmem=$((maxmemory/instances))
	[[ $memory -gt 1 ]] && [[ $jmem -gt $memory ]] && jmem=$memory
	jgct=$(((3+5*ithreads/8)/instances))
	[[ $jgct -eq 0 ]] && jgct=1
	jcgct=$((jgct/4))
	[[ $jcgct -eq 0 ]] && jcgct=1

	echo "$instances $ithreads $jmem $jgct $jcgct"
	return 0
}
