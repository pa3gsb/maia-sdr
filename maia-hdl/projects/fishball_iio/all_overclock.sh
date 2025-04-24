PATH_OVERCLOCK=/home/hp-z2-dev/prog/tezuka_fw/board/fishball/bitstream/overclock
PATH_BITSTREAM=/home/hp-z2-dev/prog/tezuka_fw/buildroot-fish/output/images

make fsbl
#Standard
./overclock.sh 40 32
./overclock.sh 58 36
./overclock.sh 64 36
#Need 11 8 11 11
./overclock.sh 62 48



