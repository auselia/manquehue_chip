// Behavioural model of an I2C target with 256 byte registers, for simulation (Verilator, Icarus, VCS)
// Author: Nicolás Villegas - Universidad de los Andes, Chile
//
// A register-pointer device, as most I2C sensors:
//   write: START, address + W, register number, data bytes (stored from the register number, auto-increment), STOP
//   read:  START, address + R, data bytes from the register pointer (auto-increment) until the host answers NACK.
//          A register read is a write of the register number, a repeated START and a read: the pointer stays.
// The model answers ACK to its own address and to every written byte, and NACK to any other address (then it
// ignores the bus until the next START or STOP). It samples SDA at the rising SCL edge and changes SDA at the falling
// SCL edge. It only pulls SDA low (sda_oe = 1): the test bench adds the pull-up (wired AND with the host).
// Not modelled: clock stretching, 10-bit addresses, general call, timing checks (hold, setup, bus speed).
`timescale 1ns/1ps
module i2c_target_model #(
  parameter [6:0] Addr = 7'h50
) (
  input  wire scl,     // bus SCL (after the pull-up)
  input  wire sda,     // bus SDA (after the pull-up)
  output reg  sda_oe   // 1: the target pulls SDA low
);
  localparam [2:0] SIdle = 3'd0, SAddr = 3'd1, SReg = 3'd2, SWrite = 3'd3, SRead = 3'd4, SIgnore = 3'd5;

  reg [7:0] regs [0:255];
  reg [2:0] state, next;
  reg [7:0] ptr;           // register pointer
  reg [7:0] sr;            // received byte
  reg [3:0] nbits;         // bits received (write) or driven (read) in the current byte
  reg       in_ack;        // in the acknowledge clock
  reg [7:0] rbyte;         // byte being read out
  reg       host_ack;      // the host acknowledged the last read byte

  reg trace;              // +i2c_trace: print every START, STOP, byte and ACK
  reg edges;              // +i2c_edges: print every SCL and SDA change (debug)
  integer i;
  initial begin
    trace = $test$plusargs("i2c_trace");
    edges = $test$plusargs("i2c_edges");
    for (i = 0; i < 256; i = i + 1) regs[i] = 8'h00;
    state = SIdle; ptr = 8'h00; sda_oe = 1'b0; nbits = 4'd0; in_ack = 1'b0; host_ack = 1'b0;
  end

  always @(scl or sda) if (edges) $display("@%t | [I2C] scl=%b sda=%b oe=%b state=%0d", $time, scl, sda, sda_oe, state);

  // START (also a repeated START): SDA falls while SCL is high
  always @(negedge sda) if (scl) begin
    state = SAddr; nbits = 4'd0; in_ack = 1'b0; sda_oe = 1'b0;
    if (trace) $display("@%t | [I2C] START", $time);
  end

  // STOP: SDA rises while SCL is high
  always @(posedge sda) if (scl) begin
    state = SIdle; in_ack = 1'b0; sda_oe = 1'b0;
    if (trace) $display("@%t | [I2C] STOP", $time);
  end

  // rising SCL: sample a bit of the byte the host sends, or the host's ACK after a read byte
  always @(posedge scl) begin
    if ((state == SAddr || state == SReg || state == SWrite) && !in_ack && nbits < 4'd8) begin
      sr = {sr[6:0], sda};
      nbits = nbits + 4'd1;
    end else if (state == SRead && nbits == 4'd9) begin
      host_ack = !sda;
    end
  end

  // falling SCL: ACK a received byte, end the ACK clock, or drive the next read bit
  always @(negedge scl) begin
    case (state)
      SAddr, SReg, SWrite: begin
        if (in_ack) begin                    // the ACK clock ends
          sda_oe = 1'b0; in_ack = 1'b0; nbits = 4'd0; state = next;
          if (state == SRead) begin           // a read starts: drive bit 7 of the first byte now
            rbyte = regs[ptr]; sda_oe = !rbyte[7]; nbits = 4'd1;
          end
        end else if (nbits == 4'd8) begin    // a full byte arrived: answer in the ACK clock
          in_ack = 1'b1;
          if (trace) $display("@%t | [I2C] received 0x%02h in state %0d", $time, sr, state);
          case (state)
            SAddr: if (sr[7:1] == Addr) begin sda_oe = 1'b1; next = sr[0] ? SRead : SReg; end
                   else                 begin sda_oe = 1'b0; next = SIgnore; end
            SReg:  begin ptr = sr; sda_oe = 1'b1; next = SWrite; end
            default: begin regs[ptr] = sr; ptr = ptr + 8'd1; sda_oe = 1'b1; next = SWrite; end
          endcase
        end
      end
      SRead: begin
        if (nbits < 4'd8) begin              // bits 6 to 0
          sda_oe = !rbyte[4'd7 - nbits]; nbits = nbits + 4'd1;
        end else if (nbits == 4'd8) begin    // release SDA for the host's ACK clock
          sda_oe = 1'b0; nbits = 4'd9;
        end else if (host_ack) begin         // the host wants the next byte
          ptr = ptr + 8'd1; rbyte = regs[ptr]; sda_oe = !rbyte[7]; nbits = 4'd1;
        end else begin                       // NACK: the read ends
          ptr = ptr + 8'd1; sda_oe = 1'b0; state = SIgnore;
        end
      end
      default: sda_oe = 1'b0;
    endcase
  end
endmodule
