#!/usr/bin/env bash
# (c) Konstantin Riege

function helper::index(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-f <infile>  | path to. else stdin
			-o <outfile> | path to
		EOF
		return 1
	}

	local OPTIND arg f o
	while getopts 'f:o:' arg; do
		case $arg in
			f)	f="$OPTARG";;
			o)	o="$OPTARG"; mkdir -p "$(dirname "$o")";;
			*)	_usage;;
		esac
	done
	[[ ! $f && ! $o ]] && { _usage || return 0; }

	if [[ $f ]]; then
		if readlink -e "$f" | file -b --mime-type -f - | grep -qF 'gzip'; then
			if rapidgzip --version | sed -E 's/.+\s([0-9]+)\.([0-9]+)\.([0-9]+)$/\1.\2\t\2.\3/' | awk '$1>0.14 || $2>=14.3{exit 0}{exit 1}'; then
				# test if available index is okay
				# if [[ -e "${f%.*}.gzi" ]]; then
				# 	rapidgzip -qkcd -P 1 --import-index "${f%.*}.gzi" "$f" 2> /dev/null | head -1 | grep -q . && return 0 || true
				# fi
				rapidgzip -qf -P 1 --index-format gztool-with-lines --export-index "${f%.*}.gzi" "$f"
			else
				# test if available index is okay
				# if [[ -e "${f%.*}.rgzi" ]]; then
				# 	gztool -v 0 -l "$f" && rapidgzip -kcd -P 2 --import-index "${f%.*}.rgzi" "$f" 2> /dev/null | head -1 | grep -q . && return 0
				# fi
				cat "$f" | tee -i >(gztool -v 0 -f -i -x -C -I "${f%.*}.gzi") >(rapidgzip -f -P 2 --export-index "${f%.*}.rgzi") > /dev/null | cat
			fi
		else
			fftool.sh -i -f "$f"
		fi
	else
		local magic recordsize=1000
		read -n 2 magic
		# diff <(echo -n $magic | od -N 2 -t x1) <(echo | gzip -kc | od -N 2 -t x1) &> /dev/null # 0x1f8b
		if echo -n "$magic" | file -b --mime-type - | grep -qF 'gzip'; then
			if rapidgzip --version | sed -E 's/.+\s([0-9]+)\.([0-9]+)\.([0-9]+)$/\1.\2\t\2.\3/' | awk '$1>0.14 || $2>=14.3{exit 0}{exit 1}'; then
				# works from v0.14.3+
				cat <(echo -n "$magic") - | tee -i >(rapidgzip -qf -P 1 --index-format gztool-with-lines --export-index "${f%.*}.gzi") > "$o" | cat
			else
				cat <(echo -n "$magic") - | tee -i >(gztool -v 0 -f -i -x -C -I "${o%.*}.gzi") >(rapidgzip -f -P 2 --export-index "${o%.*}.rgzi") > "$o" | cat
			fi
		else
			cat <(echo -n "$magic") - | fftool.sh -i -o "$o"
		fi
	fi

	return 0
}

function helper::pgzip(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-f <infile>  | path to. else stdin
			-o <outfile> | path to
			-t <threads> | number of
			-p           | use slower pigz instead of bgzip to lower disk footprint by 5%
		EOF
		return 1
	}

	local OPTIND arg threads=1 f o tool="bgzip"
	while getopts 'f:t:o:p' arg; do
		case $arg in
			f)	f="$OPTARG";;
			o)	o="$OPTARG"; mkdir -p "$(dirname "$o")";;
			t)	threads=$OPTARG;;
			p)	tool="pigz";;
			*)	_usage;;
		esac
	done
	[[ ! $f && ! $o ]] && { _usage || return 0; }
	[[ ! $f ]] && f=/dev/stdin
	[[ ! $o ]] && o="$f.gz"

	if [[ $tool == "bgzip" && -x "$(command -v bgzip)" ]]; then
		# compression level changed from v1.16 to ~match gzip size at cost of throughput (still being faster than pigz)
		tool+=" -l $(bgzip --version | head -1 | awk '$NF>1.15{print 5; exit}{print 6}') -@"
	else
		tool="pigz -p"
	fi

	$tool $threads -k -c "$f" | helper::index -o "$o"

	return 0
}

