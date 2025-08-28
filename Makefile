BUILD_DIR := build
TARGET := $(BUILD_DIR)/rv32i_test

.PHONY: all run clean

all: $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(TARGET): main.cpp | $(BUILD_DIR)
	c++ -O3 -ffast-math -std=c++23 -flto -o $@ $< -lkahip

run: all
	nx compile _netx.toml --top CORE --minimal | $(TARGET)

clean:
	rm $(TARGET)