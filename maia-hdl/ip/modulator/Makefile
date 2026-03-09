VIVADO := vivado -mode batch -source
IP_CORE_VERSION := $(shell PYTHONPATH="../../:${PYTHONPATH}" python3 -m maia_hdl.maia_sdr_version)

all: modulator

modulator:
	mkdir -p modulator
	PYTHONPATH="../../:${PYTHONPATH}" python3 -m maia_hdl.modulator generate -t v modulator/modulator.v
	cd modulator && IP_CORE_VERSION=$(IP_CORE_VERSION) $(VIVADO) ../package_ip.tcl

clean:
	rm -rf modulator

.PHONY: all clean modulator
