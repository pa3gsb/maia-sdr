TOPTARGETS := all clean

# SUBDIRS := $(filter-out $(wildcard _*/.), $(wildcard */.))
SUBDIRS := e200_iio fishball_iio fishball7020_iio libre_iio pluto_iio plutoplus_iio

$(TOPTARGETS): $(SUBDIRS)
$(SUBDIRS):
	$(MAKE) -C $@ $(MAKECMDGOALS) all

.PHONY: $(TOPTARGETS) $(SUBDIRS)
