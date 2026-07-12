# HFT FPGA Trading Engine ⚡

A 10 Gbps hardware-accelerated market data parser built on a custom Artix-7 PCB. The goal was to build something that resembles what actual HFT firms run in their data centers — a dedicated FPGA card that sits on the network, parses incoming market data packets entirely in silicon, and fires a trade execution signal in under 150 nanoseconds. No CPU, no operating system, no software stack in the critical path.

This has been my main project this summer and honestly the most technically challenging thing I've built. It touches everything — PCB design, high-speed signal integrity, RTL design, network protocols, timing closure, and clock domain crossing. I learned a ton.

---

## What It Does

When a market data packet arrives on the SFP+ port, the FPGA processes it through a full hardware pipeline:

1. The GTX transceiver deserializes the 10.3125 Gbps serial stream into 64-bit parallel words at 156.25 MHz
2. The 10G Ethernet MAC strips the preamble, validates the CRC, and presents clean AXI-Stream data
3. My custom packet parser FSM validates the full Ethernet/IPv4/UDP header stack in hardware
4. If the packet passes all checks and the payload price crosses the threshold, `signal_trigger` fires

Total latency from first byte arriving at the SFP+ pin to `signal_trigger` asserting: **~115-150 nanoseconds**. That's the tick-to-trade latency.

---

## Architecture
<!-- INSERT: architecture block diagram image here -->

---

## The PCB

I designed a custom 4-layer PCB in Altium Designer from scratch. This was my first time doing a board with a BGA component and high-speed differential pairs and it was genuinely difficult — lots of hours spent on signal integrity, stackup design, and BGA escape routing.

<!-- INSERT: Altium 3D render of board here -->
<!-- INSERT: PCB layout screenshot showing SFP+ differential pairs and BGA -->

**Board specs:**
- **FPGA:** Xilinx Artix-7 XC7A35T (FGG484 BGA, 484 balls, 1.0mm pitch)
- **Clock:** Microchip DSC1123DI2 — 156.25 MHz LVDS differential oscillator
- **Flash:** Winbond W25Q64 QSPI — stores bitstream for autonomous boot
- **Power chain:** USB-C → USBLC6 ESD protection → TPS25942 eFuse → TPS62130 buck regulators (1.0V VCCINT, 1.8V VCCAUX, 3.3V IO)
- **Interface:** SFP+ cage for 10GBASE-R fiber or DAC cable
- **Layers:** 4-layer stackup — Signal / GND / PWR / Signal
- **Surface finish:** ENIG (required for BGA soldering and SFP+ trace quality)
- **Manufacturer:** PCBWay with turnkey SMT assembly

**Signal integrity features:**
- 100Ω differential impedance control on SFP+ TX/RX pairs
- Ground via shielding fence alongside SFP+ differential traces
- Perimeter BGA escape routing with via-in-pad for power balls
- Bypass capacitors placed directly under FPGA on inner layers

---

## The Packet Parser

The core of the project is `packet_parser.sv` — an 8-state FSM that processes one 64-bit word per clock cycle.

STATE_IDLE → STATE_ETH → STATE_IP → STATE_UDP → STATE_PAYLOAD → STATE_IDLE
↓
STATE_DROP (on any validation failure)

**The alignment problem:**

Ethernet headers are 14 bytes. On a 64-bit (8-byte) bus that means IP headers start 6 bytes into the third raw cycle — not on a natural 64-bit boundary. I solved this with a two-register pipeline and a combinational alignment bus:

```systemverilog
// Shift the bus forward by 6 bytes (48 bits) to align IP headers
assign aligned_data = {data_reg_past[15:0], data_reg_current[63:16]};
```

Everything from the IP header onwards reads from `aligned_data` through packed structs:

```systemverilog
typedef struct packed {
    logic [3:0]  version;
    logic [3:0]  ihl;
    logic [7:0]  tos;
    logic [15:0] total_length;
    logic [15:0] id;
    logic [2:0]  flags;
    logic [12:0] frag_offset;
} ip_head_0_t;

ip_head_0_t ip0;
assign ip0 = aligned_data;  // permanently wired, not a register write
```

**What gets validated per state:**

| State | Checks |
|-------|--------|
| STATE_ETH | Destination MAC == board MAC, EtherType == 0x0800 (IPv4) |
| STATE_IP | Version == 4, IHL == 5, Protocol == 0x11 (UDP), Dest IP == board IP |
| STATE_UDP | Destination port == configured trading port (0x1388) |
| STATE_PAYLOAD | msg_type == 0x41 (Add Order), price vs threshold comparison |

**The payload format** is modeled after NASDAQ ITCH message framing — fixed width, byte-aligned, fits in exactly two 64-bit words:

