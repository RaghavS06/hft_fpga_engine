`timescale 1ns / 1ps
module packet_parser_tb;

    // =========================================================================
    // DUT SIGNAL DECLARATIONS
    // =========================================================================
    logic        clk;
    logic        rst_n;
    logic [63:0] rx_tdata;
    logic        rx_tvalid;
    logic        rx_tlast;
    logic        signal_trigger;
    logic [31:0] target_stock_price;
    logic [31:0] dropped_packet_count;
    logic        signal_trigger_latched;
    logic        target_stock_price_reg;

    // =========================================================================
    // DUT INSTANTIATION
    // =========================================================================
    packet_parser dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .rx_tdata            (rx_tdata),
        .rx_tvalid           (rx_tvalid),
        .rx_tlast            (rx_tlast),
        .signal_trigger      (signal_trigger),
        .target_stock_price  (target_stock_price),
        .dropped_packet_count(dropped_packet_count),
        .signal_trigger_latched (signal_trigger_latched),
        .target_stock_price_reg (target_stock_price_reg)
    );

    // =========================================================================
    // CLOCK GENERATION - 156.25 MHz = 6.4ns period
    // =========================================================================
    initial clk = 0;
    always #3.2 clk = ~clk;

    // =========================================================================
    // TEST PARAMETERS
    // =========================================================================
    // These match the hardcoded values in packet_parser.sv
    localparam DST_MAC       = 48'h00_11_22_33_44_55;
    localparam SRC_MAC       = 48'hAA_BB_CC_DD_EE_FF;
    localparam DST_IP        = 32'hC0_A8_01_0A;       // 192.168.1.10
    localparam SRC_IP        = 32'hC0_A8_01_01;       // 192.168.1.1
    localparam DST_PORT      = 16'h1388;               // 5000
    localparam SRC_PORT      = 16'h1389;               // 5001
    localparam PRICE_THRESH  = 32'd15000;              // $150.00
    localparam MSG_ADD       = 8'h41;                  // 'A'
    localparam MSG_DELETE    = 8'h44;                  // 'D'
    localparam SIDE_BUY      = 8'h42;                  // 'B'
    localparam TICKER_AAPL   = 16'h0001;

    // =========================================================================
    // PASS/FAIL COUNTER
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;

    // =========================================================================
    // TASK: drive one 64-bit word onto the AXI-Stream bus
    // =========================================================================
    task send_cycle(input logic [63:0] data, input logic last);
        @(negedge clk);          // drive signals on falling edge
        rx_tdata  = data;        // so they're stable before the next rising edge
        rx_tvalid = 1'b1;
        rx_tlast  = last;
        @(posedge clk);          // DUT samples here
        #0.1;                    // tiny delay to let outputs settle
    endtask

    // =========================================================================
    // TASK: de-assert valid between packets
    // =========================================================================
    task idle_cycle(input int n);
        @(negedge clk);
        rx_tvalid = 1'b0;
        rx_tdata  = 64'h0;
        rx_tlast  = 1'b0;
        repeat(n) @(posedge clk);
    endtask

    // =========================================================================
    // TASK: send a complete well-formed packet
    //
    // Raw byte stream layout:
    // Cycle 0: dst_mac[47:0] + src_mac[47:32]           bytes  0-7
    // Cycle 1: src_mac[31:0] + ethertype + ip[1:0]      bytes  8-15
    // Cycle 2: ip[3:0] + total_len + id + flags+frag    bytes 16-23
    // Cycle 3: ttl + protocol + checksum + src_ip        bytes 24-31
    // Cycle 4: dst_ip + udp_src_port + udp_dst_port     bytes 32-39
    // Cycle 5: udp_len + udp_chk + payload[7:0]         bytes 40-47
    // Cycle 6: msg_type+side+ticker_id+price            bytes 48-55
    // Cycle 7: quantity + sequence_num (tlast=1)         bytes 56-63
    // =========================================================================
    task send_packet(
    input logic [47:0] dst_mac,
    input logic [15:0] ethertype,
    input logic [7:0]  ip_protocol,
    input logic [31:0] dst_ip,
    input logic [15:0] dst_port,
    input logic [7:0]  msg_type,
    input logic [7:0]  side,
    input logic [15:0] ticker_id,
    input logic [31:0] price,
    input logic [31:0] quantity,
    input logic [31:0] sequence_num
);
    // Cycle 0: dst_mac[47:0] + src_mac[47:32]
    send_cycle({dst_mac, SRC_MAC[47:32]}, 1'b0);

    // Cycle 1: src_mac[31:0] + ethertype + ver_ihl(0x45) + tos(0x00)
    send_cycle({SRC_MAC[31:0], ethertype, 8'h45, 8'h00}, 1'b0);

    // Cycle 2: total_len + id + flags_frag + ttl + protocol
    send_cycle({16'h002C, 16'h0001, 16'h4000, 8'h40, ip_protocol}, 1'b0);

    // Cycle 3: checksum + src_ip + dst_ip[31:16]
    send_cycle({16'h0000, SRC_IP, dst_ip[31:16]}, 1'b0);

    // Cycle 4: dst_ip[15:0] + udp_src_port + udp_dst_port + udp_length
    send_cycle({dst_ip[15:0], SRC_PORT, dst_port, 16'h0018}, 1'b0);

    // Cycle 5: udp_checksum + msg_type + side + ticker_id + price[31:16]
    send_cycle({16'h0000, msg_type, side, ticker_id, price[31:16]}, 1'b0);

    // Cycle 6: price[15:0] + quantity + seq_num[31:16]
    send_cycle({price[15:0], quantity, sequence_num[31:16]}, 1'b0);

    // Cycle 7: seq_num[15:0] + padding (tlast=1)
    send_cycle({sequence_num[15:0], 48'h0}, 1'b0);
    
    // Cycle 8: dummy word to clock cycle 7 data through pipeline (tlast=1)
    send_cycle(64'h0, 1'b1);

    @(negedge clk);
    rx_tvalid = 1'b0;
    rx_tdata  = 64'h0;
    rx_tlast  = 1'b0;
    @(posedge clk);
endtask

    // =========================================================================
    // TASK: check signal_trigger and target_stock_price
    // Waits a few cycles after packet ends then samples outputs
    // =========================================================================
    task check_trigger(
    input logic        expect_trigger,
    input logic [31:0] expect_price,
    input string       test_name);

    // Wait long enough for the packet to fully process and latch
    repeat(15) @(posedge clk);
    #0.1;

    if (signal_trigger_latched === expect_trigger) begin
        $display("PASS [%s]: signal_trigger = %b as expected",
                  test_name, expect_trigger);
        pass_count++;
    end else begin
        $display("FAIL [%s]: signal_trigger = %b, expected %b",
                  test_name, signal_trigger_latched, expect_trigger);
        fail_count++;
    end

    if (expect_trigger) begin
        if (target_stock_price_reg === expect_price) begin
            $display("PASS [%s]: target_stock_price = %0d as expected",
                      test_name, target_stock_price_reg);
            pass_count++;
        end else begin
            $display("FAIL [%s]: target_stock_price = %0d, expected %0d",
                      test_name, target_stock_price_reg, expect_price);
            fail_count++;
        end
    end
endtask

    // =========================================================================
    // TASK: check dropped_packet_count
    // =========================================================================
    task check_drop_count(
    input logic [31:0] expected_count,
    input string       test_name
);
    // dropped_packet_count is registered so it holds its value -
    // just wait a few cycles for the last always_ff to settle
    repeat(5) @(posedge clk);
    if (dropped_packet_count === expected_count) begin
        $display("PASS [%s]: dropped_packet_count = %0d as expected",
                  test_name, dropped_packet_count);
        pass_count++;
    end else begin
        $display("FAIL [%s]: dropped_packet_count = %0d, expected %0d",
                  test_name, dropped_packet_count, expected_count);
        fail_count++;
    end
endtask

    // =========================================================================
    // MAIN TEST SEQUENCE
    // =========================================================================
    initial begin
        // Waveform dump for Vivado viewer
        $dumpfile("packet_parser_tb.vcd");
        $dumpvars(0, packet_parser_tb);

        // Initialize all inputs
        rst_n     = 1'b0;
        rx_tdata  = 64'h0;
        rx_tvalid = 1'b0;
        rx_tlast  = 1'b0;

        // Hold reset for 8 cycles
        repeat(8) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat(2) @(posedge clk);
        
        $monitor("t=%0t state=%s cnt=%0d tdata=%h tvalid=%b trigger=%b",
        $time, dut.current_state.name(), dut.cycle_counter,
        rx_tdata, rx_tvalid, signal_trigger);

        $display("============================================================");
        $display("  packet_parser_tb starting");
        $display("============================================================");

        // -----------------------------------------------------------------
        // TEST 1: Valid packet, price BELOW threshold - trigger should fire
        // price = 14000 ($140.00) < PRICE_THRESHOLD (15000)
        // -----------------------------------------------------------------
        $display("\n--- TEST 1: Valid packet, price below threshold ---");
        send_packet(
            .dst_mac      (DST_MAC),
            .ethertype    (16'h0800),
            .ip_protocol  (8'h11),
            .dst_ip       (DST_IP),
            .dst_port     (DST_PORT),
            .msg_type     (MSG_ADD),
            .side         (SIDE_BUY),
            .ticker_id    (TICKER_AAPL),
            .price        (32'd14000),
            .quantity     (32'd100),
            .sequence_num (32'd1)
        );
        check_trigger(1'b1, 32'd14000, "TEST1");
        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 2: Valid packet, price ABOVE threshold - trigger should NOT fire
//        // price = 16000 ($160.00) > PRICE_THRESHOLD (15000)
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 2: Valid packet, price above threshold ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd16000),
//            .quantity     (32'd100),
//            .sequence_num (32'd2)
//        );
//        check_trigger(1'b0, 32'd0, "TEST2");
//        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 3: Wrong destination MAC - should DROP
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 3: Wrong destination MAC ---");
//        send_packet(
//            .dst_mac      (48'hDE_AD_BE_EF_CA_FE),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd3)
//        );
//        check_trigger(1'b0, 32'd0, "TEST3");
//        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 4: Wrong EtherType (0x0806 = ARP) - should DROP
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 4: Wrong EtherType ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0806),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd4)
//        );
//        check_trigger(1'b0, 32'd0, "TEST4");
//        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 5: Wrong IP protocol (0x06 = TCP) - should DROP
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 5: Wrong IP protocol (TCP) ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h06),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd5)
//        );
//        check_trigger(1'b0, 32'd0, "TEST5");
//        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 6: Wrong destination IP - should DROP
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 6: Wrong destination IP ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (32'hC0_A8_01_FF),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd6)
//        );
//        check_trigger(1'b0, 32'd0, "TEST6");
//        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 7: Wrong UDP destination port - should DROP
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 7: Wrong UDP destination port ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (16'h0050),   // port 80
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd7)
//        );
//        check_trigger(1'b0, 32'd0, "TEST7");
//        idle_cycle(4);

//        // -----------------------------------------------------------------
//        // TEST 8: Wrong msg_type (Delete order) - should go IDLE quietly
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 8: Wrong msg_type (Delete) ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_DELETE),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd8)
//        );
//        check_trigger(1'b0, 32'd0, "TEST8");
//        idle_cycle(8);

//        // -----------------------------------------------------------------
//        // TEST 9: Sequence number gap - dropped_packet_count should increment
//        // Send sequence 10 after sequence 8, skipping 9
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 9: Sequence number gap ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd10)      // skipped 9
//        );
//        check_drop_count(32'd1, "TEST9");
//        idle_cycle(8);

//        // -----------------------------------------------------------------
//        // TEST 10: Two back-to-back valid packets - both should parse correctly
//        // -----------------------------------------------------------------
//        $display("\n--- TEST 10: Back-to-back valid packets ---");
//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd14000),
//            .quantity     (32'd100),
//            .sequence_num (32'd11)
//        );
//        check_trigger(1'b1, 32'd14000, "TEST10a");
//        idle_cycle(2);

//        send_packet(
//            .dst_mac      (DST_MAC),
//            .ethertype    (16'h0800),
//            .ip_protocol  (8'h11),
//            .dst_ip       (DST_IP),
//            .dst_port     (DST_PORT),
//            .msg_type     (MSG_ADD),
//            .side         (SIDE_BUY),
//            .ticker_id    (TICKER_AAPL),
//            .price        (32'd13500),
//            .quantity     (32'd200),
//            .sequence_num (32'd12)
//        );
//        check_trigger(1'b1, 32'd13500, "TEST10b");
//        idle_cycle(4);

        // -----------------------------------------------------------------
        // FINAL RESULTS
        // -----------------------------------------------------------------
        $display("\n============================================================");
        $display("  RESULTS: %0d passed, %0d failed", pass_count, fail_count);
        $display("============================================================");

        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED - check waveforms");

        $finish;
    end

endmodule