function helper::lapply(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-l <lines>   | that make a record. default: 1
			-d <records> | per thread. default: 5000
			-t <threads> | number of
			-o <odir>    | path to. default: TMPDIR
			-f           | create seekable temporary files. file name is \$FILE
			-r           | round robin mode i.e. distribute all input evenly across -t jobs. default: initiate new process per chunk
			-c <cmd>     | and parameters - needs to be last! job id is \$JOB_ID

			example 1:
			cat file | ${FUNCNAME[-2]} -t 10 -c cat

			example 2:
			fun(){
				cat > $JOB_ID.out
			}
			export -f fun
			cat file | ${FUNCNAME[-2]} -t 10 -c fun

			example 3:
			cat file | ${FUNCNAME[-2]} -f -t 10 -c "cat \$FILE > \$FILE.out"

			example 4:
			cat file | ${FUNCNAME[-2]} -f -t 10 -c 'cat > $FILE.out'
		EOF
		return 1
	}

	local OPTIND arg mandatory threads=1 l=1 d=5000 params="" odir="${TMPDIR:-/tmp}"
	while getopts 'l:d:t:o:rfc' arg; do
		case $arg in
			l)	l=$OPTARG;;
			d)	d=$OPTARG;;
			t)	threads=$OPTARG;;
			o)	odir="$OPTARG"; mkdir -p "$odir";;
			r)	params+=" --round-robin";;
			f)	params+=" --cat";;
			c)	((++mandatory)); shift $((OPTIND-1)); break;;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 1 ]] && _usage

	# attention: this solution requires escape sequences within single quotes. (example: cat file | papply -t 10 -c 'cat \> \$JOB_ID.out')
	# function helper::_papply(){
	# 	FILE="${1:-/dev/stdin}"
	# 	JOB_ID="$2" # or $PARALLEL_SEQ
	# 	shift 2
	# 	if [[ "$FILE" == "/dev/stdin" ]]; then
	# 		IFS=$'\n'
	# 		read -r l < "$FILE" || exit 0
	# 		cat <(echo "$l") - | eval "$*"
	# 	else
	# 		[[ -s "$FILE" ]] || exit 0
	# 		eval "$*"
	# 	fi
	# }
	# export -f helper::_papply
	# parallel --tmpdir "$odir" --termseq INT,1000,TERM,0 --halt now,fail=1 --line-buffer --pipe -L $l -N $((5000/l)) $params -P $threads helper::_papply "{}" "{#}" "$@"

	parallel --tmpdir "$odir" --termseq INT,1000,TERM,0 --halt now,fail=1 --line-buffer --pipe -L $l -N $((d/l)) $params -P $threads "JOB_ID={#}; FILENO={#}; FILE=\"{}\"; if [[ -s \"\$FILE\" ]]; then $*; else read -r l || exit 0; cat <(echo \"\$l\") - | $*; fi"

	return 0
}

