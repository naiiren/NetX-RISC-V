BUILD_DIR := build
TARGET := $(BUILD_DIR)/rv32i_test

TEST ?= gcd

.PHONY: all run raw custom fpga fpga-system fpga-verilog fpga-verilog-system clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): main.cpp | $(BUILD_DIR)
	c++ -O3 -ffast-math -march=native -std=c++23 -o $@ $<

run: all custom
	nx compile _netx.toml --top CORE --minimal --output compiled.json
	cat compiled.json | $(TARGET)
	cat compiled.json | $(TARGET) --dir custom_cases
	rm compiled.json

raw: all custom
	nx compile _netx.toml --top CORE --minimal --output compiled.json
	cat compiled.json | $(TARGET) --no-native
	cat compiled.json | $(TARGET) --no-native --dir custom_cases
	rm compiled.json

debug: all custom
	nx compile _netx.toml --top CORE --minimal --output compiled.json
	cat compiled.json | $(TARGET) --trace
	cat compiled.json | $(TARGET) --trace --dir custom_cases
	rm compiled.json

custom:
	bash ./scripts/build_tests.sh

fpga:
	bash ./scripts/build_tests.sh $(TEST)
	bash ./scripts/fpga_flow.sh core $(TEST)

fpga-system:
	mkdir -p fpga_cases
	OUT_DIR=$(CURDIR)/fpga_cases bash ./scripts/build_tests.sh workloads/system.c
	bash ./scripts/fpga_flow.sh system system

fpga-verilog:
	bash ./scripts/build_tests.sh $(TEST)
	bash ./scripts/fpga_flow_verilog.sh $(TEST)

fpga-verilog-system:
	mkdir -p fpga_cases
	OUT_DIR=$(CURDIR)/fpga_cases bash ./scripts/build_tests.sh workloads/system.c
	CASE_DIR=$(CURDIR)/fpga_cases bash ./scripts/fpga_flow_verilog.sh system

clean:
	rm $(TARGET)
