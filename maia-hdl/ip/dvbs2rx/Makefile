VIVADO := vivado -mode batch -source
IP_CORE_VERSION := $(shell PYTHONPATH="../../:${PYTHONPATH}" python3 -m maia_hdl.maia_sdr_version)

all: dvbs2rx

dvbs2rx:
	mkdir -p dvbs2rx
	PYTHONPATH="../../:${PYTHONPATH}" python3 -m maia_hdl.dvbs2rx generate -t v dvbs2rx/dvbs2rx.v
	cd dvbs2rx && IP_CORE_VERSION=$(IP_CORE_VERSION) $(VIVADO) ../package_ip.tcl

clean:
	rm -rf dvbs2rx

.PHONY: all clean dvbs2rx
