// Behavioural model of a serial PSRAM (APS6404L, 8 MB, SPI mode) for simulation (Verilator, Icarus), on CS1 or CS2.
// Commands (opcode on sio0):
//   0x03 read, 0x0B fast read (8 wait clocks), 0x02 write: 24-bit address and data on single lines (MOSI = sio0,
//   MISO = sio1)
//   0xEB quad read: 24-bit address on sio[3:0] (6 clocks), 6 wait clocks, data on sio[3:0] (qqspi in quad mode)
//   0x38 quad write: 24-bit address and data on sio[3:0]
//   0x9F read ID: 24 address clocks (ignored), then MF ID 0x0D and KGD 0x5D
//   0x66 / 0x99 reset enable / reset: nothing to do in the model
// No write enable (a PSRAM has none). The content starts at 0x00 (+psram<n>= loads a hex file, objcopy -O verilog).
// Not modelled: QPI mode (0x35), wrap mode (0xC0), page boundary, the 8 us CS low limit (tCEM), timing checks.
`timescale 1ns/1ps
module spi_psram_model #(
  parameter int unsigned SizeBytes = 1 << 16,   // modelled part of the 8 MB PSRAM
  parameter real         TcoNs     = 6.0,
  parameter string       Name      = "psram0"
) (
  input  wire       csn,
  input  wire       sclk,
  input  wire [3:0] sio_i,
  output wire [3:0] sio_o,
  output wire [3:0] sio_oe
);
  reg [7:0]  mem [SizeBytes];
  reg [7:0]  cmd;
  reg [23:0] addr;
  reg [7:0]  shreg;
  integer    nclk;
  reg [3:0]  out_q, oe_q;
  string     image;

  initial begin
    for (int i = 0; i < SizeBytes; i++) mem[i] = 8'h00;
    if ($value$plusargs({Name, "=%s"}, image)) begin
      $readmemh(image, mem);
      $display("[PSRAM] %s loaded %s", Name, image);
    end
    out_q = 4'h0;
    oe_q  = 4'h0;
  end

  assign #(TcoNs) sio_o  = out_q;
  assign #(TcoNs) sio_oe = oe_q;

  always @(negedge csn) begin
    nclk = 0;
    cmd  = 8'h00;
    addr = 24'h0;
    oe_q = 4'h0;
  end
  always @(posedge csn) oe_q = 4'h0;

  always @(posedge sclk) if (!csn) begin
    integer k;
    if (nclk < 8)                                    cmd  = {cmd[6:0], sio_i[0]};
    else if ((cmd == 8'h03 || cmd == 8'h0B || cmd == 8'h02 || cmd == 8'h9F) && nclk < 32)
                                                     addr = {addr[22:0], sio_i[0]};
    else if ((cmd == 8'hEB || cmd == 8'h38) && nclk < 14)
                                                     addr = {addr[19:0], sio_i[3:0]};
    else if (cmd == 8'h02) begin                     // single write, MSB first
      shreg = {shreg[6:0], sio_i[0]};
      k = nclk - 32;
      if (k % 8 == 7) mem[(addr + k / 8) % SizeBytes] = shreg;
    end else if (cmd == 8'h38) begin                 // quad write, high nibble first
      k = nclk - 14;
      shreg = {shreg[3:0], sio_i[3:0]};
      if (k % 2 == 1) mem[(addr + k / 2) % SizeBytes] = shreg;
    end
    nclk = nclk + 1;
  end

  always @(negedge sclk) if (!csn) begin
    integer k;
    reg [7:0] b;
    if (cmd == 8'h03 && nclk >= 32) begin
      k = nclk - 32;  b = mem[(addr + k / 8) % SizeBytes];
      out_q = {2'b00, b[7 - (k % 8)], 1'b0};  oe_q = 4'b0010;
    end else if (cmd == 8'h0B && nclk >= 40) begin
      k = nclk - 40;  b = mem[(addr + k / 8) % SizeBytes];
      out_q = {2'b00, b[7 - (k % 8)], 1'b0};  oe_q = 4'b0010;
    end else if (cmd == 8'h9F && nclk >= 32) begin
      k = nclk - 32;  b = (k < 8) ? 8'h0D : 8'h5D;
      out_q = {2'b00, b[7 - (k % 8)], 1'b0};  oe_q = 4'b0010;
    end else if (cmd == 8'hEB && nclk >= 20) begin   // 6 address + 6 wait clocks after the opcode
      k = nclk - 20;  b = mem[(addr + k / 2) % SizeBytes];
      out_q = (k % 2 == 0) ? b[7:4] : b[3:0];  oe_q = 4'b1111;
    end
  end
endmodule
