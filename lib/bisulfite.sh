#! /usr/bin/env bash
# (c) Konstantin Riege

bisulfite::mspicut() {
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-d <length>   | maximum of diversity adapters
			-c <number>   | bases to clip from R2 start (default: 2)
			-o <outdir>   | path to
			-1 <fastq1>   | array of
			-2 <fastq2>   | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads outdir diversity=0 clip=2
	declare -n _fq1_mspicut _fq2_mspicut
	while getopts 'S:s:t:d:c:o:1:2:' arg; do
		case $arg in
			S) $OPTARG && return 0;;
			s) $OPTARG && skip=true;;
			t) ((++mandatory)); threads=$OPTARG;;
			d) diversity=$OPTARG;;
			c) clip=$OPTARG;;
			o) ((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			1) ((++mandatory)); _fq1_mspicut=$OPTARG;;
			2) _fq2_mspicut=$OPTARG;;
			*) _usage;;
		esac
	done
	[[ $mandatory -lt 3 ]] && _usage

	commander::printinfo "selecting msp1 cut reads"

	declare -a cmd1
	local i o1 o2 e1 e2
	[[ $n -gt 2 ]] && n=2 # since only the best matching adapter is removed, run cutadapt twice
	for i in "${!_fq1_mspicut[@]}"; do
		helper::basename -f "${_fq1_mspicut[$i]}" -o o1 -e e1
		e1=$(echo $e1 | cut -d '.' -f 1)
		o1="$outdir/$o1.$e1.gz"


		if [[ "${_fq2_mspicut[$i]}" ]]; then
			helper::basename -f "${_fq2_mspicut[$i]}" -o o2 -e e2
			e2=$(echo $e2 | cut -d '.' -f 1)
			o2="$outdir/$o2.$e2.gz"

			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD
				rrbsMspIselection.sh
				-t $threads
				-d $diversity
				-i "${_fq1_mspicut[$i]}"
				-j "${_fq2_mspicut[$i]}"
				-o "$o1"
				-p "$o2"
				-c $clip
			CMD
			# do not clip off 2 nt from R2 starts, it will be done by cutadapt in case of nomspi=true (required for multi enzyme digestion)
			_fq1_mspicut[$i]="$o1"
			_fq2_mspicut[$i]="$o2"
		else
			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD
				rrbsMspIselection.sh
				-t $threads
				-d $diversity
				-i "${_fq1_mspicut[$i]}"
				-o "$o1"
			CMD
			_fq1_mspicut[$i]="$o1"
		fi
	done

	if $skip; then
		commander::printcmd -a cmd1
	else
		commander::runcmd -v -b -t 1 -a cmd1
	fi

	return 0
}

