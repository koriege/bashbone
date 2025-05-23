#! /usr/bin/env bash
# (c) Konstantin Riege

function alignment::slice(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <slicesinfo>| hash per bam of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory tmpdir="${TMPDIR:-/tmp}"
	declare -n _mapper_slice _bamslices_slice
	while getopts 'S:s:t:m:M:r:c:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			r)	((++mandatory)); _mapper_slice=$OPTARG;;
			c)	((++mandatory)); _bamslices_slice=$OPTARG;;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 4 ]] && _usage

	commander::printinfo "slicing alignments"

	declare -n _bams_slice="${_mapper_slice[0]}"
	local minstances mthreads instances ithreads
	read -r minstances mthreads < <(configure::instances_by_memory -T $threads -m $memory -M "$maxmemory")
	read -r instances ithreads < <(configure::instances_by_threads -t 10 -T $threads)

	local tdir m f i bed o
	declare -a mapdata cmd1 cmd2 cmd3 cmd4

	mkdir -p "$tmpdir/genome"
	samtools view -H "${_bams_slice[0]}" | sed -En '/^@SQ/{s/.+\tSN:(\S+)\s+LN:(\S+).*/\1\t0\t\2/p}' > "$tmpdir/genome/chr.bed"
	# do not use process substitution as Rscript argument - sometimes R swallows parts
	# in case of thousands of contigs, sum of lengths in binpacking function causes integer out bounds and function will never terminate
	# -> divide lengths by 1000
	commander::makecmd -a cmd1 -s ' ' -c {COMMANDER[0]}<<- 'CMD' {COMMANDER[1]}<<- CMD
		Rscript - <<< '
			suppressMessages(library("knapsack"));
			args <- commandArgs(TRUE);
			slices <- as.numeric(args[1]);
			odir <- args[2];
			df <- read.table(args[3], header=F, sep="\t", stringsAsFactors=F, check.names=F, quote="");

			len <- as.integer(df[,3]/1000+1);
			srt <- sort(len,decreasing=T,index.return=1);
			len <- srt$x;
			df <- df[srt$ix,];

			lmax <- max(len);
			bins <- c(1:nrow(df));
			n <- length(bins);
			i <- 1;
			while(n > slices){
				i <- i+1;
				b <- binpacking(len, cap=as.integer(lmax/2*i+1));
				n <- b$nbins;
				bins <- b$xbins;
			};
			for (j in 1:n){
				write.table(df[bins %in% j,], row.names = F, col.names = F, file=file.path(odir,paste("slice",j,"bed",sep=".")), quote=F, sep="\t");
			};
		'
	CMD
		$minstances "$tmpdir/genome" "$tmpdir/genome/chr.bed"
	CMD

	if $skip; then
		for i in $(seq 1 $minstances); do
			touch "$tmpdir/genome/slice.$i.bed"
		done
		commander::printcmd -a cmd1
	else
		rm -f "$tmpdir/genome/slice".*.bed
		commander::runcmd -v -b -i $threads -a cmd1
	fi

	for m in "${_mapper_slice[@]}"; do
		declare -n _bams_slice=$m
		tdir="$tmpdir/$m"
		mkdir -p "$tdir" # do not use mktemp which triggers cleanup, since slices might be reused later
		for f in "${_bams_slice[@]}"; do
			o="$tdir"/$(basename "$f")
			o="${o%.*}"

			mapfile -t mapdata < <(find "$tmpdir/genome" -maxdepth 1 -type f -name "slice.*.bed" | sort -V)
			printf "%s\n" "${mapdata[@]}" | sed -E "s@.+\.([0-9]+)\.bed@$o.slice.\1.bam@" > "$o.slices.info"
			_bamslices_slice["$f"]="$o.slices.info"

			for bed in "${mapdata[@]}"; do
				i=$(basename "$bed" .bed | rev | cut -d '.' -f 1 | rev)
				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
					samtools view
						-@ $ithreads
						-L "$bed"
						-M
						-b
						--no-PG
						--write-index
						-o "$o.slice.$i.bam##idx##$o.slice.$i.bai"
						"$f"
				CMD
			done
		done
	done

	if $skip; then
		commander::printcmd -a cmd2
		# commander::printcmd -a cmd3
	else
		commander::runcmd -v -b -i $instances -a cmd2
		# commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::rmduplicates(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-k             | keep marked duplicates in bam
			-l             | true/false legacy mode. true:MarkDuplikates/UMI-tools, false (for SE or PE DNA-seq only!): MarkDuplicatesWithMateCigar/UmiAwareMarkDuplicatesWithMateCigar (default: true)
			-t <threads>   | number of
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-3 <fastqUMI>  | array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
			-x <regex>     | of read name identifier with grouped tile information. default: \S+:(\d+):(\d+):(\d+)\s*.*
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory outdir regex remove=true legacy=true tmpdir="${TMPDIR:-/tmp}"
	declare -n _mapper_rmduplicates _bamslices_rmduplicates _umi_rmduplicates
	while getopts 'S:s:t:m:M:x:r:3:c:o:l:k' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			k)	remove=false;;
			l)	legacy=$OPTARG;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			x)	regex="$OPTARG";;
			r)	((++mandatory)); _mapper_rmduplicates=$OPTARG;;
			3)	_umi_rmduplicates=$OPTARG;;
			c)	((++mandatory)); _bamslices_rmduplicates=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 5 ]] && _usage

	commander::printinfo "removing alignment duplicates"

	local sinstances sthreads smemory minstances mthreads jmem jgct jcgct
	read -r sinstances sthreads smemory jgct jcgct < <(configure::jvm -i ${#_umi_rmduplicates[@]} -T $threads -m $memory -M "$maxmemory")
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")
	local nfh=$(($(ulimit -n)/minstances))
	[[ ! $nfh ]] || [[ $nfh -le 1 ]] && nfh=$((1024/minstances))

	local m i o e slice instances ithreads odir params x=0 oinstances othreads
	for m in "${_mapper_rmduplicates[@]}"; do
		declare -n _bams_rmduplicates=$m
		i=$(wc -l < "${_bamslices_rmduplicates[${_bams_rmduplicates[0]}]}")
		((instances+=i*${#_bams_rmduplicates[@]}))
		((oinstances+=${#_bams_rmduplicates[@]}))
	done
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)
	read -r oinstances othreads < <(configure::instances_by_threads -i $oinstances -t 10 -T $threads)

	# to get MC tags use a mapper like bwa or
	# samtools sort -n | samtools fixmate or
	# picard FixMateInformation
	declare -a cmdsort umi_rmduplicates
	if [[ $_umi_rmduplicates ]]; then
		for i in "${!_umi_rmduplicates[@]}"; do
			helper::basename -f "${_umi_rmduplicates[$i]}" -o o -e e
			e=$(echo $e | cut -d '.' -f 1)
			o="$tmpdir/$o.$e.gz"

			commander::makecmd -a cmdsort -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- 'CMD' {COMMANDER[2]}<<- CMD {COMMANDER[3]}<<- 'CMD' {COMMANDER[4]}<<- CMD
				helper::cat -f "${_umi_rmduplicates[$i]}" | paste - - - -
			CMD
				awk -v OFS='\t' '{print $1,$(NF-2),$(NF-1),$NF}'
			CMD
				LC_ALL=C sort --parallel=$sthreads -S ${smemory}M -T "$tmpdir" -k1,1V
			CMD
				tr '\t' '\n'
			CMD
				helper::pgzip -t $sthreads -o "$o"
			CMD
			umi_rmduplicates[$i]="$o"
		done

		if $legacy; then # umitools for SE and PE. handles large split reads since simple 5' position based dedup
			x=$(samtools view -F 4 "${_bams_rmduplicates[0]}" | head -10000 | cat <(samtools view -H "${_bams_rmduplicates[0]}") - | samtools view -c -f 1)
			[[ $x -gt 0 ]] && params="--paired"
		else
			# picard UmiAwareMarkDuplicatesWithMateCigar designed for PE without N-cigar (ie not for RNA-seq)
			# needs MC tag (works also for SE without MC). due to 5'trimming searches +- readlenght around 5' position for reads of identical fragment
			# x=$(samtools view -F 4 "${_bams_rmduplicates[0]}" | head -10000 | cat <(samtools view -H "${_bams_rmduplicates[0]}") - | samtools view -c -f 1 -d MC)
			params="UmiAwareMarkDuplicatesWithMateCigar"
			[[ $regex ]] && params+=" READ_NAME_REGEX='$regex'" # default is to follow casava i.e. split by 5 or 7 colons and use the last 3 groups i.e. \s+:\d+:\d+:\d+.*
		fi
	else
		# picard MarkDuplicates for SE (and PE) and large splits
		params="MarkDuplicates MAX_FILE_HANDLES=$nfh"
		if ! $legacy; then
			x=$(samtools view -F 4 "${_bams_rmduplicates[0]}" | head -10000 | cat <(samtools view -H "${_bams_rmduplicates[0]}") - | samtools view -c -f 1)
			[[ $x -gt 0 ]] && params="MarkDuplicatesWithMateCigar"
		fi
		[[ $regex ]] && params+=" READ_NAME_REGEX='$regex'"
		legacy=false # for runcmd conda env selection
	fi

	declare -a tdirs tomerge cmd1 cmd2 cmd3 cmd4
	for m in "${_mapper_rmduplicates[@]}"; do
		declare -n _bams_rmduplicates=$m
		odir="$outdir/$m"
		mkdir -p "$odir"
		for i in "${!_bams_rmduplicates[@]}"; do
			tomerge=()
			while read -r slice; do
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.rmduplicates)")

				if [[ $umi_rmduplicates ]]; then
					commander::makecmd -a cmd1 -s ' ' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD {COMMANDER[3]}<<- 'CMD' {COMMANDER[4]}<<- CMD {COMMANDER[5]}<<- CMD
						samtools sort
							-n
							-@ $ithreads
							-u
							-T "${tdirs[-1]}/$(basename "${slice%.*}")"
							"$slice"
					CMD
						| samtools fixmate
							-@ $ithreads
							-r
							-O SAM
							- -
					CMD
						| awk -v f=<(helper::cat -f "${umi_rmduplicates[$i]}" | paste - - - -)
					CMD
						-v OFS='\t' '/^@\S\S\s/{print; next}{l=$0; r="@"$1; while(r!=u){getline < f; u=$1; s=$2; q=$4} print l,"RX:Z:"s,"QX:Z:"q}'
					CMD
						| samtools sort
							-@ $ithreads
							-O BAM
							-T "${tdirs[-1]}/$(basename "${slice%.*}").rx"
							--write-index
							-o "$slice.rx##idx##${slice%.*}.bai";
					CMD
						mv "$slice.rx" "$slice";
					CMD
					# alternative 1
					# picard MergeBamAlignment on input bam and created unaligned_umi.bam
					# alternative 2
					# commander::makecmd -a cmd -s ';' -c {COMMANDER[0]}<<- CMD
					# 	fgbio
					# 		-Xmx${jmem}m
					# 		-XX:ParallelGCThreads=$jgct
					# 		-XX:ConcGCThreads=$jcgct
					# 		-Djava.io.tmpdir="$tmpdir"
					# 		--tmp-dir="${tdirs[-1]}"
					# 	AnnotateBamWithUmis
					# 		-s true
					# 		-t RX
					# 		-i "$slice.nsorted"
					# 		-f "${umi_rmduplicates[$i]}"
					# 		-o "$slice"
					# CMD
					# inefficient piece of shit even if name sorted input complains about offending records and uses >10gb ram
					# alternative for unsorted files
					# samtools view -h results-RRBS_pilot/F_anselli/mapped/bwa/no001-1_Fmi_439_NN_RRBS_S1_R1_001.unique.sorted.bam | awk -v umi=RAW-RRBS_pilot/no001-1_Fmi_439_NN_RRBS_S1_UMI_001.fastq.gz 'BEGIN{while(("zcat \""umi"\" | paste - - - -" |& getline)){m[$1]=$(NF-2)}}{if($0~/^@\S\S\s+\S/){print}else{print $0"\tRX:Z:"m["@"$1]}}' | samtools view -@ 56 -b > dedub.bam
					# less memory consumption than fgbio, but 1/3 more memory than perl hash (still too much ~6 times uncompressed umi fq)

					if $legacy; then
						commander::makecmd -a cmd2 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
							umi_tools dedup
								-I "$slice"
								--log2stderr
								--temp-dir "${tdirs[-1]}"
								--extract-umi-method tag
								--umi-tag RX
								--method directional
								--edit-distance-threshold 1
								--random-seed 12345
								--no-sort-output
								$params
						CMD
							samtools sort
								--no-PG
								-@ $ithreads
								-O BAM
								-T "${tdirs[-1]}/$(basename "${slice%.*}")"
								-o "$slice.rmdup"
						CMD
					else
						commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
							MALLOC_ARENA_MAX=4 picard
								-Xmx${jmem}m
								-XX:ParallelGCThreads=$jgct
								-XX:ConcGCThreads=$jcgct
								-Djava.io.tmpdir="$tmpdir"
								$params
								I="$slice"
								O="$slice.rmdup"
								M="$slice.metrics"
								TMP_DIR="${tdirs[-1]}"
								UMI_METRICS_FILE="$slice.umimetrics"
								MAX_EDIT_DISTANCE_TO_JOIN=1
								UMI_TAG_NAME=RX
								CLEAR_DT=false
								REMOVE_DUPLICATES=$remove
								ASSUME_SORT_ORDER=coordinate
								VALIDATION_STRINGENCY=SILENT
								VERBOSITY=WARNING
								MAX_FILE_HANDLES=$nfh
						CMD
					fi
					# alternative: fgbio GroupReadsByUmi --mark-duplicates=true
				else
					if [[ $x -gt 0 ]]; then
						commander::makecmd -a cmd1 -s ' ' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD {COMMANDER[3]}<<- CMD
							samtools sort
								-n
								-@ $ithreads
								-u
								-T "${tdirs[-1]}/$(basename "${slice%.*}")"
								"$slice"
						CMD
							| samtools fixmate
								-@ $ithreads
								-r
								-u
								- -
						CMD
							| samtools sort
								-@ $ithreads
								-O BAM
								-T "${tdirs[-1]}/$(basename "${slice%.*}").mc"
								--write-index
								-o "$slice.mc##idx##${slice%.*}.bai";
						CMD
							mv "$slice.mc" "$slice";
						CMD
					fi

					commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
						MALLOC_ARENA_MAX=4 picard
							-Xmx${jmem}m
							-XX:ParallelGCThreads=$jgct
							-XX:ConcGCThreads=$jcgct
							-Djava.io.tmpdir="$tmpdir"
							$params
							I="$slice"
							O="$slice.rmdup"
							M="$slice.metrics"
							TMP_DIR="${tdirs[-1]}"
							REMOVE_DUPLICATES=$remove
							ASSUME_SORT_ORDER=coordinate
							VALIDATION_STRINGENCY=SILENT
							VERBOSITY=WARNING
					CMD
					# note REMOVE_DUPLICATES=true removes, without -> marks
					# alternative1: samtools sort -n -u -@ $threads -T $tmp/$prefix1 $bam | samtools fixmate -@ $threads -m -u - - | samtools sort -u -@ $threads -T $tmp/$prefix2 | samtools markdup -r -S -T $tmp/$prefix3 -u -@ $threads - $bam.rmdup
					# note: -r removes, without -> marks
					# alternative2: samtools sort -n -@ $threads -O SAM -T $tmp/$prefix1 $bam | samblaster --removeDups --addMateTags | samtools sort -@ $threads -O BAM -T $tmp/$prefix2 > $bam.rmdup
					# note: --removeDups removes, else use --excludeDups. requires setupped RG in SAM header
					# alternative3: sambamba / dupsifter
				fi

				commander::makecmd -a cmd3 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.rmdup" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_rmduplicates[${_bams_rmduplicates[$i]}]}"

			o="$odir"/$(basename "${_bams_rmduplicates[$i]}")
			o="${o%.*}.rmdup.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd4 -s ';' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $othreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_rmduplicates["$o"]="${_bamslices_rmduplicates[${_bams_rmduplicates[$i]}]}"
			_bams_rmduplicates[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmdsort
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
		commander::printcmd -a cmd4
	else
		commander::runcmd -v -b -i $sinstances -a cmdsort
		commander::runcmd -v -b -i $instances -a cmd1
		if $legacy; then
			commander::runcmd -c umitools -v -b -i $minstances -a cmd2
		else
			commander::runcmd -c picard -v -b -i $minstances -a cmd2
		fi
		commander::runcmd -v -b -i $instances -a cmd3
		commander::runcmd -v -b -i $oinstances -a cmd4
	fi

	return 0
}

function alignment::tn5clip(){
	alignment::clip "$@" -5 4 -3 0 -5 5 -3 0
}

function alignment::clip(){
	# does not handle secondary and supplementary alignments
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-g <genome>    | mandatory
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
			-5 <value>     | to be clipped from single or first mate 5'. use twice for mate pairs.
			-3 <value>     | to be clipped from single or first mate 3'. use twice for mate pairs.
			-H             | swtich from soft to hard clip
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false genome threads memory maxmemory outdir tmpdir="${TMPDIR:-/tmp}" r15 r13 r25 r23 mode=Soft
	declare -n _mapper_clip _bamslices_clip
	declare -A nidx tidx
	while getopts 'S:s:t:m:M:g:r:c:o:5:3:H' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			r)	((++mandatory)); _mapper_clip=$OPTARG;;
			c)	((++mandatory)); _bamslices_clip=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			5)	[[ $r15 ]] && r25="$OPTARG" || r15="$OPTARG";;
			3)	[[ $r13 ]] && r23="$OPTARG" || r13="$OPTARG";;
			H)	mode=Hard;;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 6 ]] && _usage
	[[ $r15 ]] || [[ $r13 ]] || _usage

	commander::printinfo "${mode,,}-clipping read ends"

	declare -n _bams_clip="${_mapper_clip[0]}"
	local instances=$((${#_mapper_clip[@]}*${#_bams_clip[@]}))
	local ithreads minstances mthreads jmem jgct jcgct
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	# version < 2 output is always coordiante sorted and indexed, >2 add may use --sort-order=Unsorted and use /dev/stdout | samtools sort for speedup
	declare -a cmdchk=("{ fgbio -v 2>&1 || true; } | grep -m 1 Version | awk '{print \$2}' | cut -d '.' -f 1")
	local params version=$(commander::runcmd -c fgbio -a cmdchk)
	[[ $version -eq 1 ]] || params="--sort-order=Unsorted"

	declare -n _bams_clip="${_mapper_clip[0]}"
	x=$(samtools view -F 4 "${_bams_clip[0]}" | head -10000 | cat <(samtools view -H "${_bams_clip[0]}") - | samtools view -c -f 1)
	[[ $x -gt 0 ]] && params+=" --read-two-five-prime=${r25:-0} --read-two-three-prime=${r23:-0}"

	local m i o slice odir x=0
	declare -a tdirs tomerge cmd1 cmd2
	for m in "${_mapper_clip[@]}"; do
		declare -n _bams_clip=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_clip[@]}"; do
			tomerge=()

			while read -r slice; do
				# fgbio can clip half the overlap from both reads, thus does not produce unmapped reads and does fixmate after clipping and indexing

				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.fgbio)")
				commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD
					samtools sort
						-@ $mthreads
						-n
						-u
						-T "${tdirs[-1]}/$(basename "${slice%.*}")"
						"$slice"
				CMD
					MALLOC_ARENA_MAX=4 fgbio
						-Xmx${jmem}m
						-XX:ParallelGCThreads=$jgct
						-XX:ConcGCThreads=$jcgct
						-Djava.io.tmpdir="$tmpdir"
						--async-io=true
						--log-level=Warning
						--sam-validation-stringency=SILENT
						--tmp-dir="${tdirs[-1]}"
					ClipBam
						--clipping-mode=$mode
						--read-one-five-prime=${r15:-0}
						--read-one-three-prime=${r13:-0}
						$params
						--clip-overlapping-reads=false
						-r "$genome"
						-i "/dev/stdin"
						-o "/dev/stdout"
				CMD
					samtools sort
						-@ $mthreads
						-O BAM
						-T "${tdirs[-1]}/$(basename "${slice%.*}").clipped"
						--write-index
						-o "$slice.clipped##idx##${slice%.*}.bai";
					mv "$slice.clipped" "$slice"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_clip[${_bams_clip[$i]}]}"

			o="$odir/$(basename "${_bams_clip[$i]}")"
			o="${o%.*}.clipped.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_clip["$o"]="${_bamslices_clip[${_bams_clip[$i]}]}"
			_bams_clip[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
	else
		commander::runcmd -c fgbio -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
	fi

	return 0
}

