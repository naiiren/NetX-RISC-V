BUILD_DIR := build
TARGET := $(BUILD_DIR)/rv32i_test

.PHONY: all run raw custom-build run-custom clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): main.cpp | $(BUILD_DIR)
	c++ -O3 -ffast-math -std=c++23 -o $@ $< -fopenmp -lkahip -march=native

run: all
	nx compile _netx.toml --top CORE --minimal | $(TARGET)

raw: all
	nx compile _netx.toml --top CORE --minimal | $(TARGET) --no-native

custom-build:
	bash ./scripts/build_tests.sh

run-custom: all custom-build
	nx compile _netx.toml --top CORE --minimal | $(TARGET) --dir custom_cases

clean:
	rm $(TARGET)
