BUILD_DIR := build
TARGET := $(BUILD_DIR)/rv32i_test

.PHONY: all run raw custom-build run-custom clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): main.cpp | $(BUILD_DIR)
	c++ -O3 -ffast-math -std=c++23 -o $@ $< -fopenmp -march=native

run: all custom-build
	nx compile _netx.toml --top CORE --minimal --output compiled.json
	cat compiled.json | $(TARGET)
	cat compiled.json | $(TARGET) --dir custom_cases
	rm compiled.json

raw: all custom-build
	nx compile _netx.toml --top CORE --minimal --output compiled.json
	cat compiled.json | $(TARGET) --no-native
	cat compiled.json | $(TARGET) --no-native --dir custom_cases
	rm compiled.json

debug: all custom-build
	nx compile _netx.toml --top CORE --minimal --output compiled.json
	cat compiled.json | $(TARGET) --trace
	cat compiled.json | $(TARGET) --trace --dir custom_cases
	rm compiled.json

custom-build:
	bash ./scripts/build_tests.sh

clean:
	rm $(TARGET)
