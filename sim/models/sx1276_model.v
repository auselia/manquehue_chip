// Behavioural model of the SX1276 (RFM9x) SPI register interface, from the facts in SPI_design_handoff.md
// (Semtech datasheet rev 5). Simulation only: registers, FIFO and the SPI protocol, no radio.
//
//   - SPI mode 0 (CPOL 0, CPHA 0), MSB first. First byte = {W, address[6:0]}, W = 1 for write.
//   - Following bytes are data. With NSS kept low the address increments (burst), except for address 0x00 (FIFO),
//     which stays and moves the FIFO pointer (RegFifoAddrPtr, 0x0D) by one per byte written or read instead.
//   - RegVersion (0x42) reads 0x12. RegOpMode (0x01), frequency 0x06..0x08, PaConfig 0x09, FifoAddrPtr 0x0D,
//     FifoTxBaseAddr 0x0E, FifoRxBaseAddr 0x0F, IrqFlags 0x12 (write 1 to clear), ModemConfig 0x1D/0x1E/0x26,
//     PayloadLength 0x22, DioMapping1 0x40 are plain read/write registers, 0x13 RxNbBytes is read only.
//   - Writing RegOpMode with a TX mode (bits 2:0 = 3) sets IrqFlags.TxDone (bit 3) after TX_DELAY_NS, after taking
//     the FIFO bytes TxBase.. as the payload (`last_tx_len`, `last_tx` for the testbench) and sets `dio0` high.
`timescale 1ns/1ps
module sx1276_model #(
  parameter real TX_DELAY_NS = 2000.0
) (
  input  wire nss_n,
  input  wire sclk,
  input  wire mosi,
  output wire miso,
  output reg  dio0
);
  reg [7:0] regs [0:127];
  reg [7:0] fifo [0:255];
  reg [7:0] last_tx [0:255];
  integer   last_tx_len = 0;
  integer   writes = 0, reads = 0, bad_burst_on_fifo = 0;

  reg [7:0] addr;
  reg       is_write;
  reg [2:0] bitcnt;
  reg [7:0] rx_byte, tx_byte;
  integer   bytecnt;
  reg       miso_r = 1'b0;
  assign miso = nss_n ? 1'bz : miso_r;

  integer i;
  initial begin
    for (i = 0; i < 128; i = i + 1) regs[i] = 8'h00;
    for (i = 0; i < 256; i = i + 1) fifo[i] = 8'h00;
    regs[8'h42] = 8'h12;       // RegVersion
    regs[8'h0E] = 8'h80;       // FifoTxBaseAddr
    regs[8'h0F] = 8'h00;       // FifoRxBaseAddr
    regs[8'h01] = 8'h09;       // RegOpMode reset value (FSK/OOK, standby)
    dio0 = 1'b0;
  end

  function [7:0] reg_read(input [6:0] a);
    begin
      if (a == 7'h00) reg_read = fifo[regs[8'h0D]];
      else            reg_read = regs[a];
    end
  endfunction

  task reg_write(input [6:0] a, input [7:0] d);
    integer k;
    begin
      writes = writes + 1;
      case (a)
        7'h00: begin fifo[regs[8'h0D]] = d; regs[8'h0D] = regs[8'h0D] + 8'd1; end
        7'h12: begin regs[8'h12] = regs[8'h12] & ~d; if (regs[8'h12][3] == 1'b0) dio0 = 1'b0; end  // write 1 to clear
        7'h13, 7'h42: ;       // read only
        default: regs[a] = d;
      endcase
      if (a == 7'h01 && d[2:0] == 3'd3) begin       // TX mode: send the FIFO payload
        last_tx_len = regs[8'h22];
        for (k = 0; k < 256; k = k + 1) last_tx[k] = fifo[(regs[8'h0E] + k) & 8'hFF];
        #(TX_DELAY_NS) regs[8'h12] = regs[8'h12] | 8'h08; dio0 = 1'b1;
        regs[8'h01] = {d[7:3], 3'd1};              // back to standby
      end
    end
  endtask

  always @(negedge nss_n) begin
    bitcnt = 3'd0; bytecnt = 0; rx_byte = 8'h00; miso_r = 1'b0;
  end

  always @(posedge sclk) if (!nss_n) begin           // sample MOSI on the rising edge
    rx_byte = {rx_byte[6:0], mosi};
    if (bitcnt == 3'd7) begin
      if (bytecnt == 0) begin
        is_write = rx_byte[7]; addr = {1'b0, rx_byte[6:0]};
        tx_byte = reg_read(rx_byte[6:0]);
      end else if (is_write) begin
        reg_write(addr[6:0], rx_byte);
        if (addr[6:0] != 7'h00) addr = addr + 8'd1;
      end else begin
        reads = reads + 1;
        if (addr[6:0] != 7'h00) addr = addr + 8'd1;
        else regs[8'h0D] = regs[8'h0D] + 8'd1;      // FIFO read: the byte just sent moves FifoAddrPtr on
        tx_byte = reg_read(addr[6:0]);
      end
      bytecnt = bytecnt + 1;
    end
    bitcnt = bitcnt + 3'd1;
  end

  // MISO changes on the falling edge (mode 0), first bit as soon as NSS falls
  always @(negedge sclk) if (!nss_n) begin
    if (bytecnt == 0 && bitcnt == 3'd0) miso_r = 1'b0;
    else miso_r = tx_byte[7 - bitcnt];
  end
  always @(negedge nss_n) miso_r = 1'b0;
  always @(bitcnt) if (!nss_n && bitcnt == 3'd0 && bytecnt > 0) miso_r = tx_byte[7];
endmodule
