BUILD_DIR := build
TARGET := $(BUILD_DIR)/rv32i_test

TEST ?= gcd

.PHONY: all run raw custom fpga lcd-demo fpga-lcd-demo clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): main.cpp | $(BUILD_DIR)
	c++ -O3 -ffast-math -std=c++23 -o $@ $< -fopenmp -march=native

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

lcd-demo:
	mkdir -p fpga_cases
	OUT_DIR=$(CURDIR)/fpga_cases bash ./scripts/build_tests.sh scripts/lcd_demo.c

fpga-lcd-demo: lcd-demo
	bash ./scripts/fpga_flow.sh lcd lcd_demo

clean:
	rm $(TARGET)
