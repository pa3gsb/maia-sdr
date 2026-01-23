# The list of projects you want to build
PROJECTS := e200 e310 fishball7010 fishball7020 libre pluto plutoplus signalsdrpro
TOPTARGETS := all clean

# This creates targets like 'all' and 'clean'
$(TOPTARGETS): $(PROJECTS)

# This rule runs for every project name in the list
$(PROJECTS):
	export PROJECT_NAME=$@; $(MAKE) -C tezuka

.PHONY: $(TOPTARGETS) $(PROJECTS)