function helper::capply(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-i <instances> | number of
			-t <threads>   | number of decompressison threads per instance (default: 1)
			-f <infile>    | path to
			-m <modulo>    | chunk size modulo zero. default: 4 (to match fastq file records)
			-l             | switch from full output buffering and ordered output to immediate line bufferd output
			-c <cmd>       | and parameters - needs to be last! job id is \$JOB_ID

			example 1:
			${FUNCNAME[-2]} -i 10 -f file[.gz] -c cat

			example 2:
			fun(){
				cat > $JOB_ID.out
			}
			export -f fun
			${FUNCNAME[-2]} -i 10 -f file[.gz] -c fun

			example 3:
			${FUNCNAME[-2]} -i 10 -f file[.gz] -c "cat > \\\$JOB_ID.out"

			example 4:
			${FUNCNAME[-2]} -i 10 -f file[.gz] -c 'cat > \$JOB_ID.out'
		EOF
		return 1
	}

	local OPTIND arg mandatory instances=1 m=4 f tdir="${TMPDIR:-/tmp}" params="--keep-order" threads=1
	while getopts 'i:f:t:m:lc' arg; do
		case $arg in
			i)	instances=$OPTARG;;
			t)	threads=$OPTARG;;
			m)	m=$OPTARG;;
			l)	params="--line-buffer";;
			f)	((++mandatory)); f="$OPTARG";;
			c)	((++mandatory)); shift $((OPTIND-1)); break;;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 2 ]] && _usage

	local l c
	if readlink -e "$f" | file -b --mime-type -f - | grep -qF 'gzip'; then
		if rapidgzip --version | sed -E 's/.+\s([0-9]+)\.([0-9]+)\.([0-9]+)$/\1.\2\t\2.\3/' | awk '$1>0.14 || $2>=14.3{exit 0}{exit 1}'; then
			l=$(rapidgzip -P 1 -q --count-lines --import-index "${f%.*}.gzi" "$f")
		else
			l=$(gztool -l "$f" |& sed -nE 's/.*\s+lines\s+:\s+([0-9]+).*/\1/p')
		fi
	else
		l=$(tail -1 "${f%.*}.ffi" | cut -f 1)
	fi
	c=$((l%instances==0 ? l/instances : l/instances+1))
	c=$((c%m == 0 ? c : c+m-c%m))

	# attention: this solution requires escape sequences within single quotes. (example: papply_gzip -i 10 -f file.gz -c 'cat \> \$JOB_ID.out')
	# function helper::_papply_gzip(){
	# 	JOB_ID="$1"
	# 	shift
	# 	eval "$*"
	# }
	# export -f helper::_papply_gzip
	# for i in $(seq 0 $((instances-1))); do
	# 	echo "gztool -v 0 -L $((i*c+1)) -R $c '$f' |"
	# done | parallel --tmpdir "$tdir" --termseq INT,1000,TERM,0 --halt now,fail=1 $params -P $instances helper::_papply_gzip "{#}" "{}" "$@"

	# for i in $(seq 0 $((instances-1))); do
	# 	echo "gztool -v 0 -L $((i*c+1)) -R $c '$f'"
	# done | parallel --tmpdir "$tdir" --termseq INT,1000,TERM,0 --halt now,fail=1 --keep-order -P $instances '{= $ENV{JOB_ID}=seq() =}' :::: - ::: " | $*"
	# for i in $(seq 0 $((instances-1))); do
	# 	echo "FILENO=\$PARALLEL_SEQ; JOB_ID=\$PARALLEL_SEQ; gztool -v 0 -L $((i*c+1)) -R $c '$f'"
	# done | parallel --tmpdir "$tdir" --termseq INT,1000,TERM,0 --halt now,fail=1 --keep-order -P $instances {} :::: - ::: " | $*"
	# v0.14+:
	# for i in $(seq 0 $((instances-1))); do
	# 	echo "FILENO=\$PARALLEL_SEQ; JOB_ID=\$PARALLEL_SEQ; rapidgzip -P 1 -kcd --ranges ${c}L@$((i*c))L --import-index '${f%.*}.gzi' '$f'"
	# done | parallel --tmpdir "$tdir" --termseq INT,1000,TERM,0 --halt now,fail=1 --keep-order -P $instances {} :::: - ::: " | $*"
	declare -a catcmd
	for i in $(seq 0 $((instances-1))); do
		helper::makecatcmd -v catcmd -t $threads -r "${c}L@$((i*c))L" -f "$f"
		echo "FILENO=\$PARALLEL_SEQ; JOB_ID=\$PARALLEL_SEQ; ${catcmd[*]} '$f'"
	done | parallel --tmpdir "$tdir" --termseq INT,1000,TERM,0 --halt now,fail=1 $params -P $instances {} :::: - ::: " | $*"

	return 0
}

function helper::sort(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-f <infile>    | path to. else stdin
			-o <outfile>   | path to. else stdout
			-t <threads>   | number of
			-M <maxmemory> | amount of
		EOF
		return 1
	}

	local OPTIND threads=1 f=/dev/stdin o=/dev/stdout maxmemory tmpdir="${TMPDIR:-/tmp}"
	declare -a args=();
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-M)	maxmemory=$2; shift 2;;
			-f)	f=$2; shift 2;;
			-o)	o=$2; shift 2; mkdir -p "$(dirname "$o")";;
			-t)	threads=$2; shift 2;;
			*)	args+=("$1"); shift;;
		esac
	done

	local instances tdir="$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.sort)"
	read -r instances maxmemory < <(configure::memory_by_instances -i 1 -M "$maxmemory")
	LC_ALL=C sort --parallel="$threads" -S "${maxmemory}M" -T "$tdir" "${args[@]}" "$f" > "$o" | cat
	# fun(){ echo foo > /dev/stdout; }; echo bar > tmp; fun >> tmp. cat tmp # foo
	# fun(){ echo foo > /dev/stdout | cat; }; echo bar > tmp; fun >> tmp. cat tmp # bar foo

	return 0
}

