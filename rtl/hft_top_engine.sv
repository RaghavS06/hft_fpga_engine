`timescale 1ns / 1ps
module hft_top_engine (
    input  logic        sys_clk_p,
    input  logic        sys_clk_n,
    input  logic        sys_reset_n,

    input  logic        sfp_rx_p,
    input  logic        sfp_rx_n,
    output logic        sfp_tx_p,
    output logic        sfp_tx_n,

    output logic [3:0]  status_leds
);

    // =========================================================================
    // 1. PCS/PMA CORE
    // sys_clk_p/n are MGTREFCLK pins - they feed directly into the PCS/PMA
    // core's internal IBUFDS_GTE2. Do NOT connect them to a general IBUFDS.
    // coreclk_out is our single system clock for everything downstream.
    // =========================================================================
    logic        coreclk;
    logic        pcs_resetdone;
    logic [63:0] xgmii_rxd;
    logic [7:0]  xgmii_rxc;
    logic [63:0] xgmii_txd;
    logic [7:0]  xgmii_txc;

    logic        drp_req;
    logic [15:0] drp_daddr_o, drp_di_o, drp_drpdo_o;
    logic        drp_den_o, drp_dwe_o, drp_drdy_o;

    ten_gig_eth_pcs_pma_0 u_pcs_pma (
        .refclk_p              (sys_clk_p),
        .refclk_n              (sys_clk_n),
        .dclk                  (coreclk),       // use coreclk for management too
        .coreclk_out           (coreclk),
        .reset                 (~pcs_resetdone),// self-releasing reset
        .resetdone_out         (pcs_resetdone),
        .xgmii_rxd             (xgmii_rxd),
        .xgmii_rxc             (xgmii_rxc),
        .xgmii_txd             (xgmii_txd),
        .xgmii_txc             (xgmii_txc),
        .rxp                   (sfp_rx_p),
        .rxn                   (sfp_rx_n),
        .txp                   (sfp_tx_p),
        .txn                   (sfp_tx_n),
        .signal_detect         (1'b1),
        .tx_fault              (1'b0),
        .sim_speedup_control   (1'b0),
        .pma_pmd_type          (3'b101),
        .mdc                   (1'b0),
        .mdio_in               (1'b0),
        .mdio_out              (),
        .mdio_tri              (),
        .prtad                 (5'b00000),
        .drp_gnt               (1'b0),
        .drp_den_i             (1'b0),
        .drp_dwe_i             (1'b0),
        .drp_daddr_i           (16'h0),
        .drp_di_i              (16'h0),
        .drp_drdy_i            (1'b0),
        .drp_drpdo_i           (16'h0),
        .drp_req               (drp_req),
        .drp_den_o             (drp_den_o),
        .drp_dwe_o             (drp_dwe_o),
        .drp_daddr_o           (drp_daddr_o),
        .drp_di_o              (drp_di_o),
        .drp_drdy_o            (drp_drdy_o),
        .drp_drpdo_o           (drp_drpdo_o),
        .rxrecclk_out          (),
        .qplloutclk_out        (),
        .qplloutrefclk_out     (),
        .qplllock_out          (),
        .txusrclk_out          (),
        .txusrclk2_out         (),
        .areset_datapathclk_out(),
        .gttxreset_out         (),
        .gtrxreset_out         (),
        .txuserrdy_out         (),
        .reset_counter_done_out(),
        .core_status           (),
        .tx_disable            ()
    );

    // =========================================================================
    // 2. RESET SYNCHRONIZER
    // sys_reset_n is asynchronous. Synchronize it into the coreclk domain.
    // Everything in this design runs on coreclk so one synchronizer covers all.
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) logic reset_sync_0, reset_sync_1;
    logic internal_reset_n;

    always_ff @(posedge coreclk or negedge sys_reset_n) begin
        if (!sys_reset_n) begin
            reset_sync_0 <= 1'b0;
            reset_sync_1 <= 1'b0;
        end else begin
            reset_sync_0 <= 1'b1;
            reset_sync_1 <= reset_sync_0;
        end
    end

    assign internal_reset_n = reset_sync_1;

    // =========================================================================
    // 3. HEARTBEAT LED
    // Runs on coreclk. At 156.25 MHz, bit 25 toggles at ~2.3 Hz.
    // =========================================================================
    logic [25:0] heartbeat_counter;

    always_ff @(posedge coreclk) begin
        if (!internal_reset_n) begin
            heartbeat_counter <= 26'd0;
            status_leds[0]    <= 1'b0;
        end else begin
            heartbeat_counter <= heartbeat_counter + 1'b1;
            status_leds[0]    <= heartbeat_counter[25];
        end
    end

    // =========================================================================
    // 4. MAC RESET
    // Parser and MAC only come out of reset after both:
    // - Board reset released (internal_reset_n high)
    // - GTX locked (pcs_resetdone high)
    // Both signals are already in coreclk domain so no CDC needed.
    // =========================================================================
    logic mac_reset_n;
    assign mac_reset_n = internal_reset_n & pcs_resetdone;

    // =========================================================================
    // 5. 10G ETHERNET MAC
    // =========================================================================
    logic [63:0] rx_axis_tdata;
    logic [7:0]  rx_axis_tkeep;
    logic        rx_axis_tvalid;
    logic        rx_axis_tlast;
    logic        rx_axis_tuser;
    logic        tx_axis_tready;

    eth_mac_10g #(
        .DATA_WIDTH    (64),
        .ENABLE_PADDING(1),
        .ENABLE_DIC    (1),
        .TX_USER_WIDTH (1),
        .RX_USER_WIDTH (1)
    ) u_eth_mac (
        .rx_clk        (coreclk),
        .rx_rst        (~mac_reset_n),
        .tx_clk        (coreclk),
        .tx_rst        (~mac_reset_n),
        .tx_axis_tdata (64'h0707070707070707),
        .tx_axis_tkeep (8'hFF),
        .tx_axis_tvalid(1'b0),
        .tx_axis_tready(tx_axis_tready),
        .tx_axis_tlast (1'b0),
        .tx_axis_tuser (1'b0),
        .rx_axis_tdata (rx_axis_tdata),
        .rx_axis_tkeep (rx_axis_tkeep),
        .rx_axis_tvalid(rx_axis_tvalid),
        .rx_axis_tlast (rx_axis_tlast),
        .rx_axis_tuser (rx_axis_tuser),
        .xgmii_rxd     (xgmii_rxd),
        .xgmii_rxc     (xgmii_rxc),
        .xgmii_txd     (xgmii_txd),
        .xgmii_txc     (xgmii_txc),
        .cfg_ifg       (8'd12),
        .cfg_tx_enable (1'b1),
        .cfg_rx_enable (1'b1)
    );

    // =========================================================================
    // 6. PACKET PARSER
    // =========================================================================
    logic        signal_trigger;
    logic [31:0] target_stock_price;
    logic [31:0] dropped_packet_count;
    logic        signal_trigger_latched;
    logic [31:0] target_stock_price_reg;

    packet_parser u_packet_parser (
        .clk                    (coreclk),
        .rst_n                  (mac_reset_n),
        .rx_tdata               (rx_axis_tdata),
        .rx_tvalid              (rx_axis_tvalid),
        .rx_tlast               (rx_axis_tlast),
        .signal_trigger         (signal_trigger),
        .target_stock_price     (target_stock_price),
        .dropped_packet_count   (dropped_packet_count),
        .signal_trigger_latched (signal_trigger_latched),
        .target_stock_price_reg (target_stock_price_reg)
    );

    // =========================================================================
    // 7. STATUS LEDS
    // =========================================================================
    assign status_leds[1] = pcs_resetdone;
    assign status_leds[2] = signal_trigger_latched;
    assign status_leds[3] = 1'b0;

endmodule