function alignment::clipmateoverlaps(){
	# must not handle supplementary i.e. circular/chimeric transcripts due to potentially uneven lists
	# if not flagged as supplementary and mate2 is mapped totally before mate1, both will be flagged as unmapped
	# fully covered by mate will be flagged as unmapped
	# default poolsize of 1Mio will consume ~1.5gb memory
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
			-u             | mark fully softclipped mate as unmapped to avoid e.g. downstream GATK BaseRecalibrator issue java.lang.IllegalStateException: cigar is completely soft-clipped
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory outdir
	declare -n _mapper_clipmateoverlaps _bamslices_clipmateoverlaps unmapped=false
	declare -A nidx tidx
	while getopts 'S:s:t:m:M:r:c:o:u' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			r)	((++mandatory)); _mapper_clipmateoverlaps=$OPTARG;;
			c)	((++mandatory)); _bamslices_clipmateoverlaps=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			u)	unmapped=true;;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 5 ]] && _usage

	commander::printinfo "clipping ends of overlapping mate pairs"

	local minstances mthreads poolsize=$((memory*1000000/1500))
	[[ $poolsize -eq 0 ]] && poolsize=1000000
	read -r minstances mthreads < <(configure::instances_by_memory -T $threads -m $memory -M "$maxmemory")

	declare -n _bams_clipmateoverlaps="${_mapper_clipmateoverlaps[0]}"
	local ithreads instances=$((${#_mapper_clipmateoverlaps[@]}*${#_bams_clipmateoverlaps[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	local m i o slice odir params
	$unmapped && params='--unmapped' || params=''

	declare -a tomerge cmd1 cmd2 cmd3
	for m in "${_mapper_clipmateoverlaps[@]}"; do
		declare -n _bams_clipmateoverlaps=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_clipmateoverlaps[@]}"; do
			tomerge=()

			while read -r slice; do
				# bamutil clips second read even full length, and by default does not produce unmapped reads
				# --unmapped marks full length clipped reads as unmapped and fixes both mates flags.
				# use stdout with bam extension to enfoce bam output
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					bam clipOverlap
						--in "$slice"
						--out -.bam
						$params
						--excludeFlags 0x0
						--poolSize $poolsize
						--stats
						--noPhoneHome
					> "$slice.mateclipped"
				CMD
				# [[ $? -le 2 ]] && true || false

				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.mateclipped" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_clipmateoverlaps[${_bams_clipmateoverlaps[$i]}]}"

			o="$odir/$(basename "${_bams_clipmateoverlaps[$i]}")"
			o="${o%.*}.mateclipped.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd3 -s ';' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_clipmateoverlaps["$o"]="${_bamslices_clipmateoverlaps[${_bams_clipmateoverlaps[$i]}]}"
			_bams_clipmateoverlaps[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -c bamutil -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
		commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::reorder(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-g <genome>    | path to
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory genome tmpdir="${TMPDIR:-/tmp}" outdir i
	declare -n _mapper_reorder _bamslices_reorder
	declare -A nidx tidx
	while getopts 'S:s:t:g:m:M:r:c:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			r)	((++mandatory)); _mapper_reorder=$OPTARG;;
			c)	((++mandatory)); _bamslices_reorder=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 7 ]] && _usage

	commander::printinfo "reordering alignments"

	local minstances mthreads jmem jgct jcgct
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")
	declare -n _bams_reorder="${_mapper_reorder[0]}"
	local ithreads instances=$((${#_mapper_reorder[@]}*${#_bams_reorder[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	local m i o slice odir
	declare -a tdirs tomerge cmd1 cmd2 cmd3
	for m in "${_mapper_reorder[@]}"; do
		declare -n _bams_reorder=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_reorder[@]}"; do
			tomerge=()

			while read -r slice; do
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.reorder)")

				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					MALLOC_ARENA_MAX=4 picard
						-Xmx${jmem}m
						-XX:ParallelGCThreads=$jgct
						-XX:ConcGCThreads=$jcgct
						-Djava.io.tmpdir="$tmpdir"
						ReorderSam
						I="$slice"
						O="$slice.ordered"
						SD="$genome"
						TMP_DIR="${tdirs[-1]}"
						VALIDATION_STRINGENCY=SILENT
						VERBOSITY=WARNING
				CMD

				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.ordered" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD
				# SD (former R) accepts fasta, bam, dict

				tomerge+=("$slice")
			done < "${_bamslices_reorder[${_bams_reorder[$i]}]}"

			o="$odir/$(basename "${_bams_reorder[$i]}")"
			o="${o%.*}.ordered.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_reorder["$o"]="${_bamslices_reorder[${_bams_reorder[$i]}]}"
			_bams_reorder[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -c picard -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
		commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::addreadgroup(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-n <readgroup> | name
			-r <mapper>    | array of sorted, indexed bams within array of
			-1 <normalidx> | array of (requieres -2)
			-2 <tumoridx>  | array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory tmpdir="${TMPDIR:-/tmp}" outdir i readgroup
	declare -n _mapper_addreadgroup _bamslices_addreadgroup _nidx_addreadgroup _tidx_addreadgroup
	declare -A nidx tidx
	while getopts 'S:s:t:m:M:n:r:1:2:c:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			n)	readgroup=$OPTARG;;
			r)	((++mandatory)); _mapper_addreadgroup=$OPTARG;;
			1)	_nidx_addreadgroup=$OPTARG;;
			2)	_tidx_addreadgroup=$OPTARG;;
			c)	((++mandatory)); _bamslices_addreadgroup=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 5 ]] && _usage

	if [[ ! $_nidx_addreadgroup ]]; then
		declare -n _bams_addreadgroup="${_mapper_addreadgroup[0]}"
		for i in "${!_bams_addreadgroup[@]}"; do
			nidx[$i]=1
		done
	else
		[[ ! $_tidx_addreadgroup ]] && _usage
		for i in "${!_nidx_addreadgroup[@]}"; do
			nidx[$i]=1
		done
		for i in "${!_tidx_addreadgroup[@]}"; do
			tidx[$i]=1
		done
	fi

	commander::printinfo "replacing read group tags"

	local minstances mthreads jmem jgct jcgct
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")
	declare -n _bams_addreadgroup="${_mapper_addreadgroup[0]}"
	local ithreads instances=$((${#_mapper_addreadgroup[@]}*${#_bams_addreadgroup[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	local m i o rgprefix slice odir
	declare -a tdirs tomerge cmd1 cmd2 cmd3
	for m in "${_mapper_addreadgroup[@]}"; do
		declare -n _bams_addreadgroup=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_addreadgroup[@]}"; do
			if [[ $readgroup ]]; then
				rgprefix=$readgroup
			else
				[[ ${nidx[$i]} ]] && rgprefix=NORMAL || rgprefix=TUMOR
			fi

			tomerge=()
			o="$(basename "${_bams_addreadgroup[$i]}")"
			o="${o%.*}"
			while read -r slice; do
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.addreadgroup)")

				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					MALLOC_ARENA_MAX=4 picard
						-Xmx${jmem}m
						-XX:ParallelGCThreads=$jgct
						-XX:ConcGCThreads=$jcgct
						-Djava.io.tmpdir="$tmpdir"
						AddOrReplaceReadGroups
						I="$slice"
						O="$slice.rg"
						RGID=${rgprefix}id
						RGLB=${rgprefix}lib
						RGPL=illumina
						RGPU=${rgprefix}unit
						RGSM=${rgprefix}
						TMP_DIR="${tdirs[-1]}"
						VALIDATION_STRINGENCY=SILENT
						VERBOSITY=WARNING
				CMD

				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.rg" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_addreadgroup[${_bams_addreadgroup[$i]}]}"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd3 -s ';' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$odir/$o.rg.bam##idx##$odir/$o.rg.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD
			_bamslices_addreadgroup["$odir/$o.rg.bam"]="${_bamslices_addreadgroup[${_bams_addreadgroup[$i]}]}"
			_bams_addreadgroup[$i]="$odir/$o.rg.bam"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -c picard -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
		commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::splitncigar(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-g <genome>    | path to
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory genome tmpdir="${TMPDIR:-/tmp}" outdir i
	declare -n _mapper_splitncigar _bamslices_splitncigar
	declare -A nidx tidx
	while getopts 'S:s:t:g:m:M:r:1:2:c:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			r)	((++mandatory)); _mapper_splitncigar=$OPTARG;;
			c)	((++mandatory)); _bamslices_splitncigar=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 6 ]] && _usage

	commander::printinfo "splitting N-cigar alignments"

	local minstances mthreads jmem jgct jcgct
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")

	declare -n _bams_splitncigar="${_mapper_splitncigar[0]}"
	local ithreads instances=$((${#_mapper_splitncigar[@]}*${#_bams_splitncigar[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	local m i o slice odir
	declare -a tdirs tomerge cmd1 cmd2 cmd3
	for m in "${_mapper_splitncigar[@]}"; do
		declare -n _bams_splitncigar=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_splitncigar[@]}"; do
			tomerge=()

			# v3.X ReassignOneMappingQuality: e.g. misused 255 as unique flag to 60
			# -rf ReassignOneMappingQuality -RMQF 255 -RMQT 60
			# v4.X does it automatically for 255, but better do it via STAR parameter outSAMmapqUnique
			# ALLOW_N_CIGAR_READS removed
			# maybe test later: --read-filter NonChimericOriginalAlignmentReadFilter
			# 					--read-filter MappingQualityReadFilter --minimum-mapping-quality 0
			# only for FR-PE data else produces empty file!	--read-filter MateDifferentStrandReadFilter
			while read -r slice; do
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.gatk)")
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					MALLOC_ARENA_MAX=4 gatk
						--java-options '
							-Xmx${jmem}m
							-XX:ParallelGCThreads=$jgct
							-XX:ConcGCThreads=$jcgct
							-Djava.io.tmpdir="$tmpdir"
						'
						SplitNCigarReads
						-I "$slice"
						-O "$slice.nsplit"
						-R "$genome"
						--process-secondary-alignments true
						-verbosity ERROR
						--tmp-dir "${tdirs[-1]}"
				CMD

				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.nsplit" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_splitncigar[${_bams_splitncigar[$i]}]}"

			o="$odir/$(basename "${_bams_splitncigar[$i]}")"
			o="${o%.*}.nsplit.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_splitncigar["$o"]="${_bamslices_splitncigar[${_bams_splitncigar[$i]}]}"
			_bams_splitncigar[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -c gatk -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
		commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::soft2hardclip(){
	# does not handle secondary and supplementary alignments
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory outdir tmpdir="${TMPDIR:-/tmp}"
	declare -n _mapper_soft2hardclip _bamslices_soft2hardclip
	declare -A nidx tidx
	while getopts 'S:s:t:m:M:r:c:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			r)	((++mandatory)); _mapper_soft2hardclip=$OPTARG;;
			c)	((++mandatory)); _bamslices_soft2hardclip=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 5 ]] && _usage

	commander::printinfo "convertig soft clipped based to hard clipped bases"


	local minstances mthreads jmem jgct jcgct
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")
	declare -n _bams_soft2hardclip="${_mapper_soft2hardclip[0]}"
	local ithreads instances=$((${#_mapper_soft2hardclip[@]}*${#_bams_soft2hardclip[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	local m i o slice odir
	declare -a tdirs tomerge cmd1 cmd2 cmd3
	for m in "${_mapper_soft2hardclip[@]}"; do
		declare -n _bams_soft2hardclip=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_soft2hardclip[@]}"; do
			tomerge=()

			while read -r slice; do
				# --upgrade-clipping=true updates softclipped sites to hard clipped ones (or vice versa) prior to do any other (optional) operation

				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.fgbio)")
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					MALLOC_ARENA_MAX=4 fgbio
						-Xmx${jmem}m
						-XX:ParallelGCThreads=$jgct
						-XX:ConcGCThreads=$jcgct
						-Djava.io.tmpdir="$tmpdir"
						--async-io=true
						--log-level=Warning
						--sam-validation-stringency=SILENT
						--tmp-dir="${tdirs[-1]}"
					ClipBam
						--clipping-mode=Hard
						--upgrade-clipping=true
						-i "$slice"
						-o "$slice.hardclipped"
				CMD

				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.hardclipped" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_soft2hardclip[${_bams_soft2hardclip[$i]}]}"

			o="$odir/$(basename "${_bams_soft2hardclip[$i]}")"
			o="${o%.*}.hardclipped.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_soft2hardclip["$o"]="${_bamslices_soft2hardclip[${_bams_soft2hardclip[$i]}]}"
			_bams_soft2hardclip[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -c fgbio -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
		commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::leftalign(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-g <genome>    | path to
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory genome tmpdir="${TMPDIR:-/tmp}" outdir i
	declare -n _mapper_leftalign _bamslices_leftalign
	declare -A nidx tidx
	while getopts 'S:s:t:g:m:M:r:1:2:c:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			r)	((++mandatory)); _mapper_leftalign=$OPTARG;;
			c)	((++mandatory)); _bamslices_leftalign=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 6 ]] && _usage

	commander::printinfo "leftaligning alignments"

	local minstances mthreads jmem jgct jcgct
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")

	declare -n _bams_leftalign="${_mapper_leftalign[0]}"
	local ithreads instances=$((${#_mapper_leftalign[@]}*${#_bams_leftalign[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads)

	local m i o slice odir
	declare -a tdirs tomerge cmd1 cmd2 cmd3
	for m in "${_mapper_leftalign[@]}"; do
		declare -n _bams_leftalign=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_leftalign[@]}"; do
			tomerge=()

			while read -r slice; do
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.gatk)")

				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD {COMMANDER[2]}<<- CMD
					samtools reheader --no-PG -c "sed -E 's/\tSO:.+/\tSO:undefined/'" "$slice" > "$slice.reheader"
				CMD
					mv "$slice.reheader" "$slice"
				CMD
					MALLOC_ARENA_MAX=4 gatk
						--java-options '
								-Xmx${jmem}m
								-XX:ParallelGCThreads=$jgct
								-XX:ConcGCThreads=$jcgct
								-Djava.io.tmpdir="$tmpdir"
							'
						LeftAlignIndels
						-I "$slice"
						-O "$slice.leftaln"
						-R "$genome"
						-verbosity ERROR
						--tmp-dir "${tdirs[-1]}"
				CMD

				commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					samtools sort
						-@ $ithreads
						-O BAM
						-T "${tdirs[-1]}/$(basename "${slice%.*}")"
						--write-index
						-o "$slice##idx##${slice%.*}.bai"
						"$slice.leftaln"
				CMD
					rm -f "$slice.leftaln"
				CMD
				# leftalign indel has a major issue if pos is incremented due to e.g. softclippings (as introduced by RNA-Seq itself, splitNcigar or clipoverlaps)
				# and file is coordinate sorted (sam header SO)
				# aln1: pos 100 cig 1M1=1D40= -> pos 101 2S40=
 				# aln2: pos 100 cig 20= -> pos 100 20= <- out of order !!

				tomerge+=("$slice")
			done < "${_bamslices_leftalign[${_bams_leftalign[$i]}]}"

			o="$odir/$(basename "${_bams_leftalign[$i]}")"
			o="${o%.*}.leftaln.bam"

			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd3 -s '|' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_leftalign["$o"]="${_bamslices_leftalign[${_bams_leftalign[$i]}]}"
			_bams_leftalign[$i]="$o"
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -c gatk -v -b -i $minstances -a cmd1
		commander::runcmd -v -b -i $instances -a cmd2
		commander::runcmd -v -b -i $instances -a cmd3
	fi

	return 0
}

