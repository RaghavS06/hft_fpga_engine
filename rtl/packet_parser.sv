`timescale 1ns / 1ps
module packet_parser (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [63:0] rx_tdata,
    input  logic        rx_tvalid,
    input  logic        rx_tlast,
    output logic        signal_trigger,
    output logic [31:0] target_stock_price,
    output logic [31:0] dropped_packet_count,
    output logic        signal_trigger_latched,
    output logic [31:0] target_stock_price_reg
);

    // =========================================================================
    // STATE DEFINITIONS
    // =========================================================================
    typedef enum logic [2:0] {
        STATE_IDLE    = 3'b000,
        STATE_ETH     = 3'b001,
        STATE_IP      = 3'b010,
        STATE_UDP     = 3'b011,
        STATE_PAYLOAD = 3'b100,
        STATE_DROP    = 3'b101
    } state_t;

    state_t current_state, next_state;
    logic [3:0] cycle_counter;

    // =========================================================================
    // PIPELINE REGISTERS & ALIGNED BUS
    // =========================================================================
    logic [63:0] data_reg_current, data_reg_past;

    // Eth header is 14 bytes. IP starts at byte 14 = 6 bytes into cycle 2.
    // Past register contributes its last 2 bytes, current contributes its first 6 bytes.
    logic [63:0] aligned_data;
    assign aligned_data = {data_reg_past[15:0], data_reg_current[63:16]};

    // Full UDP header: upper 4 bytes from aligned_data (udp_length + checksum),
    // lower 4 bytes from data_reg_past (udp_src_port + udp_dest_port)
    logic [63:0] full_udp_head;
    //assign full_udp_head = {aligned_data[63:32], data_reg_past[31:0]};
    assign full_udp_head = {data_reg_past[47:0], data_reg_current[63:48]};

    // Payload window: past register bytes 5-0, current register bytes 7-6
    logic [63:0] payload_data;
    assign payload_data = {data_reg_past[47:0], data_reg_current[63:48]};


   
    // =========================================================================
    // PIPELINE REGISTER UPDATE
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            data_reg_current <= 64'h0;
            data_reg_past    <= 64'h0;
        end else if (rx_tvalid) begin
            data_reg_past    <= data_reg_current;
            data_reg_current <= rx_tdata;
        end
    end
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            signal_trigger_latched <= 1'b0;
        end else begin
            if (signal_trigger) 
                signal_trigger_latched <= 1'b1;
            else if (current_state == STATE_ETH)
                signal_trigger_latched <= 1'b0;
        end
    end
    

    // =========================================================================
    // PROTOCOL STRUCTS
    // =========================================================================
    typedef struct packed {
        logic [47:0] destination_mac;
        logic [15:0] source_mac_high;
    } eth_head_0_t;

    typedef struct packed {
        logic [31:0] source_mac_low;
        logic [15:0] ether_type;
        logic [15:0] ip_start_junk;
    } eth_head_1_t;

    typedef struct packed {
        logic [3:0]  version;
        logic [3:0]  ihl;
        logic [7:0]  tos;
        logic [15:0] total_length;
        logic [15:0] id;
        logic [2:0]  flags;
        logic [12:0] frag_offset;
    } ip_head_0_t;

    typedef struct packed {
        logic [7:0]  ttl;
        logic [7:0]  protocol;
        logic [15:0] header_checksum;
        logic [31:0] src_ip;
    } ip_head_1_t;

    typedef struct packed {
        logic [31:0] dest_ip;
        logic [31:0] extra_udp_head;
    } ip_head_2_t;

    typedef struct packed {
        logic [15:0] udp_src_port;
        logic [15:0] udp_dest_port;
        logic [15:0] udp_length;
        logic [15:0] udp_checksum;
    } udp_head_t;

    typedef struct packed {
        logic [7:0]  msg_type;
        logic [7:0]  side;
        logic [15:0] ticker_id;
        logic [31:0] price;
    } payload_head_0_t;

    typedef struct packed {
        logic [31:0] quantity;
        logic [31:0] sequence_num;
    } payload_head_1_t;

    // =========================================================================
    // PERMANENT WIRE ASSIGNMENTS
    // =========================================================================
    eth_head_0_t   eth0;     assign eth0     = data_reg_current;
    eth_head_1_t   eth1;     assign eth1     = data_reg_current;
    ip_head_0_t    ip0;      assign ip0      = aligned_data;
    ip_head_1_t    ip1;      assign ip1      = aligned_data;
    ip_head_2_t    ip2;      assign ip2      = aligned_data;
    udp_head_t     udp0;     assign udp0     = full_udp_head;
    payload_head_0_t payload0; assign payload0 = payload_data;
    payload_head_1_t payload1; assign payload1 = payload_data;

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================
    localparam PRICE_THRESHOLD = 32'd15000; // Trigger if price < $150.00

    logic [31:0] price_reg;
    logic [31:0] last_sequence_num;

    // Latch price from payload cycle 0, update sequence number on payload cycle 1
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            price_reg              <= 32'h0;
            last_sequence_num      <= 32'h0;
            target_stock_price_reg <= 32'h0;
        end else if (rx_tvalid) begin
            if (current_state == STATE_PAYLOAD && cycle_counter == 4'd1 && payload0.msg_type == 8'h41)
                price_reg <= payload0.price;
    
            if (current_state == STATE_PAYLOAD && cycle_counter == 4'd2) begin
                target_stock_price_reg <= price_reg;
                last_sequence_num <= payload1.sequence_num;
                end else if (current_state == STATE_ETH) begin
                    target_stock_price_reg <= 32'd0;
            end
        end
    end

    // Dropped packet counter - increments on sequence gap detection
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dropped_packet_count <= 32'h0;
        end else if (rx_tvalid && current_state == STATE_PAYLOAD
                && cycle_counter == 4'd2
                && payload1.sequence_num != last_sequence_num + 1) begin
            dropped_packet_count <= dropped_packet_count + 1;
        end
    end

    // =========================================================================
    // FSM - SEQUENTIAL
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_state <= STATE_IDLE;
            cycle_counter <= 4'h0;
        end else begin
            current_state <= next_state;
            if (current_state != next_state)
                cycle_counter <= 4'h1;
            else if (rx_tvalid)
                cycle_counter <= cycle_counter + 1'b1;
        end
    end

    // =========================================================================
    // FSM - COMBINATIONAL
    // =========================================================================
    always_comb begin
        // Defaults to prevent latch generation
        next_state         = current_state;
        signal_trigger     = 1'b0;
        target_stock_price = 32'h0;

        case (current_state)

            // -----------------------------------------------------------------
            // STATE_IDLE: Wait for packet
            // -----------------------------------------------------------------
            STATE_IDLE: begin
                if (rx_tvalid)
                    next_state = STATE_ETH;
            end

            // -----------------------------------------------------------------
            // STATE_ETH: Parse 14-byte Ethernet header (2 raw cycles)
            // Cycle 0: verify destination MAC
            // Cycle 1: verify EtherType == 0x0800 (IPv4)
            // -----------------------------------------------------------------
            STATE_ETH: begin
                if (rx_tvalid) begin
                    if (cycle_counter == 4'd1) begin
                        if (eth0.destination_mac == 48'h00_11_22_33_44_55)
                            next_state = STATE_ETH;
                        else
                            next_state = STATE_DROP;
                    end else if (cycle_counter == 4'd2) begin
                        if (eth1.ether_type == 16'h0800)
                            next_state = STATE_IP;
                        else
                            next_state = STATE_DROP;
                    end
                end
            end

            // -----------------------------------------------------------------
            // STATE_IP: Parse 20-byte IPv4 header (3 aligned cycles)
            // Cycle 0: verify version == 4, IHL == 5
            // Cycle 1: verify protocol == 0x11 (UDP)
            // Cycle 2: verify destination IP
            // -----------------------------------------------------------------
            STATE_IP: begin
                if (rx_tvalid) begin
                    if (cycle_counter == 4'd1) begin
                        if (ip0.version == 4'd4 && ip0.ihl == 4'd5)
                            next_state = STATE_IP;
                        else
                            next_state = STATE_DROP;
                    end else if (cycle_counter == 4'd2) begin
                        if (ip1.protocol == 8'h11)
                            next_state = STATE_IP;
                        else
                            next_state = STATE_DROP;
                    end else if (cycle_counter == 4'd3) begin
                        if (ip2.dest_ip == 32'hC0_A8_01_0A)
                            next_state = STATE_UDP;
                        else
                            next_state = STATE_DROP;
                    end
                end
            end

            // -----------------------------------------------------------------
            // STATE_UDP: Parse 8-byte UDP header (1 cycle via full_udp_head)
            // Verify destination port == 5000 (0x1388)
            // -----------------------------------------------------------------
            STATE_UDP: begin
            if (rx_tvalid) begin
                    if (udp0.udp_dest_port == 16'h1388) 
                        next_state = STATE_PAYLOAD;
                    else
                        next_state = STATE_DROP;
                end
            end

            // -----------------------------------------------------------------
            // STATE_PAYLOAD: Extract market data and fire execution signal
            // Cycle 0: validate msg_type, price latched into price_reg via always_ff
            // Cycle 1: output price, fire trigger if below threshold,
            //          flag sequence gap if detected
            // -----------------------------------------------------------------
            STATE_PAYLOAD: begin
                if (rx_tvalid) begin
                    if (cycle_counter == 4'd1) begin
                        if (payload0.msg_type == 8'h41)
                            next_state = STATE_PAYLOAD;
                        else
                            next_state = STATE_IDLE;
                    end else if (cycle_counter == 4'd2) begin
                        target_stock_price = price_reg;
                        if (price_reg < PRICE_THRESHOLD)
                            signal_trigger = 1'b1;
                            next_state = STATE_IDLE;
                    end
                end
            end

            // -----------------------------------------------------------------
            // STATE_DROP: Drain remainder of invalid packet, return to idle
            // -----------------------------------------------------------------
            STATE_DROP: begin
                if (rx_tvalid && rx_tlast)
                    next_state = STATE_IDLE;
            end

            default: next_state = STATE_IDLE;

        endcase
        
        
    end

endmodule