function helper::vcfsort(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-f <infile>    | path to. else stdin
			-o <outfile>   | path to. else stdout
			-t <threads>   | number of
			-M <maxmemory> | amount of
			-z             | compress output
		EOF
		return 1
	}

	local OPTIND threads=1 f=/dev/stdin o=/dev/stdout maxmemory tmpdir="${TMPDIR:-/tmp}" zip=false
	while getopts 'f:t:o:M:z' arg; do
		case $arg in
			f) f="$OPTARG";;
			o) o="$OPTARG"; mkdir -p "$(dirname "$o")";;
			t) threads=$OPTARG;;
			M) maxmemory=$OPTARG;;
			z) zip=true;;
			*) _usage;;
		esac
	done

	local instances maxmemory tdir="$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.vcfsort)"
	read -r instances maxmemory < <(configure::memory_by_instances -i 1 -M "$maxmemory")
	if $zip; then
		bcftools view "$f" 2> >(sed -u '/vcf_parse/{q 1}' >&2) | awk -F'\t' -v t=$threads -v m=$maxmemory -v p="$tdir" -v OFS='\t' '/^#/{if(match($0,/^##contig=<ID=(\S+),length.*/,a)){i++; c[a[1]]=i}; print; next} {$1=c[$1]; print | "LC_ALL=C sort -k1,1n -k2,2n -k4,4 -k5,5 --parallel="t" -S "m"M -T \""p"\""}' | awk -F'\t' -v OFS='\t' '/^#/{if(match($0,/^##contig=<ID=(\S+),length.*/,a)){i++; c[i]=a[1]}; print; next} {$1=c[$1]; print}' | bgzip -k -c -@ $threads > "$o" | cat
		tabix -f -p vcf "$o"
	else
		bcftools view "$f" 2> >(sed -u '/vcf_parse/{q 1}' >&2) | awk -F'\t' -v t=$threads -v m=$maxmemory -v p="$tdir" -v OFS='\t' '/^#/{if(match($0,/^##contig=<ID=(\S+),length.*/,a)){i++; c[a[1]]=i}; print; next} {$1=c[$1]; print | "LC_ALL=C sort -k1,1n -k2,2n -k4,4 -k5,5 --parallel="t" -S "m"M -T \""p"\""}' | awk -F'\t' -v OFS='\t' '/^#/{if(match($0,/.*#contig=<ID=(\S+),length.*/,a)){i++; c[i]=a[1]}; print; next} {$1=c[$1]; print}' > "$o" | cat
	fi

	return 0
}