bisulfite::segemehl() {
	declare -a tdirs
	_cleanup::bisulfite::segemehl(){
		rm -rf "${tdirs[@]}"
	}

	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip>   | true/false return
			-s <softskip>   | true/false only print commands
			-5 <skip>       | true/false md5sums, indexing respectively
			-t <threads>    | number of
			-a <accuracy>   | optional: 80 to 100
			-i <insertsize> | optional: 50 to 200000+
			-r <mapper>     | array of bams within array of
			-g <genome>     | path to
			-x <ctidx>      | path to
			-y <gaidx>      | path to
			-m <mode>       | lister (1), cokus (2) - default: 1
			-o <outdir>     | path to
			-p <tmpdir>     | path to
			-1 <fastq1>     | array of
			-2 <fastq2>     | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false skipmd5=false threads genome gaidx ctidx outdir tmpdir mode=1 accuracy insertsize
	declare -n _fq1_segemehl _fq2_segemehl _mapper_segemehl
	declare -g -a segemehl=()
	while getopts 'S:s:5:t:a:i:g:x:y:m:r:o:p:1:2:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			5)	$OPTARG && skipmd5=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			m)	mode=$OPTARG;;
			a)	accuracy=$OPTARG;;
			i)	insertsize=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			x)	((++mandatory)); ctidx="$OPTARG";;
			y)	((++mandatory)); gaidx="$OPTARG";;
			o)	((++mandatory)); outdir="$OPTARG/segemehl"; mkdir -p "$outdir";;
			p)	((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			r)	((++mandatory))
				_mapper_segemehl=$OPTARG
				_mapper_segemehl+=(segemehl)
			;;
			1)	((++mandatory)); _fq1_segemehl=$OPTARG;;
			2)	_fq2_segemehl=$OPTARG;;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 8 ]] && _usage

	commander::printinfo "bisufite mapping segemehl"

	if $skipmd5; then
		commander::warn "skip checking md5 sums and genome indexing respectively"
	else
		commander::printinfo "checking md5 sums"
		[[ ! -s "$genome.md5.sh" ]] && cp "$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")/md5.sh" "$genome.md5.sh"
		source "$genome.md5.sh"

		local thismd5genome thismd5segemehlbs
		thismd5genome=$(md5sum "$genome" | cut -d ' ' -f 1)
		[[ -s "$ctidx" ]] && thismd5segemehlbs=$(md5sum "$ctidx" | cut -d ' ' -f 1)
		if [[ "$thismd5genome" != "$md5genome" || ! "$thismd5segemehlbs" || "$thismd5segemehlbs" != "$md5segemehlbs" ]]; then
			commander::printinfo "indexing genome for segemehl bisulfite mode"
			declare -a cmdidx
			# lister/cokus mode use the same index, thus it does not matter if indexed with -F 1 or -F 2
			commander::makecmd -a cmdidx -s '|' -c {COMMANDER[0]}<<- CMD
				segemehl -F 1 -x "$ctidx" -y "$gaidx" -d "$genome"
			CMD
			commander::runcmd -v -b -t $threads -a cmdidx
			commander::printinfo "updating md5 sums"
			thismd5segemehlbs=$(md5sum "$ctidx" | cut -d ' ' -f 1)
			sed -i "s/md5segemehlbs=.*/md5segemehlbs=$thismd5segemehlbs/" $genome.md5.sh
		fi
	fi

	declare -a cmd1
	local o e params
	for i in "${!_fq1_segemehl[@]}"; do
		helper::basename -f "${_fq1_segemehl[$i]}" -o o -e e
		o="$outdir/$o"
		params=""
		[[ $accuracy ]] && params+=" -A $accuracy"
		tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.segemehl)")
		if [[ ${_fq2_segemehl[$i]} ]]; then
			[[ $insertsize ]] && params+=" -I $insertsize"
			commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
				cd "${tdirs[-1]}"
			CMD
				segemehl
				$params
				-F $mode
				-i "$ctidx"
				-j "$gaidx"
				-d "$genome"
				-q "${_fq1_segemehl[$i]}"
				-p "${_fq2_segemehl[$i]}"
				-t $threads
				-b
				-o "$o.bam"
			CMD
		else
			commander::makecmd -a cmd1 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
				cd "${tdirs[-1]}"
			CMD
				segemehl
				$params
				-F $mode
				-i "$ctidx"
				-j "$gaidx"
				-d "$genome"
				-q "${_fq1_segemehl[$i]}"
				-t $threads
				-b
				-o "$o.bam"
			CMD
		fi
		segemehl+=("$o.bam")
	done

	if $skip; then
		commander::printcmd -a cmd1
	else
		commander::runcmd -v -b -t 1 -a cmd1
	fi

	return 0
}

