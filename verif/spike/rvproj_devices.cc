// =============================================================================
// rvproj_devices.cc -- Spike MMIO plugin modelling this project's two custom
// peripherals, so Spike can be the reference model for tb_pipe_csr.
//
// ---- Why this file exists, and why it is NOT a step backwards ----
//
// The whole reason the hand-written C++ ISS was deleted is that a reference
// model written by the same author as the RTL, from the same reading of the
// spec, cannot catch a misreading of the spec. This file is written by us and
// models our RTL -- so why is it not the same problem?
//
// Because there is no specification for these two devices to disagree with.
// clint.sv here is a deliberately simplified 32-bit CLINT at a project-chosen
// address; uart_tx.sv is a two-register transmit-only UART with no baud model.
// Neither claims conformance to anything. They are *design*, not *spec*, and a
// model of them is a restatement of a design decision rather than an
// independent claim about correctness.
//
// What matters is where the boundary sits. Everything with a specification --
// every instruction, CSR read/write side effect, trap cause encoding, trap
// priority, mstatus stacking on trap entry, mret behaviour -- comes from Spike
// and is checked against an authority we did not write. Only the two
// peripherals come from us, and they are ~60 lines with no branching
// semantics. That is the smallest surface this split can have while keeping
// tb_pipe_csr's timer-interrupt and UART coverage.
//
// ---- What is modelled ----
//
// CLINT (rv32i_pkg::CLINT_BASE, default 0x00020000), matching clint.sv:
//   +0x0  mtime      32-bit, free-running, +1 per tick; software-writable
//   +0x4  mtimecmp   32-bit, reset 0xFFFFFFFF
//   mtip = (mtime >= mtimecmp), driven into the hart's mip.MTIP
//
// UART (rv32i_pkg::UART_BASE, default 0x00030000), matching uart_tx.sv:
//   +0x0  txdata     write-only; byte is emitted immediately (no baud model)
//   +0x4  status     bit 0 = TX_READY, always 1 (instant-transmit model)
//   Reads of txdata return the last byte written, matching uart_tx.sv's
//   readback behaviour that tb_pipe_csr's x26 check depends on.
//
// ---- A timing difference that is deliberate, not a bug ----
//
// clint.sv increments mtime once per CLOCK CYCLE. Spike has no notion of a
// clock, so this increments once per instruction retired. The two therefore
// fire the timer interrupt after different amounts of program progress. That
// is the same step-count-vs-clock-count mismatch DESIGN_GUIDE.md section 7
// already documented for the previous ISS, and the reason tb_pipe_csr checks
// "the handler ran and left the right architectural state" rather than "it
// fired on cycle N". program_csr.py's handler defers mtimecmp far into the
// future on the interrupt path, so exactly one timer interrupt is taken on
// either model regardless of rate.
//
// Build: see Makefile in this directory. Load with
//   spike --extlib=librvproj_devices.so --device=rvproj_clint,... etc.
// =============================================================================

// sys/syscall.h first: libstdc++ 13's <atomic> uses SYS_futex without pulling
// in its declaration, and Spike's processor.h reaches <atomic> transitively.
// Spike's own build gets this via its config; a standalone plugin does not.
#include <sys/syscall.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <sstream>

#include "abstract_device.h"
#include "processor.h"
#include "simif.h"
#include "sim.h"
#include "dts.h"
#include "encoding.h"

// ---------------------------------------------------------------------------
// helpers: these devices are 32-bit registers only; reject anything else
// rather than silently mis-serving a width the RTL could never see.
// ---------------------------------------------------------------------------
static bool read32(uint32_t value, reg_t addr, size_t len, uint8_t *bytes)
{
  if (len != 4 || (addr & 3))
    return false;
  const uint32_t le = value;
  memcpy(bytes, &le, 4);
  return true;
}

static bool write32(uint32_t *dst, reg_t addr, size_t len, const uint8_t *bytes)
{
  if (len != 4 || (addr & 3))
    return false;
  memcpy(dst, bytes, 4);
  return true;
}

// ---------------------------------------------------------------------------
// CLINT -- mirrors rtl/clint.sv
// ---------------------------------------------------------------------------
class rvproj_clint_t : public abstract_device_t {
 public:
  explicit rvproj_clint_t(const simif_t *sim)
      : sim(sim), mtime(0), mtimecmp(0xFFFFFFFFu) { sync(); }

  bool load(reg_t addr, size_t len, uint8_t *bytes) override
  {
    switch (addr & 0xF) {
      case 0x0: return read32(mtime, addr, len, bytes);
      case 0x4: return read32(mtimecmp, addr, len, bytes);
      default:  return read32(0, addr, len, bytes);   // clint.sv reads 0 elsewhere
    }
  }

