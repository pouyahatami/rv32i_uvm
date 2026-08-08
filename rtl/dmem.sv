// =============================================================================
// dmem.sv
//
// Byte-addressable data RAM with LB/LH/LW/LBU/LHU and SB/SH/SW support,
// selected by funct3. EXTENDED (memory-widening milestone) from a fixed
// 256-byte array to a parameterized MemBytes (default 16384 = 16KB),
// so a program can actually have a stack and a few real data structures
// instead of living in 256 bytes. The byte-lane logic itself is
// unchanged from the RV32I-extension version -- only the address width
// is now derived from MemBytes via $clog2 instead of hardcoded to 8
// bits.
//
// Little-endian byte ordering (byte 0 = LSB), consistent with RV32I.
// =============================================================================

module dmem #(
    parameter int MemBytes = 16384
) (
    input  logic        clk,
    input  logic        we,
    input  logic [31:0] a,
    input  logic [31:0] wd,
    input  logic [2:0]  funct3,   // 000 SB/LB, 001 SH/LH, 010 SW/LW,
                                   // 100 LBU, 101 LHU (store side only
                                   // distinguishes byte/half/word)
    output logic [31:0] rd
);

  localparam int AddrWidth = $clog2(MemBytes);

  logic [7:0] mem[MemBytes-1:0];

  logic [AddrWidth-1:0] addr;
  logic [1:0]           off;
  assign addr = a[AddrWidth-1:0];
  assign off  = a[1:0];

  logic [31:0] word_read;
  logic [7:0]  byte_read;
  logic [15:0] half_read;

  assign word_read = {mem[{addr[AddrWidth-1:2], 2'b11}], mem[{addr[AddrWidth-1:2], 2'b10}],
                       mem[{addr[AddrWidth-1:2], 2'b01}], mem[{addr[AddrWidth-1:2], 2'b00}]};
  assign byte_read = mem[addr];
  assign half_read = off[1]
      ? {mem[{addr[AddrWidth-1:2], 2'b11}], mem[{addr[AddrWidth-1:2], 2'b10}]}
      : {mem[{addr[AddrWidth-1:2], 2'b01}], mem[{addr[AddrWidth-1:2], 2'b00}]};

  // unique case: funct3 enumerates the 5 legal load widths (LB/LH/LW/LBU/
  // LHU); the remaining 3 encodings of a 3-bit field are structurally
  // unreachable here (they're store-only or unused), covered defensively.
  always_comb
    unique case (funct3)
      3'b000: // LB (sign-extend)
        rd = {{24{byte_read[7]}}, byte_read};
      3'b001: // LH (sign-extend)
        rd = {{16{half_read[15]}}, half_read};
      3'b010: // LW
        rd = word_read;
      3'b100: // LBU (zero-extend)
        rd = {24'b0, byte_read};
      3'b101: // LHU (zero-extend)
        rd = {16'b0, half_read};
      default:
        rd = word_read;
    endcase

  // unique case: funct3 enumerates the 3 legal store widths (SB/SH/SW);
  // the remaining encodings never reach this port from real RV32I decode.
  always_ff @(posedge clk)
    if (we)
      unique case (funct3)
        3'b000: // SB
          mem[addr] <= wd[7:0];
        3'b001: begin // SH
          mem[{addr[AddrWidth-1:2], off[1], 1'b0}] <= wd[7:0];
          mem[{addr[AddrWidth-1:2], off[1], 1'b1}] <= wd[15:8];
        end
        3'b010: begin // SW
          mem[{addr[AddrWidth-1:2], 2'b00}] <= wd[7:0];
          mem[{addr[AddrWidth-1:2], 2'b01}] <= wd[15:8];
          mem[{addr[AddrWidth-1:2], 2'b10}] <= wd[23:16];
          mem[{addr[AddrWidth-1:2], 2'b11}] <= wd[31:24];
        end
        default: begin // funct3 011/100/101/110/111 are not valid store widths --
                        // no real encoding reaches here; fall back to a full-word
                        // write rather than silently dropping the store.
          mem[{addr[AddrWidth-1:2], 2'b00}] <= wd[7:0];
          mem[{addr[AddrWidth-1:2], 2'b01}] <= wd[15:8];
          mem[{addr[AddrWidth-1:2], 2'b10}] <= wd[23:16];
          mem[{addr[AddrWidth-1:2], 2'b11}] <= wd[31:24];
        end
      endcase
endmodule