function helper::makecatcmd(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-c <var>     | obsolete synonym for -v
			-v <var>     | variable
			-f <file>    | path to
			-t <threads> | number of (default: 4)
			-r <range>   | with format <m|inf>L@<n>L meaning m or infinity lines after n lines (gzip only)
			-l           | legacy mode without index
			example:
			${FUNCNAME[-2]} -v cmd -f [txt|bz2|gz]
		EOF
		return 1
	}

	local OPTIND arg mandatory f v legacy=false threads=4 range
	while getopts 'f:c:v:t:r:l' arg; do
		case $arg in
			c)	v=$OPTARG;;
			v)	v=$OPTARG;;
			t)	threads=$OPTARG;;
			r)	range="$OPTARG";;
			l)	legacy=true;;
			f)	((++mandatory)); f="$OPTARG";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 1 ]] && _usage

	if [[ $v ]]; then
		declare -n _makecatcmd=$v
	else
		local _makecatcmd
	fi

	### SSD
	# pigz p=1  : 400MB/s
	# pigz p=2  : 500MB/s
	# bgzip @=1 : 400MB/s
	# bgzip @=2 : 400MB/s
	# rapidgzip P=4 : index or bgzip : 1300MB/s | no index : 800MB/s  <-
	# rapidgzip P=8 : index or bgzip : 1500MB/s | no index : 1100MB/s
	### NFS
	# pigz p=1  : 250MB/s
	# pigz p=2  : 200MB/s
	# bgzip @=1 : 550MB/s
	# bgzip @=4 : 2500MB/s
	# bgzip @=8 : 3800MB/s
	# rapidgzip P=4               : index or bgzip : 2500MB/s | no index : 550MB/s (P=1!)
	# rapidgzip P=8               : index or bgzip : 3800MB/s | no index : 550MB/s (P=1!)
	# rapidgzip P=12              : index or bgzip : 5500MB/s | no index : 550MB/s (P=1!)
	# rapidgzip (sequential) P=4  : index or bgzip : 2500MB/s | no index : 2200MB/s       <-
	# rapidgzip (sequential) P=8  : index or bgzip : 3800MB/s | no index : 3500MB/s
	# rapidgzip (sequential) P=12 : index or bgzip : 5500MB/s | no index : 5000MB/s

	# _makecatcmd=$({ readlink -e "$f" | file -b --mime-type -f - | grep -oF -e 'gzip' -e 'bzip2' || echo cat; } | sed '/cat/!{s/gzip/pigz -p 2/; s/$/ -kcd/}')
	# _makecatcmd=$({ readlink -e "$f" | file -b --mime-type -f - | grep -oF -e 'gzip' -e 'bzip2' || echo cat; } | sed '/cat/!{s/gzip/bgzip -@ 1/; s/$/ -kcd/}')
	# _makecatcmd=$({ readlink -e "$f" | file -b --mime-type -f - | grep -oF -e 'gzip' -e 'bzip2' || echo cat; } | sed '/cat/!{s/gzip/rapidgzip -P 4/; s/$/ -kcd/}')

	case "$(readlink -e "$f" | file -b --mime-type -f - | grep -oF -e 'gzip' -e 'bzip2' || echo cat)" in
		gzip)
			if rapidgzip --version | sed -E 's/.+\s([0-9]+)\.([0-9]+)\.([0-9]+)$/\1.\2\t\2.\3/' | awk '$1>0.14 || $2>=14.3{exit 0}{exit 1}'; then
				# from v0.14.1+ rapidgzip supports gztool indices and likewise to its default indices gives all the benefits (ie. ISA-L based decoding)
				# -> no rgzi indices necesseray anymore
				if [[ $range ]]; then
					_makecatcmd=("rapidgzip" "-qkcd" "-P" "$threads" "--import-index" "${f%.*}.gzi" "--ranges" "$range")
				elif ! $legacy && [[ -e "${f%.*}.gzi" ]]; then
					_makecatcmd=("rapidgzip" "-qkcd" "-P" "$threads" "--import-index")
					[[ $v ]] && _makecatcmd+=("'${f%.*}.gzi'") || _makecatcmd+=("${f%.*}.gzi")
				else
					local rota=$(
						rota="$(df --output=source "$(readlink -e "$f")" | tail -1)"
						lsblk -n -o ROTA "$rota" 2> /dev/null || {
							rota="$(realpath "/dev/disk/by-label/$(rev <<< "$rota" | xargs basename | rev)")"
							lsblk -n -o ROTA "$rota" 2> /dev/null || echo 1
						}
					)
					if [[ $rota -gt 0 ]]; then
						# hdd/nfs/overlay/...
						_makecatcmd=("rapidgzip" "-qkcd" "-P" "$threads" "--io-read-method" "sequential")
					else
						# bgzip || gzip
						# params="-P $(gzip -l "$f" | tail -1 | awk '$1>0 && $2==0{print 4; exit}{print 8}')"
						_makecatcmd=("rapidgzip" "-qkcd" "-P" "$threads")
					fi
				fi
			else
				# wo avoid non mutable "[Warning] The index only has an effect for parallel decoding"
				[[ $threads -eq 1 ]] && threads=2
				if [[ $range ]]; then
					local l r
					read -r r l < <(sed -E 's/L@?/ /g' <<< "$range")
					_makecatcmd=("gztool" "-v" "0" "-L" "$((l+1))" "-R" "$r")
				elif ! $legacy && [[ -e "${f%.*}.rgzi" ]]; then
					_makecatcmd=("rapidgzip" "-kcd" "-P" "$threads" "--import-index")
					[[ $v ]] && _makecatcmd+=("'${f%.*}.rgzi'") || _makecatcmd+=("${f%.*}.rgzi")
				else
					local rota=$(
						rota="$(df --output=source "$(readlink -e "$f")" | tail -1)"
						lsblk -n -o ROTA "$rota" 2> /dev/null || {
							rota="$(realpath "/dev/disk/by-label/$(rev <<< "$rota" | xargs basename | rev)")"
							lsblk -n -o ROTA "$rota" 2> /dev/null || echo 1
						}
					)
					if [[ $rota -gt 0 ]]; then
						# hdd/nfs/overlay/...
						_makecatcmd=("rapidgzip" "-kcd" "-P" "$threads" "--io-read-method" "sequential")
					else
						# bgzip || gzip
						# params="-P $(gzip -l "$f" | tail -1 | awk '$1>0 && $2==0{print 4; exit}{print 8}')"
						_makecatcmd=("rapidgzip" "-kcd" "-P" "$threads")
					fi
				fi
			fi
		;;
		bzip2)
			# bzip2 replaced by faster indexed_bzip2
			_makecatcmd=("ibzip2" "-qkcd" "-P" "$threads")
			;;
		*)
			if [[ $range ]]; then
				_makecatcmd=("fftool.sh" "-r" "$range" "-f")
			else
				_makecatcmd=("cat")
			fi
	esac

	[[ $v ]] || "${_makecatcmd[@]}" "$f"
	return 0
}