  bool store(reg_t addr, size_t len, const uint8_t *bytes) override
  {
    bool ok;
    switch (addr & 0xF) {
      case 0x0: ok = write32(&mtime, addr, len, bytes); break;
      case 0x4: ok = write32(&mtimecmp, addr, len, bytes); break;
      default:  ok = (len == 4);  break;              // clint.sv ignores it
    }
    sync();
    return ok;
  }

  // Spike calls this as the hart makes progress. clint.sv counts clock cycles;
  // here one tick is one instruction. See the header note -- the rate differs
  // by construction, the architectural outcome does not.
  void tick(reg_t rtc_ticks) override
  {
    mtime += (rtc_ticks ? rtc_ticks : 1);
    sync();
  }

  reg_t size() override { return 0x1000; }

 private:
  void sync()
  {
    // mtip_o = (mtime >= mtimecmp), exactly clint.sv's combinational compare.
    // get_state() rather than the `state` member directly: Spike's own clint_t
    // is a declared friend of processor_t and a plugin is not.
    const bool mtip = (mtime >= mtimecmp);
    for (const auto &[hart_id, hart] : sim->get_harts())
      hart->get_state()->mip->backdoor_write_with_mask(MIP_MTIP,
                                                       mtip ? MIP_MTIP : 0);
  }

  const simif_t *sim;
  uint32_t mtime;
  uint32_t mtimecmp;
};

// ---------------------------------------------------------------------------
// UART -- mirrors rtl/uart_tx.sv
// ---------------------------------------------------------------------------
class rvproj_uart_t : public abstract_device_t {
 public:
  rvproj_uart_t() : last_byte(0) {}

  bool load(reg_t addr, size_t len, uint8_t *bytes) override
  {
    switch (addr & 0xF) {
      case 0x0: return read32(last_byte, addr, len, bytes);
      case 0x4: return read32(1u, addr, len, bytes);   // TX_READY always 1
      default:  return read32(0, addr, len, bytes);
    }
  }

  bool store(reg_t addr, size_t len, const uint8_t *bytes) override
  {
    uint32_t v = 0;
    if (!write32(&v, addr, len, bytes))
      return false;
    if ((addr & 0xF) == 0x0) {
      last_byte = v & 0xFF;
      tx.push_back(static_cast<uint8_t>(last_byte));
    }
    return true;
  }

  reg_t size() override { return 0x1000; }

  const std::vector<uint8_t> &stream() const { return tx; }

 private:
  uint32_t last_byte;
  std::vector<uint8_t> tx;
};

// ---------------------------------------------------------------------------
// Spike plugin registration.
//
// Spike discovers a plugin device's base address through the device tree: the
// factory emits a DTS node, Spike compiles and re-parses it, and hands the
// parsed base back. The base is passed as the --device argument, e.g.
//   --device=rvproj_clint,0x20000
// so the addresses stay in one place (regen.sh, from rv32i_pkg.sv) rather than
// being compiled in here.
// ---------------------------------------------------------------------------
static reg_t base_from_args(const std::vector<std::string> &sargs, reg_t dflt)
{
  if (!sargs.empty())
    return strtoull(sargs[0].c_str(), nullptr, 0);
  return dflt;
}

static std::string dts_node(const char *compat, const char *name,
                            const std::vector<std::string> &sargs, reg_t dflt)
{
  const reg_t base = base_from_args(sargs, dflt);
  std::stringstream s;
  s << std::hex
    << "    " << name << "@" << base << " {\n"
       "      compatible = \"" << compat << "\";\n"
       "      reg = <0x0 0x" << base << " 0x0 0x1000>;\n"
       "    };\n";
  return s.str();
}

static rvproj_clint_t *clint_parse(const void *fdt, const sim_t *sim,
                                   reg_t *base, const std::vector<std::string> &sargs)
{
  *base = base_from_args(sargs, 0x20000);
  return new rvproj_clint_t(sim);
}

static std::string clint_dts(const sim_t *, const std::vector<std::string> &sargs)
{
  return dts_node("rvproj,clint0", "rvproj_clint", sargs, 0x20000);
}

static rvproj_uart_t *uart_parse(const void *fdt, const sim_t *sim,
                                 reg_t *base, const std::vector<std::string> &sargs)
{
  *base = base_from_args(sargs, 0x30000);
  return new rvproj_uart_t();
}

static std::string uart_dts(const sim_t *, const std::vector<std::string> &sargs)
{
  return dts_node("rvproj,uart0", "rvproj_uart", sargs, 0x30000);
}

REGISTER_DEVICE(rvproj_clint, clint_parse, clint_dts)
REGISTER_DEVICE(rvproj_uart, uart_parse, uart_dts)