bisulfite::bwa() {
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip>   | true/false return
			-s <softskip>   | true/false only print commands
			-5 <skip>       | true/false md5sums, indexing respectively
			-t <threads>    | number of
			-r <mapper>     | array of bams within array of
			-g <genome>     | path to
			-o <outdir>     | path to
			-1 <fastq1>     | array of
			-2 <fastq2>     | array of
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false skipmd5=false threads genome outdir
	declare -n _fq1_bwa _fq2_bwa _mapper_bwa
	declare -g -a bwa=()
	while getopts 'S:s:5:t:a:i:g:m:r:o:p:1:2:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			5)	$OPTARG && skipmd5=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			o)	((++mandatory)); outdir="$OPTARG/bwa"; mkdir -p "$outdir";;
			r)	((++mandatory))
				_mapper_bwa=$OPTARG
				_mapper_bwa+=(bwa)
			;;
			1)	((++mandatory)); _fq1_bwa=$OPTARG;;
			2)	_fq2_bwa=$OPTARG;;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 5 ]] && _usage

	commander::printinfo "bisufite mapping bwa"

	if $skipmd5; then
		commander::warn "skip checking md5 sums and genome indexing respectively"
	else
		commander::printinfo "checking md5 sums"
		[[ ! -s "$genome.md5.sh" ]] && cp "$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")/md5.sh" "$genome.md5.sh"
		source "$genome.md5.sh"

		local thismd5genome thismd5bwameth
		thismd5genome=$(md5sum "$genome" | cut -d ' ' -f 1)
		[[ -s "$genome.bwameth.c2t.pac" ]] && thismd5bwameth=$(md5sum "$genome.bwameth.c2t.pac" | cut -d ' ' -f 1)
		if [[ "$thismd5genome" != "$md5genome" || ! "$thismd5bwameth" || "$thismd5bwameth" != "$md5bwameth" ]]; then
			commander::printinfo "indexing genome for bwameth"
			declare -a cmdidx
			commander::makecmd -a cmdidx -s ';' -c {COMMANDER[0]}<<- CMD
				bwameth.py index-mem2 "$genome"
			CMD
			commander::runcmd -c bwameth -v -b -t $threads -a cmdidx
			commander::printinfo "updating md5 sums"
			thismd5bwameth=$(md5sum "$genome.bwameth.c2t.pac" | cut -d ' ' -f 1)
			sed -i "s/md5bwameth=.*/md5bwameth=$thismd5bwameth/" "$genome.md5.sh"
		fi
	fi

	declare -a cmd1
	local o e
	for i in "${!_fq1_bwa[@]}"; do
		helper::basename -f "${_fq1_bwa[$i]}" -o o -e e
		o="$outdir/$o"

		if [[ ${_fq2_bwa[$i]} ]]; then
			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- 'CMD' {COMMANDER[2]}<<- CMD
				bwameth.py
					--do-not-penalize-chimeras
					--read-group '@RG\tID:A1\tSM:sample1\tLB:library1\tPU:unit1\tPL:illumina'
					--threads $threads
					--reference "$genome"
					"${_fq1_bwa[$i]}" "${_fq2_bwa[$i]}"
			CMD
				sed -E ':a; s/(\s[SX]A:Z\S*[:;])[fr]/\1/; t a'
			CMD
				samtools view -@ $threads -b > "$o.bam"
			CMD
			# sed corrects SA and XA tags, which bwameth does not change back from c2t (f+r) chromosomes i.e. (f|r)chr to chr
		else
			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- 'CMD' {COMMANDER[2]}<<- CMD
				bwameth.py
					--do-not-penalize-chimeras
					--read-group '@RG\tID:A1\tSM:sample1\tLB:library1\tPU:unit1\tPL:illumina'
					--threads $threads
					--reference "$genome"
					"${_fq1_bwa[$i]}"
			CMD
				sed -E ':a; s/(\s[SX]A:Z\S*[:;])[fr]/\1/; t a'
			CMD
				samtools view -@ $threads -b > "$o.bam"
			CMD
		fi
		bwa+=("$o.bam")
	done

	if $skip; then
		commander::printcmd -a cmd1
	else
		commander::runcmd -c bwameth -v -b -t 1 -a cmd1
	fi

	return 0
}

