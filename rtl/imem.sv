// =============================================================================
// imem.sv
//
// Instruction memory, word-aligned, loaded from a hex file at simulation
// start via $readmemh. EXTENDED (memory-widening milestone): MemWords
// is now a parameter (default 4096 = 16KB of instructions, up from the
// original 64 words), matching dmem.sv's default RAM size symmetrically.
// =============================================================================

module imem #(
    parameter        TestFile = "riscvtest.txt",
    parameter int    MemWords = 4096
) (
    input  logic [31:0] a,
    output logic [31:0] rd
);

  logic [31:0] RAM[MemWords-1:0];

  initial
      $readmemh(TestFile, RAM);

  assign rd = RAM[a[31:2]]; // word aligned
endmodule
