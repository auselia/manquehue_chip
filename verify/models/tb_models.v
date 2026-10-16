// Self-test of the two behavioural models with a plain bit-banging master (no DUT). Prints PASS or FAIL lines.
`timescale 1ns/1ps
module tb_models;
  reg cs_n = 1, sclk = 0, mosi = 0;
  reg [13:0] code = 14'd0;
  wire sdo;
  reg nss_n = 1, rsclk = 0, rmosi = 0;
  wire rmiso, dio0;
  integer errors = 0;

  ads7057_model #(.LAUNCH_ON_FALLING(1)) adc (.cs_n(cs_n), .sclk(sclk), .sdo(sdo), .ain_code(code));
  sx1276_model radio (.nss_n(nss_n), .sclk(rsclk), .mosi(rmosi), .miso(rmiso), .dio0(dio0));

  // ---- ADC frame: nclk clocks, SDO sampled on the rising edge after the launching falling edge
  reg [31:0] frame;
  task adc_frame(input integer nclk);
    integer k;
    begin
      frame = 0;
      cs_n = 0; #20;
      for (k = 0; k < nclk; k = k + 1) begin
        #25 sclk = 1;                          // rising edge: host samples SDO (launched at the previous falling edge)
        frame = {frame[30:0], sdo};
        #25 sclk = 0;                          // falling edge: ADC launches the next bit
      end
      #20 cs_n = 1; #120;                      // CS high longer than tacq
    end
  endtask

  task check(input [255:0] what, input [31:0] got, input [31:0] exp);
    begin
      if (got !== exp) begin errors = errors + 1; $display("FAIL %0s: got 0x%08h expected 0x%08h", what, got, exp); end
    end
  endtask

  // ---- radio byte transfer (mode 0)
  reg [7:0] rb;
  task rf_byte(input [7:0] d);
    integer k;
    begin
      rb = 0;
      for (k = 7; k >= 0; k = k - 1) begin
        rmosi = d[k]; #50 rsclk = 1; rb = {rb[6:0], rmiso}; #50 rsclk = 0;
      end
    end
  endtask

  reg [7:0] v;
  integer j;
  initial begin
    #100;
    // ---- ADS7057: sample 1.000 V = code 2482 (0x09B2)
    code = 14'd2482;
    adc_frame(24);                 // first frame: zeros, also the calibration frame
    check("adc first frame", frame[23:0], 24'h000000);
    adc_frame(24);                 // second frame returns the sample taken at the first CS fall
    check("adc second frame", frame[23:0], 24'h136400);    // {0, 0x09B2 << 9}
    code = 14'h3F00;               // negative code
    adc_frame(24);                 // returns 2482 again (sample taken at the second CS fall)
    check("adc third frame", frame[23:0], 24'h136400);
    adc_frame(24);                 // returns the negative code
    check("adc fourth frame", frame[23:0], {1'b0, 14'h3F00, 9'd0});
    adc_frame(10);                 // short frame, the conversion does not finish
    adc_frame(24);
    check("adc after short frame", frame[23:0], 24'h000000);
    check("adc short frames", adc.short_frame_count, 1);
    check("adc tacq violations", adc.tacq_violations, 0);

    // ---- SX1276: RegVersion
    nss_n = 0; #20; rf_byte(8'h42); rf_byte(8'h00); nss_n = 1; #100;
    check("radio RegVersion", rb, 8'h12);
    // write RegFifoAddrPtr = 0x80, then burst-write 3 bytes to the FIFO, set payload length, TX mode
    nss_n = 0; #20; rf_byte(8'h8D); rf_byte(8'h80); nss_n = 1; #100;
    nss_n = 0; #20; rf_byte(8'h80); rf_byte(8'hA1); rf_byte(8'hB2); rf_byte(8'hC3); nss_n = 1; #100;
    nss_n = 0; #20; rf_byte(8'hA2); rf_byte(8'h03); nss_n = 1; #100;    // RegPayloadLength = 3
    nss_n = 0; #20; rf_byte(8'h81); rf_byte(8'h83); nss_n = 1; #100;    // RegOpMode = LoRa TX
    #3000;
    check("radio dio0 after TX", dio0, 1);
    nss_n = 0; #20; rf_byte(8'h12); rf_byte(8'h00); nss_n = 1; #100;
    check("radio IrqFlags TxDone", rb & 8'h08, 8'h08);
    check("radio tx len", radio.last_tx_len, 3);
    check("radio tx byte 0", radio.last_tx[0], 8'hA1);
    check("radio tx byte 2", radio.last_tx[2], 8'hC3);
    nss_n = 0; #20; rf_byte(8'h92); rf_byte(8'h08); nss_n = 1; #100;    // clear TxDone
    check("radio dio0 cleared", dio0, 0);
    // burst read of three registers 0x0E.. (TxBase 0x80, RxBase 0x00)
    nss_n = 0; #20; rf_byte(8'h0E); rf_byte(8'h00); v = rb; rf_byte(8'h00); nss_n = 1; #100;
    check("radio burst reg 0x0E", v, 8'h80);
    check("radio burst reg 0x0F", rb, 8'h00);

    if (errors == 0) $display("PASS: models self-test, 0 failures");
    else $display("FAIL: %0d failures", errors);
    $finish;
  end
endmodule