bisulfite::mecall(){
	declare -a tdirs
	_cleanup::bisulfite::mecall(){
		rm -rf "${tdirs[@]}"
	}

	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip> | true/false return
			-s <softskip> | true/false only print commands
			-t <threads>  | number of
			-g <genome>   | path to
			-x <context>  | Cp* base - default: CG
			-r <mapper>   | array of bams within array of
			-o <outdir>   | path to
			-p <tmpdir>   | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads genome outdir tmpdir context=CG
	declare -n _mapper_haarz
	while getopts 'S:s:t:m:r:g:x:o:p:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			g)	((++mandatory)); genome="$OPTARG";;
			x)	context=$OPTARG;;
			r)	((++mandatory)); _mapper_haarz=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			p)	((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 5 ]] && _usage

	commander::printinfo "calling methylated sites"

	declare -n _bams_haarz=${_mapper_haarz[0]}
	local ithreads imemory instances=$((${#_bams_haarz[@]}*${#_mapper_haarz[@]}))
	read -r instances ithreads < <(configure::instances_by_threads -i $instances -T $threads)
	read -r instances imemory < <(configure::memory_by_instances -i $instances -T $threads)

	local m f o odir
	for m in "${_mapper_haarz[@]}"; do
		declare -n _bams_haarz=$m
		odir="$outdir/$m"
		mkdir -p "$odir"

		for f in "${_bams_haarz[@]}"; do
			o=$(basename $f)
			o=${o%.*}

			tdirs+=("$(mktemp -d -p "$tmpdir" cleanup.XXXXXXXXXX.haarz)")

			commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
				haarz callmethyl -t $threads -d $genome -b "$f"
			CMD
				bgzip -f -@ $threads > "${tdirs[-1]}/$o.vcf.gz"
			CMD

			# pipe into bgzip is much faster than using bctools sort -O z
			commander::makecmd -a cmd2 -s ';' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
				bcftools sort -T "${tdirs[-1]}" -m ${imemory}M "${tdirs[-1]}/$o.vcf.gz" | bgzip -f -@ $ithreads > "$odir/$o.vcf.gz"
			CMD
				tabix -f -p vcf "$odir/$o.vcf.gz"
			CMD

			commander::makecmd -a cmd3 -s ' ' -o "$odir/$o.$context.full.bed" -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- 'CMD' {COMMANDER[2]}<<- CMD {COMMANDER[3]}<<- CMD {COMMANDER[4]}<<- 'CMD'
				bcftools view -H "$odir/$o.vcf.gz" |
			CMD
				perl -slane '
					next unless $F[7]=~/;CC=$c;/;
					$F[1]-- if $F[7]=~/^CS=-;/;
					print join"\t",($F[0],$F[1]-1,$F[1],(split/:/,$F[-1])[-3,-4,0])
				'
			CMD
				-- -c=$context |
			CMD
				bedtools merge -d -1 -c 4,5,6 -o sum,sum,max |
			CMD
				perl -lane 'print join"\t",(@F[0..2],$F[3]/$F[4],$F[5])'
			CMD

			commander::makecmd -a cmd4 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
				awk '\$NF>=10' "$odir/$o.$context.full.bed"
			CMD
				cut -f 1-4 > "$odir/$o.$context.bed"
			CMD
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
		commander::printcmd -a cmd4
	else
		commander::runcmd -v -b -t 1 -a cmd1
		commander::runcmd -v -b -t $instances -a cmd2
		commander::runcmd -v -b -t $threads -a cmd3
		commander::runcmd -v -b -t $threads -a cmd4
	fi

	return 0
}

bisulfite::metilene(){
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-S <hardskip>   | true/false return
			-s <softskip>   | true/false only print commands
			-t <threads>    | number of
			-c <cmpfiles>   | array of
			-m <minimum>    | values present in control and treatment samples as fraction or absolute number - default: 0.8
			-u <upperbound> | values present in control and treatment samples as absolute number (see -m) - default: not capped
			-x <context>    | bases - default: CG
			-r <mapper>     | array of bams within array of
			-i <methdir>    | path to
			-o <outdir>     | path to
			-p <tmpdir>     | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory skip=false threads genome mecalldir outdir tmpdir min=0.8 cap=999999 context=CG
	declare -n _mapper_metilene _cmpfiles_metilene
	while getopts 'S:s:t:c:m:u:x:r:i:o:p:' arg; do
		case $arg in
			S)	$OPTARG && return 0;;
			s)	$OPTARG && skip=true;;
			t)	((++mandatory)); threads=$OPTARG;;
			c)	((++mandatory)); _cmpfiles_metilene=$OPTARG;;
			m)	min=$OPTARG;;
			u)	cap=$OPTARG;;
			x)	context=$OPTARG;;
			r)	((++mandatory)); _mapper_metilene=$OPTARG;;
			i)	((++mandatory)); mecalldir="$OPTARG";;
			o)	((++mandatory)); outdir="$OPTARG"; mkdir -p "$outdir";;
			p)	((++mandatory)); tmpdir="$OPTARG"; mkdir -p "$tmpdir";;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 6 ]] && _usage

	commander::printinfo "differential methylation analyses"

	declare -a cmd1 cmd2 cmd3 mapdata

	local m f i c t odir sample condition library replicate factors crep trep
	for m in "${_mapper_metilene[@]}"; do
		odir="$outdir/$m"
		mkdir -p "$odir"

		for f in "${_cmpfiles_metilene[@]}"; do
			mapfile -t mapdata < <(cut -d $'\t' -f 2 $f | uniq)
			i=0
			for c in "${mapdata[@]::${#mapdata[@]}-1}"; do
				crep=$(awk -v s=$c -v n=$min '$2==s{i=i+1}END{if(n>1){if(i<n){n=i} print n}else{printf "%0.f", i*n}}' "$f")
				[[ $crep -gt $cap ]] && crep=$cap

				for t in "${mapdata[@]:$((++i)):${#mapdata[@]}}"; do
					odir="$outdir/$m/$c-vs-$t"
					mkdir -p "$odir"
					tomerge=()
					header="chr sta pos"
					trep=$(awk -v s=$t -v n=$min '$2==s{i=i+1}END{if(n>1){if(i<n){n=i} print n}else{printf "%0.f", i*n}}' "$f")
					[[ $trep -gt $cap ]] && trep=$cap

					unset sample condition library replicate factors
					while read -r sample condition library replicate factors; do
						tomerge+=("$(readlink -e "$mecalldir/$m/$sample"*.$context.bed | head -1)")
						header+=" ${condition}_$replicate"
					done < <(awk -v c=$c '$2==c' "$f" | sort -k4,4V && awk -v t=$t '$2==t' "$f" | sort -k4,4V)

					commander::makecmd -a cmd1 -s '|' -c {COMMANDER[0]}<<- CMD {COMMANDER[1]}<<- CMD
						{	sed 's/ /\t/g' <<< "$header";
							bedtools unionbedg
								-filler .
								-i $(printf '"%s" ' "${tomerge[@]}");
						}
					CMD
						cut -f 1,3- > $odir/merates.bedg
					CMD

					bisulfite::_metilene \
						-1 cmd2 \
						-2 cmd3 \
						-t $threads \
						-i "$odir/merates.bedg" \
						-a $c \
						-b $t \
						-x $crep \
						-y $trep \
						-o "$odir"
				done
			done
		done
	done

	if $skip; then
		commander::printcmd -a cmd1
		commander::printcmd -a cmd2
		commander::printcmd -a cmd3
	else
		commander::runcmd -v -b -t $threads -a cmd1
		commander::runcmd -c metilene -v -b -t 1 -a cmd2
		commander::runcmd -v -b -t $threads -a cmd3
	fi

	return 0
}

