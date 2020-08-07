#! /usr/bin/env bash
# (c) Konstantin Riege

die() {
	echo ":ERROR: $*" >&2
	exit 1
}

source $(dirname $(readlink -e $0))/activate.sh -c false || die

trap 'configure::exit -p $$' EXIT
trap 'die "killed"' INT TERM

THREADS=$(cat /proc/cpuinfo | grep -cF processor)
VERBOSITY=0

options::parse "$@" || die "parameterization issue"

[[ $INSTALL ]] || die "mandatory parameter -i missing"
[[ $INSDIR ]] || die "mandatory parameter -d missing"

mkdir -p $INSDIR || die "cannot access $INSDIR"
INSDIR=$(readlink -e $INSDIR)
[[ $LOG ]] || LOG=$INSDIR/install.log
printf '' > $LOG || die "cannot access $LOG"

progress::log -v $VERBOSITY -o $LOG
commander::printinfo "installation started. please be patient." >> $LOG

for i in "${INSTALL[@]}"; do
	compile::$i -i $INSDIR -t $THREADS 2> >(tee -ai $LOG >&2) >> $LOG || die
done

commander::printinfo "success" >> $LOG
exit 0
