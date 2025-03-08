
all: reader.bin

%.bin : %.p
	@p2bin $< $@

%.p : %.s
	@asl -o $@ $<