bisulfite::_metilene(){
	_usage() {
		commander::print {COMMANDER[0]}<<- EOF
			${FUNCNAME[1]} usage:
			-1 <cmds1>     | array of
			-2 <cmds2>     | array of
			-t <threads>   | number of
			-i <inmerates> | path to bedgraph
			-a <condition> | name of control
			-b <condition> | name of treatment
			-x <minimum>   | of -a values
			-y <minimum>   | of -b values
			-d <distance>  | for CpGs within DMR maximum - default: 300
			-o <outdir>    | path to
		EOF
		return 1
	}

	local OPTIND arg mandatory threads merates gtf outdir gtfinfo c t crep trep distance=300
	declare -n _cmds1_metilene _cmds2_metilene
	while getopts '1:2:t:i:a:b:x:y:d:o:' arg; do
		case $arg in
			1)	((++mandatory)); _cmds1_metilene=$OPTARG;;
			2)	((++mandatory)); _cmds2_metilene=$OPTARG;;
			t)	((++mandatory)); threads=$OPTARG;;
			i)	((++mandatory)); merates="$OPTARG";;
			a)	((++mandatory)); c=$OPTARG;;
			b)	((++mandatory)); t=$OPTARG;;
			x)	crep=$OPTARG;;
			y)	trep=$OPTARG;;
			d)	distance=$OPTARG;;
			o)	((++mandatory)); outdir="$OPTARG";;
			*)	_usage;;
		esac
	done
	[[ $mandatory -lt 7 ]] && _usage

	local params=''
	# this is the default behaviour of allowing for missing values
	[[ $crep ]] && params+=" -X $crep"
	[[ $trep ]] && params+=" -Y $trep"

	local header="chr start stop q-value mean_$c-mean_$t CpGs p-value_MWU p-value_2DKS mean_$c mean_$t"
	commander::makecmd -a _cmds1_metilene -s ';' -c {COMMANDER[0]}<<- CMD
		{	sed 's/ /\t/g' <<< "$header";
			metilene
				$params
				-t $threads
				-m 8
				-M $distance
				-a $c
				-b $t
				"$merates";
		} > "$outdir/dmr.full.tsv"
	CMD

	commander::makecmd -a _cmds2_metilene -s ';' -c {COMMANDER[0]}<<- CMD
		awk '\$4=="q-value" || \$4<=0.05' "$outdir/dmr.full.tsv" > "$outdir/dmr.tsv"
	CMD

	return 0
}
