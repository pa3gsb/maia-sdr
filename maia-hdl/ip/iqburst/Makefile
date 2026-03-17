VIVADO := vivado -mode batch -source
IP_CORE_VERSION := $(shell PYTHONPATH="../../:${PYTHONPATH}" python3 -m maia_hdl.maia_sdr_version)

all: iqburst

iqburst:
	mkdir -p iqburst
	PYTHONPATH="../../:${PYTHONPATH}" python3 -m maia_hdl.iqburst generate -t v iqburst/iqburst.v
	cd iqburst && IP_CORE_VERSION=$(IP_CORE_VERSION) $(VIVADO) ../package_ip.tcl

clean:
	rm -rf iqburst

.PHONY: all clean iqburst
