#! /usr/bin/env bash
# (c) Konstantin Riege

function alignment::mkreplicates(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>   | true/false return
			-s <softskip>   | true/false only print commands
			-t <threads>    | number of
			-r <mapper>     | array of sorted bams within array of
			-n <nidx>       | array of normal bam idices within -r
			-m <nridx>      | array of normal repl bam idices within -r
			-i <tidx>       | no treat repl ? array to store new pseudorepl bam : array of treat bam idices within -r
			-j <ridx>       | no treat repl ? array to store new pseudorepl bam : array of treat repl bam idices within -r
			-k <pidx>       | no treat repl ? array of treat aka pseudopool bam : array to store new fullpool bam idices within -r
			-o <outdir>     | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir tmpdir="${TMPDIR:-/tmp}"
	declare -n _mapper_mkreplicates _nidx_mkreplicates _nridx_mkreplicates _tidx_mkreplicates _ridx_mkreplicates _pidx_mkreplicates
	while getopts 'S:s:q:t:r:n:m:i:j:k:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			r)	((++mandatory)); _mapper_mkreplicates=$OPTARG;;
			n)	((++mandatory)); _nidx_mkreplicates=$OPTARG;;
			m)	_nridx_mkreplicates=$OPTARG;;
			i)	((++mandatory)); _tidx_mkreplicates=$OPTARG;;
			j)	((++mandatory)); _ridx_mkreplicates=$OPTARG;;
			k)	((++mandatory)); _pidx_mkreplicates=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 7 ]] && _usage

	local ithreads1 ithreads2 instances1 instances2
	instances1=$((${#_mapper_mkreplicates[@]} * ${#_nidx_mkreplicates[@]}))
	instances2=$((${#_mapper_mkreplicates[@]} * ${#_nidx_mkreplicates[@]} * 2 + ${#_mapper_mkreplicates[@]} * ${#_nridx_mkreplicates[@]} * 2))
	read -r instances1 ithreads1 < <(configure::instances_by_threads -i $instances1 -t 10 -T $threads)
	read -r instances2 ithreads2 < <(configure::instances_by_threads -i $instances2 -t 10 -T $threads)

	local m i odir o tmp nf nrf tf rf pf addindex=true
	declare -a tdirs cmd1 cmd2 cmd3
	if [[ $_ridx_mkreplicates ]]; then
		commander::printinfo "generating pseudo-pools"

		# pool replicates:
		# m[N1 N2 T1 T2 R1 R2] -> m[N1 N2 T1 T2 R1 R2 PP1 PP2]
		# n   1 2
		# nr
		# t   3 4
		# r   5 6
		# p   7 8
		# -> idr: 1 vs 3 + 1 vs 5 + 1 vs 7
		#          2 vs 4 + 2 vs 6 + 2 vs 8
		for m in "${_mapper_mkreplicates[@]}"; do
			declare -n _bams_mkreplicates=$m
			odir=$outdir/$m
			mkdir -p "$odir"
			for i in "${!_nidx_mkreplicates[@]}"; do
				tf="${_bams_mkreplicates[${_tidx_mkreplicates[$i]}]}"
				rf="${_bams_mkreplicates[${_ridx_mkreplicates[$i]}]}"
				o="$odir/$(echo -e "$(basename "$tf")\t$(basename "$rf")" | sed -E 's/(\..+)\t(.+)\1/-\2.pseudopool\1/')"

				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					samtools merge
						-f
						-c
						-p
						-@ $ithreads1
						--write-index
						-o "$o##idx##${o%.*}.bai"
						<(samtools view -@ $(((ithreads1+1)/2)) -u -s 0.5 "$tf")
						<(samtools view -@ $(((ithreads1+1)/2)) -u -s 0.5 "$rf")
				CMD

				_bams_mkreplicates+=("$o")
				_pidx_mkreplicates+=($((${#_bams_mkreplicates[@]}-1)))
			done
		done

		if [[ $_nridx_mkreplicates ]]; then
			# create fully pooled bams and extend _nidx_mkreplicates by indices for n/nr/nfp based peak calling
			# PP : pseudopool (2x0.5) , FP: fullpool (2x1)
			#                                           1  2   3   4  5  6  7  8  9   10   11  12   13  14
			# m[N1 N2 NR1 NR2 T1 T2 R1 R2 PP1 PP2] -> m[N1 N2 NR1 NR2 T1 T2 R1 R2 PP1 PP2 NFP1 FP1 NFP2 FP2]
			# n   1 2   3 4   11 13
			# nr  3 4
			# t   5 6   5 6   5  6
			# r   7 8   7 8   7  8
			# p   9 10  9 10  12 14
			# -> idr: 1 vs 5 + 1 vs 7 + 1 vs 9
			#          2 vs 6 + 2 vs 8 + 2 vs 10
			#         3 vs 5 + 3 vs 7 + 3 vs 9
			#          4 vs 6 + 4 vs 8 + 4 vs 10
			#         11 vs 5 + 11 vs 7 + 11 vs 12
			#          13 vs 6 + 13 vs 8 + 13 vs 14
			_nidx_mkreplicates=("${_nidx_mkreplicates[@]}" "${_nridx_mkreplicates[@]}")
			_tidx_mkreplicates+=("${_tidx_mkreplicates[@]}" "${_tidx_mkreplicates[@]}")
			_ridx_mkreplicates+=("${_ridx_mkreplicates[@]}" "${_ridx_mkreplicates[@]}")
			_pidx_mkreplicates+=("${_pidx_mkreplicates[@]}")
			for m in "${_mapper_mkreplicates[@]}"; do
				declare -n _bams_mkreplicates=$m
				odir="$outdir/$m"
				mkdir -p $odir
				for i in "${!_nridx_mkreplicates[@]}"; do
					nf="${_bams_mkreplicates[${_nidx_mkreplicates[$i]}]}"
					nrf="${_bams_mkreplicates[${_nridx_mkreplicates[$i]}]}"
					o="$odir/$(echo -e "$(basename "$nf")\t$(basename "$nrf")" | sed -E 's/(\..+)\t(.+)\1/-\2.fullpool\1/')"

					commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
						samtools merge
							-f
							-c
							-p
							-@ $ithreads2
							--write-index
							-o "$o##idx##${o%.*}.bai"
							"$nf" "$nrf"
					CMD
					_bams_mkreplicates+=("$o")
					$addindex && _nidx_mkreplicates+=($((${#_bams_mkreplicates[@]}-1)))

					tf="${_bams_mkreplicates[${_tidx_mkreplicates[$i]}]}"
					rf="${_bams_mkreplicates[${_ridx_mkreplicates[$i]}]}"
					o="$odir/$(echo -e "$(basename "$tf")\t$(basename "$rf")" | sed -E 's/(\..+)\t(.+)\1/-\2.fullpool\1/')"
					commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
						samtools merge
							-f
							-c
							-p
							-@ $ithreads2
							--write-index
							-o "$o##idx##${o%.*}.bai"
							"$tf" "$rf"
					CMD
					_bams_mkreplicates+=("$o")
					$addindex && _pidx_mkreplicates+=($((${#_bams_mkreplicates[@]}-1)))
				done
				addindex=false
			done
		fi
	else
		commander::printinfo "generating pseudo-replicates"

		# make pseudo-replicates from pseudo-pool:
		# m[N1 N2 P1 P2] -> m[N1 N2 P1 P2 T1 R1 T2 R2]
		# n   1 2
		# nr
		# t   5 7
		# r   6 8
		# p   3 4
		# -> idr: 1 vs 5 + 1 vs 6 + 1 vs 3
		#          2 vs 7 + 2 vs 8 + 2 vs 4
		for m in "${_mapper_mkreplicates[@]}"; do
			declare -n _bams_mkreplicates=$m
			odir="$outdir/$m"
			mkdir -p "$odir"

			for i in "${!_nidx_mkreplicates[@]}"; do
				pf="${_bams_mkreplicates[${_pidx_mkreplicates[$i]}]}"
				o="$odir/$(basename "${pf%.*}").pseudorep"
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.mkreplicates)")

				commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD
					samtools collate
						-@ $ithreads1
						-u
						-O
						-n 1
						"$pf" "${tdirs[-1]}/$(basename "${pf%.*}")"
				CMD
					samtools view --no-PG -@ $ithreads1
				CMD
					split
						--numeric-suffixes=1
						--additional-suffix=.bam
						-a 1
						-l \$(( (\$(samtools view -c -@ $ithreads1 "$pf")+1)/2 ))
						--filter='cat <(samtools view --no-PG -H "$pf") - | samtools sort -@ $ithreads1 -O BAM -T "${tdirs[-1]}/\$(basename "\${FILE%.*}")" --write-index -o "\$FILE##idx##\${FILE%.*}.bai"'
						- "$o"
				CMD
					# split
					# 	--numeric-suffixes=1
					# 	--additional-suffix=.bam
					# 	-a 1
					# 	-l \$(( (\$(samtools view -c -@ $ithreads1 "$pf")+1)/2 ))
					# 	--filter='cat <(samtools view -H "$pf") - | samtools sort -@ $ithreads1 -O BAM -T "${tdirs[-1]}/\$(basename "\${FILE%.*}")" > "\$FILE"'
					# 	- "$o";
					# samtools index -@ $ithreads1 "${o}1.bam" "${o}1.bai";
					# samtools index -@ $ithreads1 "${o}2.bam" "${o}2.bai";

				# -n number of temporary files has default 64
				# -u not equals --output-fmt SAM => a small compression level (optimum: -l 3) reduces amount of data stream through pipe
				# which finally makes samtools view faster despite of decompression - tested with 650M bam (~1m30 vs ~1m)
				# samtools view necessary, because it removes header - grep -v '^@' may match CIGAR string
				_bams_mkreplicates+=("${o}1.bam")
				_tidx_mkreplicates+=($((${#_bams_mkreplicates[@]}-1)))
				_bams_mkreplicates+=("${o}2.bam")
				_ridx_mkreplicates+=($((${#_bams_mkreplicates[@]}-1)))
			done
		done

		# if [[ $_nridx_mkreplicates ]]; then
			# nothing to do here
			#   1  2   3   4  5  6  7  8  9  10
			# m[N1 N2 NR1 NR2 P1 P2 T1 R1 T2 R2]
			# n   1 2   3 4
			# nr  3 4
			# t   7 9   7 9
			# r   8 10  8 10
			# p   5 6   5 6
			# -> idr: 1 vs 7 + 1 vs 8 + 1 vs 5
			#          2 vs 9 + 2 vs 10 + 2 vs 6
			#         3 vs 7 + 3 vs 8 + 3 vs 5
			#          4 vs 9 + 4 vs 10 + 4 vs 6
		# fi
	fi

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
	else
		commander::runcmd -v -b -i $instances1 -a cmd1
		commander::runcmd -v -b -i $instances2 -a cmd2
	fi

	return 0
}

function alignment::strandsplit(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>   | true/false return
			-s <softskip>   | true/false only print commands. use with -d
			-t <threads>    | number of
			-r <mapper>     | array of sorted, indexed bams within array of
			-x <strandness> | hash per bam of
			-g <gtf>        | path to
			-o <outdir>     | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir tmpdir="${TMPDIR:-/tmp}" gtf
	declare -n _mapper_strandsplit _strandness_strandsplit
	while getopts 'S:s:t:r:x:g:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			g)	gtf="$OPTARG";;
			t)	((++mandatory)); threads=$OPTARG;;
			r)	((++mandatory)); _mapper_strandsplit=$OPTARG;;
			x)	((++mandatory)); _strandness_strandsplit=$OPTARG;;
			o)	outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 3 ]] && _usage

	commander::printinfo "splitting alignments according to strandness"

	declare -a tdirs cmd1 cmd2
	local m f odir b x s r o
	for m in "${_mapper_strandsplit[@]}"; do
		declare -n _bams_strandsplit=$m
		for f in "${_bams_strandsplit[@]}"; do
			odir="$outdir/$m"
			[[ $outdir ]] || odir="$(dirname "$f")"
			mkdir -p "$odir"
			o="$odir/$(basename "${f%.*}")"

			if [[ _strandness_strandsplit["$f"] -eq 0 ]]; then
				commander::warn "library preparation for $f was not strand specific. skipping."
				continue
			fi

			if [[ _strandness_strandsplit["$f"] -eq 1 ]]; then
				s="+"
				r="-"
			else
				s="-"
				r="+"
			fi
			b="$(basename "$f")"
			b="${b%.*}"

			# infer SE or PE filter
			x=$(samtools view -F 4 "$f" | head -10000 | cat <(samtools view -H "$f") - | samtools view -c -f 1)
			tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.samtools)")

			if [[ $x -gt 0 ]]; then
				# 98 = proper-pair + first-in-pair + mate-reverse
				# 146 = poper-pair + second-in-pair + reverse
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					samtools merge
						-f
						-c
						-p
						-@ $threads
						--write-index
						-o "$o.$s.bam##idx##$o.$s.bai"
					<(samtools view -@ $(((threads+1)/2)) -u -F 4 -f 98 "$f" | samtools sort -u -@ $(((threads+1)/2)) -T "${tdirs[-1]}/$b.R1")
					<(samtools view -@ $(((threads+1)/2)) -u -F 4 -f 146 "$f" | samtools sort -u -@ $(((threads+1)/2)) -T "${tdirs[-1]}/$b.R2")
				CMD
			else
				# 16 = reverse
				commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					samtools view
						-@ $threads
						-u
						-F 4
						-F 16
						"$f"
				CMD
					samtools sort
						-O BAM
						-@ $threads
						-T "${tdirs[-1]}/$b"
						--write-index
						-o "$o.$s.bam##idx##$o.$s.bai"
				CMD
			fi

			if [[ $gtf ]]; then
				commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					samtools view
						-@ $threads
						-u
						-M
						-L <(awk -v OFS="\\t" '\$3=="gene" && \$7=="$s"{print \$1,\$4-1,\$5}' "$gtf")
						"$o.$s.bam"
				CMD
					samtools sort
						-@ $threads
						-O BAM
						-T "${tdirs[-1]}/$b"
						--write-index
						-o "$o.$s.filtered.bam##idx##$o.$s.filtered.bai"
				CMD
			fi

			if [[ $x -gt 0 ]]; then
				# 82 = proper-pair + first-in-pair + reverse
				# 162 = proper-pair + second-in-pair + mate-reverse
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.samtools)")
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					samtools merge
						-f
						-c
						-p
						-@ $threads
						--write-index
						-o "$o.$r.bam##idx##$o.$r.bai"
					<(samtools view -@ $(((threads+1)/2)) -u -F 4 -f 82 "$f" | samtools sort -u -@ $(((threads+1)/2)) -T "${tdirs[-1]}/$b.R1")
					<(samtools view -@ $(((threads+1)/2)) -u -F 4 -f 162 "$f" | samtools sort -u -@ $(((threads+1)/2)) -T "${tdirs[-1]}/$b.R2")
				CMD
			else
				# 16 = reverse
				commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					samtools view
						-@ $threads
						-u
						-F 4
						-f 16
						"$f"
				CMD
					samtools sort
						-O BAM
						-@ $threads
						-T "${tdirs[-1]}/$b"
						--write-index
						-o "$o.$r.bam##idx##$o.$r.bai"
				CMD
			fi

			if [[ $gtf ]]; then
				commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					samtools view -@ $threads -u -M	-L <(awk -v OFS="\\t" '\$3=="gene" && \$7=="$r"{print \$1,\$4-1,\$5}' "$gtf") "$o.$r.bam"
				CMD
					samtools sort
						-@ $threads
						-O BAM
						-T "${tdirs[-1]}/$b"
						--write-index
						-o "$o.$r.filtered.bam##idx##$o.$r.filtered.bai"
				CMD
			fi
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
	else
		commander::runcmd -v -b -i 1 -a cmd1
		commander::runcmd -v -b -i 1 -a cmd2
	fi

	return 0
}

function alignment::downsample(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>   | true/false return
			-s <softskip>   | true/false only print commands. use with -d
			-t <threads>    | number of
			-r <mapper>     | array of sorted, indexed bams within array of
			-o <outdir>     | path to
			-m <basename>   | of merged bam from downsampled files. optional
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir merged delete=false
	declare -n _mapper_downsample
	while getopts 'S:s:t:r:o:m:d' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			r)	((++mandatory)); _mapper_downsample=$OPTARG;;
			o)	outdir="$OPTARG"; mkdir -p "$outdir";;
			m)	merged="$OPTARG";;
			d)	delete=true;;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 2 ]] && _usage
	[[ $merged && ! $outdir ]] && _usage

	commander::printinfo "downsampling alignments to smallest"

	declare -n _bams_downsample="${_mapper_downsample[0]}"
	# local ithreads instances=$((${#_mapper_downsample[@]}*${#_bams_downsample[@]}))
	# read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	declare -a cmd1 cmd2 cmd3 cmd4 tomerge
	local m i n f min odir
	for m in "${_mapper_downsample[@]}"; do
		declare -n _bams_downsample=$m
		[[ $outdir ]] && odir="$outdir/$m" && mkdir -p "$odir"

		tomerge=()
		min=0
		while read -r n i; do
			f="${_bams_downsample[$i]}"
			[[ $outdir ]] || odir="$(dirname "$f")"
			o="$odir/$(basename "${f%.*}").downsampled.bam"
			tomerge+=("$o")

			if [[ $min -eq 0 ]]; then
				min=$n
				# ln -sfnr "$f" "$o"
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					cp "$f" "$o"
				CMD
			else
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					samtools view -@ $threads -b --subsample-seed 1234 -s $(echo $n | awk -v min=$min '{print min/$1}') -o "$o" "$f"
				CMD
			fi
			commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
				samtools index -@ $threads "$o" "${o%.*}.bai"
			CMD

			_bams_downsample[$i]="$o"
		done < <(
			for i in "${!_bams_downsample[@]}"; do
				echo "$(samtools idxstats "${_bams_downsample[$i]}" | awk '{n=n+$3}END{print n}') $i"
			done | sort -k1,1n
		)

		if [[ $merged ]]; then
			commander::makecmd -a cmd3 -s ';' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $threads
					-f
					-c
					-p
					--write-index
					-o "$outdir/$m/$merged##idx##$outdir/$m/${merged%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			if $delete; then
				commander::makecmd -a cmd4 -s ';' -c {COMMANDER[0]}<<- CMD
					rm -f $(printf '"%s" ' "${tomerge[@]}")
				CMD
			fi
		fi
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
		commander::printcmd -a cmd4
	else
		commander::runcmd -v -b -i 1 -a cmd1
		commander::runcmd -v -b -i 1 -a cmd2
		commander::runcmd -v -b -i 1 -a cmd3
		commander::runcmd -v -b -i 1 -a cmd4
	fi

	return 0
}