function helper::cat(){
	helper::makecatcmd "$@"
}

function helper::basename(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-f <file> | path to
			-o <var>  | basename
			-e <var>  | extension

			example:
			${FUNCNAME[-2]} -f foo.txt.gz -o base -e ex
		EOF
		return 1
	}

	local OPTIND arg f mandatory
	declare -n _basename _basenamex
	while getopts 'f:o:e:' arg; do
		case $arg in
			f) ((++mandatory)); f="$OPTARG";;
			o) ((++mandatory)); _basename=$OPTARG;;
			e) ((++mandatory)); _basenamex=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 3 ]] && _usage

	if readlink -e "$f" | file -b --mime-type -f - | grep -qF -e 'gzip' -e 'bzip2'; then
		_basename="$(basename "$f" | rev | cut -d '.' -f 3- | rev)"
		_basenamex="$(basename "$f" | rev | cut -d '.' -f 1-2 | rev)"
	else
		_basename="$(basename "$f" | rev | cut -d '.' -f 2- | rev)"
		_basenamex="$(basename "$f" | rev | cut -d '.' -f 1 | rev)"
	fi

	return 0
}

function helper::ps2pdf(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-f <file> | to ps
		EOF
		return 1
	}

	local OPTIND arg mandatory f
	while getopts 'f:' arg; do
		case $arg in
			f) ((++mandatory)); f="$OPTARG";;
			*) _usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 1 ]] && _usage

	ps2pdf -g$(grep -m 1 -F BoundingBox "$f" | sed -E 's/.+\s+([0-9]+)\s+([0-9]+)$/\10x\20/') "$f" "${f%.*}.pdf"

	return 0
}

function helper::join(){
	helper::multijoin "$@"
}

function helper::multijoin(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-s <separator> | i/o character - default: tab
			-h <header>    | string of
			-e <empty>     | cell character - default: 0
			-o <outfile>   | path to
			-f <files>     | ALWAYS LAST OPTION
			                 tab-separated, to join by unique id in first column
			example:
			${FUNCNAME[-2]} -f <path> <path> [<path> ..]
		EOF
		return 1
	}

	local OPTIND arg mandatory outfile=/dev/stdout empty=0 sep=$'\t' tmpdir="${TMPDIR:-/tmp}"
	declare -n _makepdfcmd
	while getopts 's:h:e:o:f:' arg; do
		case $arg in
			s)	sep=$(echo -e "$OPTARG");;
			e)	empty="$OPTARG";;
			h)	header="$OPTARG";;
			o)	outfile="$OPTARG"; mkdir -p "$(dirname "$outfile")";;
			f)	((++mandatory)); shift $((OPTIND-2)); break;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 1 ]] && _usage

	local format i
	local tmp="$(mktemp -p "$tmpdir" cleanup.XXXXXXXXXX.join)"
	local joined="$(mktemp -p "$tmpdir" cleanup.XXXXXXXXXX.joined)"

	join --nocheck-order -t "$sep" -1 1 -2 1 -a 1 -a 2 -e "$empty" -o '0,1.2,2.2' "$1" "$2" > "$joined"
	for i in $(seq 3 $#); do
		format="0"
		for j in $(seq 2 $i); do format+=",1.$j"; done
		format+=",2.2"
		join --nocheck-order -t "$sep" -1 1 -2 1 -a 1 -a 2 -e "$empty" -o "$format" "$joined" "${!i}" > "$tmp"
		mv "$tmp" "$joined"
	done

	if [[ $header ]]; then
		cat <(echo -e "$header") "$joined" > "$outfile"
	else
		cat "$joined" > "$outfile"
	fi

	return 0
}

