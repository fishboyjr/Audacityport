# Host build of the portable C DSP core + unit tests (Linux/macOS).
CC      ?= cc
CFLAGS  ?= -O2 -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Wpedantic -Werror
DSP_SRC := $(wildcard Sources/AudioDSP/*.c)
BUILD   := .build-host

.PHONY: test clean
test: $(BUILD)/test_dsp
	./$(BUILD)/test_dsp

$(BUILD)/test_dsp: $(DSP_SRC) Tests/AudioDSPTests/test_dsp.c Sources/AudioDSP/include/AudioDSP.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -ISources/AudioDSP/include $(DSP_SRC) Tests/AudioDSPTests/test_dsp.c -lm -o $@

clean:
	rm -rf $(BUILD)
