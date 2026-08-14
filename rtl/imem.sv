// =============================================================================
// imem.sv
//
// Instruction memory, word-aligned, loaded from a hex file at simulation
// start via $readmemh. MemWords defaults to 4096 (16KB), matching dmem.sv's
// default RAM size.
//
// The UVM environment writes this array directly through a bound interface
// rather than via $readmemh; see verif/uvm/mem_backdoor_bind.sv. Nothing in
// this file knows about that, which is the point of using `bind`.
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
