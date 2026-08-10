.PHONY: clean patch-dvb_fpga

clean:
	make -C adi-hdl clean
	make -C ip clean
	make -C projects clean
	make -C test_cocotb clean

# Local modifications to the dvb_fpga submodule are kept as a patch here
# instead of committed inside it, since we don't have push access to
# https://github.com/OpenResearchInstitute/dvb_fpga. Run this after
# `git submodule update --init dvb_fpga` (or whenever dvb_fpga gets reset
# back to the pinned upstream commit).
patch-dvb_fpga:
	@git -C dvb_fpga apply --reverse --check ../patches/dvb_fpga/padding_ok.patch 2>/dev/null && \
	  echo "dvb_fpga: padding_ok.patch already applied" || \
	  git -C dvb_fpga apply ../patches/dvb_fpga/padding_ok.patch