function helper::ishash(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-v <var> | variable
		EOF
		return 1
	}

	local OPTIND arg
	while getopts 'v:' arg; do
		case $arg in
			v)	{	declare -p "$OPTARG" &> /dev/null
					compgen -A variable -A arrayvar "$OPTARG" | grep -qFx "$OPTARG" && return 1
				} || return 1
				# {	declare -p "$OPTARG" &> /dev/null
				# 	declare -n __="$OPTARG"
				# 	[[ "$(declare -p ${!__})" =~ ^declare\ \-[Ab-z]+ ]]
				# } || return 1
			;;
			*)	_usage;;
		esac
	done

	return 0
}

function helper::isarray(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-v <var> | variable
		EOF
		return 1
	}

	local OPTIND arg mandatory var
	declare -a vars
	while getopts 'v:' arg; do
		case $arg in
			v)	{	declare -p "$OPTARG" &> /dev/null
					compgen -A arrayvar "$OPTARG" | grep -qFx "$OPTARG"
				} || return 1
				# {	declare -p "$OPTARG" &> /dev/null
				# 	declare -n __="$OPTARG"
				# 	[[ "$(declare -p ${!__})" =~ ^declare\ \-[a-zB-Z]+ ]]
				# } || return 1
			;;
			*)	_usage;;
		esac
	done

	return 0
}

function helper::addmemberfunctions(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-v <var> | variable
		EOF
		return 1
	}

	local OPTIND arg mandatory var
	declare -a vars
	while getopts 'v:' arg; do
		case $arg in
			v) ((++mandatory)); vars+=("$(printf '%q' "$OPTARG")");;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 1 ]] && _usage

	shopt -s expand_aliases
	for var in "${vars[@]}"; do
		eval "alias $var.get='helper::_get $var'"
		eval "alias $var.push='helper::_push $var'"
		eval "alias $var.pop='helper::_pop $var'"
		eval "alias $var.slice='helper::_slice $var'"
		eval "alias $var.join='helper::_join $var'"
		eval "alias $var.print='helper::_print $var'"
		eval "alias $var.println='helper::_println $var'"
		eval "alias $var.shift='helper::_shift $var'"
		eval "alias $var.length='helper::_length $var'"
		eval "alias $var.lastidx='helper::_lastidx $var'"
		eval "alias $var.idxs='helper::_idxs $var'"
		eval "alias $var.uc='helper::_uc $var'"
		eval "alias $var.ucfist='helper::_ucfirst $var'"
		eval "alias $var.lc='helper::_lc $var'"
		eval "alias $var.lcfist='helper::_lcfirst $var'"
		eval "alias $var.sum='helper::_sum $var'"
		eval "alias $var.trimprefix='helper::_prefix $var'"
		eval "alias $var.trimprefixfirst='helper::_prefixfirst $var'"
		eval "alias $var.trimsuffix='helper::_trimsuffix $var'"
		eval "alias $var.trimsuffixfirst='helper::_suffixfirst $var'"
		eval "alias $var.substring='helper::_substring $var'"
		eval "alias $var.replace='helper::_replace $var'"
		eval "alias $var.replaceprefix='helper::_replaceprefix $var'"
		eval "alias $var.replacesuffix='helper::_replacesuffix $var'"
		eval "alias $var.uniq='helper::_uniq $var'"
		eval "alias $var.sort='helper::_sort $var'"
		eval "alias $var.basename='helper::_basename $var'"
		eval "alias $var.dirname='helper::_dirname $var'"
	done

	return 0
}