function alignment::bqsr(){
	function _usage(){
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[-2]} usage:
			-S <hardskip>  | true/false return
			-s <softskip>  | true/false only print commands
			-t <threads>   | number of
			-g <genome>    | path to
			-d <dbsnp>     | path to
			-m <memory>    | amount of
			-M <maxmemory> | amount of
			-r <mapper>    | array of sorted, indexed bams within array of
			-c <sliceinfo> | array of
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads memory maxmemory genome dbsnp tmpdir="${TMPDIR:-/tmp}" outdir i
	declare -n _mapper_bqsr _bamslices_bqsr
	declare -A nidx tidx
	while getopts 'S:s:t:g:d:m:M:r:1:2:c:o:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	((++mandatory)); memory=$OPTARG;;
			M)	maxmemory=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			d)	dbsnp="$OPTARG";;
			r)	((++mandatory)); _mapper_bqsr=$OPTARG;;
			c)	((++mandatory)); _bamslices_bqsr=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			*)	_usage;;
		esac
	done
	[[ $# -eq 0 ]] && { _usage || return 0; }
	[[ $mandatory -lt 6 ]] && _usage

	if [[ ! $dbsnp ]]; then
		local tmpfile="$(mktemp -p "$tmpdir" cleanup.XXXXXXXXXX.vcf)"
		dbsnp="$tmpfile"
		echo -e "##fileformat=VCFv4.0\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO" > "$dbsnp"
		bgzip -k -c -@ $threads "$dbsnp" > "$dbsnp.gz"
		tabix -f -p vcf "$dbsnp.gz"
		dbsnp="$dbsnp.gz"
	fi

	commander::printinfo "base quality score recalibration"

	local minstances mthreads jmem jgct jcgct minstances2 mthreads2 jmem2 jgct2 jcgct2
	read -r minstances mthreads jmem jgct jcgct < <(configure::jvm -T $threads -m $memory -M "$maxmemory")

	declare -n _bams_bqsr="${_mapper_bqsr[0]}"
	local ithreads instances=$((${#_mapper_bqsr[@]}*${#_bams_bqsr[@]}))
	read -r minstances2 mthreads2 jmem2 jgct2 jcgct2 < <(configure::jvm -i $instances -T $threads -M "$maxmemory") # for gatk simple tasks like gathering
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -t 10 -T $threads) # for samtools

	local m i o slice odir params
	[[ -s "$genome.InDel_gold.vcf.gz" ]] && params="--known-sites '$dbsnp' --known-sites '$genome.InDel_gold.vcf.gz'" || params="--known-sites '$dbsnp'"

	declare -a reportfile tdirs tomerge cmd1 cmd2 cmd3 cmd4 cmd5
	for m in "${_mapper_bqsr[@]}"; do
		declare -n _bams_bqsr=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for i in "${!_bams_bqsr[@]}"; do
			tomerge=()

			reportfile="$(mktemp -p "$tmpdir" cleanup.XXXXXXXXXX.bqsreport)"

			while read -r slice; do
				# https://gatkforums.broadinstitute.org/gatk/discussion/7131/is-indel-realignment-removed-from-gatk4
				# https://software.broadinstitute.org/gatk/blog?id=7847
				#
				# known polymorphic sites used to exclude regions around
				# https://gatkforums.broadinstitute.org/gatk/discussion/1247/what-should-i-use-as-known-variants-sites-for-running-tool-x
				# gatk known-sites bundle: https://software.broadinstitute.org/gatk/documentation/article.php?id=1213
				#
				# BaseRecalibratorSpark with --spark-master local[$mthreads] is BETA!!
				# --bqsr-baq-gap-open-penalty (Phred Scaled) Default value is 40. 30 is perhaps better for whole genome call sets
				# ApplyBQSRSpark fails as of v4.1.2.0
				# -> i.e. also true for BQSRPipelineSpark which does both steps in one
				# GatherBQSRReports - Gathers scattered BQSR recalibration reports into a single file
				#
				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.gatk)")
				commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD
					MALLOC_ARENA_MAX=4 gatk
						--java-options '
								-Xmx${jmem}m
								-XX:ParallelGCThreads=$jgct
								-XX:ConcGCThreads=$jcgct
								-Djava.io.tmpdir="$tmpdir"
							'
						BaseRecalibrator
						-R "$genome"
						$params
						-I "$slice"
						-O "$slice.bqsreport"
						-verbosity ERROR
						--tmp-dir "${tdirs[-1]}"
				CMD

				tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.gatk)")
				commander::makecmd -a cmd3 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					rm -rf "$slice.bqsr.parts"
				CMD
					MALLOC_ARENA_MAX=4 gatk
						--java-options '
								-Xmx${jmem}m
								-XX:ParallelGCThreads=$jgct
								-XX:ConcGCThreads=$jcgct
								-Djava.io.tmpdir="$tmpdir"
							'
						ApplyBQSR
						-bqsr "$reportfile"
						-I "$slice"
						-O "$slice.bqsr"
						-verbosity ERROR
						--tmp-dir "${tdirs[-1]}"
				CMD

				commander::makecmd -a cmd4 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
					mv "$slice.bqsr" "$slice"
				CMD
					samtools index -@ $ithreads "$slice" "${slice%.*}.bai"
				CMD

				tomerge+=("$slice")
			done < "${_bamslices_bqsr[${_bams_bqsr[$i]}]}"

			tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.gatk)")
			commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD
				MALLOC_ARENA_MAX=4 gatk
					--java-options '
							-Xmx${jmem2}m
							-XX:ParallelGCThreads=$jgct2
							-XX:ConcGCThreads=$jcgct2
							-Djava.io.tmpdir="$tmpdir"
						'
					GatherBQSRReports
					$(printf -- '-I "%s" ' "${tomerge[@]/%/.bqsreport}")
					-O "$reportfile"
					--tmp-dir "${tdirs[-1]}"
			CMD

			o="$odir/$(basename "${_bams_bqsr[$i]}")"
			o="${o%.*}.bqsr.bam"
			# slices have full sam header info used by merge to maintain the global sort order
			commander::makecmd -a cmd5 -s '|' -c {COMMANDER[0]}<<- CMD
				samtools merge
					-@ $ithreads
					-f
					-c
					-p
					-O BAM
					--no-PG
					--write-index
					-o "$o##idx##${o%.*}.bai"
					$(printf '"%s" ' "${tomerge[@]}")
			CMD

			_bamslices_bqsr["$o"]="${_bamslices_bqsr[${_bams_bqsr[$i]}]}"
			_bams_bqsr[$i]="$o"
		done
	done

	if $skip; then
        commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
		commander::printcmd -a cmd4
		commander::printcmd -a cmd5
	else
		commander::runcmd -c gatk -v -b -i $minstances -a cmd1
		commander::runcmd -c gatk -v -b -i $minstances2 -a cmd2
		commander::runcmd -c gatk -v -b -i $minstances -a cmd3
		commander::runcmd -v -b -i $instances -a cmd4
		commander::runcmd -v -b -i $instances -a cmd5
	fi

	return 0
}
