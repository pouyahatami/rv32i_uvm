// =============================================================================
// debug_fsm.sv
//
// External-debug halt/resume. A two-state machine: the core is either
// running or parked at the debug halt address.
//
// Entry is on an external debug request or an EBREAK; exit is on DRET, which
// resumes at dpc. The state encoding is explicit (StRunning = 2'b00,
// StParked = 2'b11) so the two states are Hamming-distance 2 apart rather
// than adjacent.
//
// Covered directly by tb_pipe_debug in rtl/tb_pipe.sv. Debug halt/resume is
// not architectural state, so no ISS models it and there are no golden values
// to check against -- the testbench asserts on the halt/resume behaviour
// itself.
// =============================================================================

module debug_fsm (
    input  logic        clk,
    input  logic        reset,
    input  logic        debug_req_i,
    input  logic [31:0] dm_halt_addr_i,
    input  logic [31:0] dm_exception_addr_i,
    input  logic        is_ebreak,
    input  logic        is_dret,
    input  logic [31:0] pc,
    output logic        debug_halted_o,
    output logic        debug_mode_o,
    output logic        enter_debug,
    output logic        exit_debug,
    output logic [31:0] dpc,
    output logic [31:0] dcsr,
    output logic [31:0] dscratch0,
    output logic [31:0] dscratch1
);

  typedef enum logic [1:0] {
    StRunning = 2'b00,
    StParked  = 2'b11
  } state_e;

  state_e state;

  assign enter_debug = (debug_req_i | is_ebreak) && !debug_mode_o;
  assign exit_debug  = is_dret && debug_mode_o;

  always_ff @(posedge clk) begin
    if (reset) begin
      state     <= StRunning;
      dpc       <= 32'h0;
      dcsr      <= 32'h0;
      dscratch0 <= 32'h0;
      dscratch1 <= 32'h0;
    end else begin
      unique case (state)
        StRunning: begin
          if (enter_debug) begin
            state     <= StParked;
            dpc       <= pc;
            dcsr[8:6] <= is_ebreak ? 3'd1 : 3'd3;
          end else
            state <= StRunning;
        end
        StParked: begin
          if (exit_debug)
            state <= StRunning;
          else
            state <= StParked;
        end
        default: // state is 2 bits but only ever holds StRunning/StParked --
                 // 2'b01/2'b10 are unreachable; recover to StRunning defensively
          state <= StRunning;
      endcase
    end
  end

  always_comb begin
    unique case (state)
      StRunning: begin
        debug_mode_o   = state[0];
        debug_halted_o = state[1];
      end
      StParked: begin
        debug_mode_o   = state[0];
        debug_halted_o = state[1];
      end
      default: begin // unreachable -- see the state-register case above
        debug_mode_o   = 1'bx;
        debug_halted_o = 1'bx;
      end
    endcase
  end

endmodule
