BUILD_DIR := build
TARGET := $(BUILD_DIR)/rv32i_test

.PHONY: all run clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): main.cpp | $(BUILD_DIR)
	g++ -O3 -Ofast -std=c++20 -o $@ $< -lnxsim

run: all
	nx compile _netx.toml --top core --minimal | $(TARGET)

clean:
	rm $(TARGET)