function helper::_get(){
	declare -n __="$1"
	[[ $2 ]] && {
		local j=1
		[[ $3 ]] && {
			[[ $3 -lt 0 ]] && j=$((${#__[@]}-$2+$3)) || {
				[[ $3 -eq 0 ]] && j=${#__[@]} || j=$(($3-$2+1))
			}
		}
		echo "${__[@]:$2:$j}"
	} || echo ${__[*]}
}

function helper::_push(){
	declare -n __="$1"
	shift
	__+=("$@")
}

function helper::_pop(){
	declare -n __="$1"
	__=("${__[@]:0:$((${#__[@]}-1))}")
}

function helper::_slice(){
	declare -n __="$1"
	local j=$(($3-$2+1))
	__=("${__[@]:$2:$3}")
}

function helper::_join(){
	declare -n __="$1" ___
	shift
	for ___ in "$@"; do
		__+=("${___[@]}")
	done
}

function helper::_shift(){
	declare -n __="$1"
	__=("${__[@]:1}")
}

function helper::_idxs(){
	declare -n __="$1"
	echo "${!__[@]}"
}

function helper::_lastidx(){
	declare -n __="$1"
	echo $((${#__[@]}-1))
}

function helper::_length(){
	declare -n __="$1"
	echo ${#__[@]}
}

function helper::_print(){
	declare -n __="$1"
	echo ${__[*]}
}

function helper::_println(){
	declare -n __="$1"
	printf '%s\n' "${__[@]}"
}

function helper::_uc(){
	declare -n __="$1"
	__=("${__[@]^^${2:-*}}")
}

function helper::_ucfirst(){
	declare -n __="$1"
	__=("${__[@]^${2:-*}}")
}

function helper::_lc(){
	declare -n __="$1"
	__=("${__[@],,${2:-*}}")
}

function helper::_lcfirst(){
	declare -n __="$1"
	__=("${__[@],${2:-*}}")
}

function helper::_sum(){
	declare -n __="$1"
	__=$(("${__[@]/%/+}"0))
}

function helper::_trimsuffixfirst(){
	declare -n __="$1"
	__=("${__[@]%"$2"*}")
}

function helper::_trimsuffix(){
	declare -n __="$1"
	__=("${__[@]%%"$2"*}")
}

function helper::_trimprefixfirst(){
	declare -n __="$1"
	__=("${__[@]#*"$2"}")
}

function helper::_trimprefix(){
	declare -n __="$1"
	__=("${__[@]##*"$2"}")
}

function helper::_substring(){
	declare -n __="$1"
	local i
	if [[ $3 ]]; then
		for i in "${!__[@]}"; do
			__[$i]="${__[$i]:$2:$3}"
		done
	else
		for i in "${!__[@]}"; do
			__[$i]="${__[$i]:$2}"
		done
	fi
}

function helper::_replace(){
	declare -n __="$1"
	__=("${__[@]/${2:-*}/"$3"}")
}

function helper::_replaceprefix(){
	declare -n __="$1"
	__=("${__[@]/#${2:-*}/"$3"}")
}

function helper::_replacesuffix(){
	declare -n __="$1"
	__=("${__[@]/%${2:-*}/"$3"}")
}

function helper::_uniq(){
	declare -n __="$1"
	declare -A ___
	local e
	for e in "${__[@]}"; do
		___["$e"]=1
	done
	__=("${!___[@]}")
}

function helper::_sort(){
	declare -n __="$1"
	mapfile -t __ < <(printf '%s\n' "${__[@]}" | sort -V)
}

function helper::_basename(){
	declare -n __="$1"
	local i
	for i in "${!__[@]}"; do
		${__[$i]}="$(basename "${__[$i]}" "$2")"
	done
}

function helper::_dirname(){
	declare -n __="$1"
	local i
	for i in "${!__[@]}"; do
		${__[$i]}="$(dirname "${__[$i]}")"
	done
}

function helper::_test(){
	declare -a arr
	helper::addmemberfunctions -v arr
	arr.push "f.o.o f.o.o"
	arr.push bar
	arr.push zar
	arr.print
	arr.get 0 -1
	arr.get 1 0
	arr.sort
	arr.print
	arr.uc [fa]
	arr.print
	arr.replace A X
	arr.print
	arr.lc
	arr.print
	arr.slice 1 2
	arr.print
	arr.substring 1 2
	arr.print
	arr.uniq
	arr.print
}
