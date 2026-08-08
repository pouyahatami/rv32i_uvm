# Build the Spike MMIO plugin (CLINT + UART) for this project.
#
#   make SPIKE_SRC=~/src/riscv-isa-sim SPIKE_BUILD=~/src/riscv-isa-sim/build
#
# SPIKE_SRC   checked-out riscv-isa-sim (for headers)
# SPIKE_BUILD its build directory       (for the generated config.h)

SPIKE_SRC   ?= $(HOME)/src/riscv-isa-sim
SPIKE_BUILD ?= $(SPIKE_SRC)/build

CXX      ?= g++
CXXFLAGS ?= -std=c++2a -O2 -fPIC -Wall
INCLUDES  = -I$(SPIKE_BUILD) \
            -I$(SPIKE_SRC) \
            -I$(SPIKE_SRC)/riscv \
            -I$(SPIKE_SRC)/fesvr \
            -I$(SPIKE_SRC)/softfloat \
            -I$(SPIKE_SRC)/fdt

TARGET = librvproj_devices.so

all: $(TARGET)

$(TARGET): rvproj_devices.cc
	$(CXX) $(CXXFLAGS) $(INCLUDES) -shared $< -o $@

clean:
	rm -f $(TARGET)

.PHONY: all clean