Byte  0:    msg_type     (0x41 = Add Order, 0x44 = Delete)
Byte  1:    side         (0x42 = Buy, 0x53 = Sell)
Bytes 2-3:  ticker_id    (16-bit symbol)
Bytes 4-7:  price        (32-bit fixed point, cents × 100)
Bytes 8-11: quantity     (32-bit share count)
Bytes 12-15: sequence_num (32-bit packet counter for drop detection)

If price < threshold and msg_type == Add Order, `signal_trigger` fires for one clock cycle and `target_stock_price_reg` latches the price for readout.

<!-- INSERT: Vivado waveform screenshot showing signal_trigger firing -->

---

## Clock Domain Crossing

One of the things I'm most proud of understanding on this project is CDC. The design has two clock domains:

- **coreclk** (156.25 MHz, recovered by GTX CDR from incoming serial data) — drives MAC and parser
- **Management domain** — reset synchronizer, heartbeat LED

The key insight is that coreclk is recovered from the incoming data stream by the GTX Clock and Data Recovery circuit. It's phase-aligned with the received data, which is why the MAC and parser must run on it. If I ran the parser on an independent oscillator clock instead, the two clocks would be asynchronous and I'd get metastability — the parser could sample data mid-transition and produce garbage.

For the reset crossing I implemented async-assert synchronous-deassert:

```systemverilog
(* ASYNC_REG = "TRUE" *) logic reset_sync_0, reset_sync_1;

always_ff @(posedge coreclk or negedge sys_reset_n) begin
    if (!sys_reset_n) begin
        reset_sync_0 <= 1'b0;  // assert immediately (async)
        reset_sync_1 <= 1'b0;
    end else begin
        reset_sync_0 <= 1'b1;
        reset_sync_1 <= reset_sync_0;  // deassert after 2 clean edges (sync)
    end
end
```

The `ASYNC_REG` attribute tells Vivado to physically colocate these flip-flops to minimize routing delay between them, maximizing the time available for metastability resolution.

---

## Testbench

I wrote a self-checking testbench in SystemVerilog that constructs real Ethernet/IP/UDP packets byte by byte, drives them into the parser at the correct timing, and automatically verifies the outputs.

The packet construction was tricky — the bytes have to land in exactly the right 64-bit bus windows to match what the aligned_data logic produces. I spent a lot of time debugging this with the Vivado waveform viewer tracing individual bytes through the pipeline registers.

**Test cases:**

| Test | Input | Expected |
|------|-------|----------|
| 1 | Valid packet, price below threshold | signal_trigger fires, correct price output |
| 2 | Valid packet, price above threshold | No trigger |
| 3 | Wrong destination MAC | STATE_DROP |
| 4 | Wrong EtherType (ARP) | STATE_DROP |
| 5 | Wrong IP protocol (TCP) | STATE_DROP |
| 6 | Wrong destination IP | STATE_DROP |
| 7 | Wrong UDP port | STATE_DROP |
| 8 | Wrong msg_type (Delete order) | STATE_IDLE, no trigger |
| 9 | Sequence number gap (skipped seq 9) | dropped_packet_count increments |
| 10 | Back-to-back valid packets | Both parse correctly |

<!-- INSERT: Vivado simulation screenshot showing all tests passing -->

---

## Hardware Note

During implementation I discovered that the XC7A35T uses GTP transceivers rated to 6.6 Gbps maximum per Xilinx DS180, while 10GBASE-R requires 10.3125 Gbps. The design is fully validated in simulation. A production deployment would target a Kintex-7 or XC7A200T which have GTX transceivers rated to 12.5 Gbps. Everything else — the parser RTL, CDC architecture, AXI-Stream interface, testbench — is completely hardware-independent and valid.

---

## Tools & Stack

| Category | Tools |
|----------|-------|
| RTL | SystemVerilog |
| Synthesis & Implementation | Vivado 2025.2 |
| Simulation | Vivado XSim |
| PCB Design | Altium Designer |
| Packet Injection | Python + Scapy |
| IP Cores | Xilinx 10G Ethernet PCS/PMA, Alex Forencich verilog-ethernet |

---

---

## What I Learned

This project taught me more than any class has. Some specific things that clicked:

**On hardware design:** You can't just think about what your code does — you have to think about what circuit it becomes. The difference between `always_ff` and `always_comb` isn't syntax, it's the difference between flip-flops and logic gates in silicon.

**On signal integrity:** At 10 Gbps a few millimeters of trace length difference between differential pair halves will cause eye closure. Signal integrity isn't something you add at the end — it has to be designed in from the start.

**On CDC:** Metastability is a real physical phenomenon, not a simulation artifact. Two flip-flops on different clocks will eventually disagree and the result is genuinely unpredictable. Gray code and two-stage synchronizers aren't bureaucratic best practices — they're necessary for the hardware to work correctly.

**On debugging:** When something doesn't work, the answer is almost never where you first look. Add `$monitor` statements, look at the waveforms, trace signals back to first principles. The waveform viewer became my best friend.

---

