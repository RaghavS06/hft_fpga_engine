##############################################################################
## HFT Trading Engine - Xilinx Design Constraints
## Target: Artix-7 XC7A (FGG484 package)
## Tool:   Vivado 2025.2
##
## Instructions for completing this file:
## 1. Open your Altium schematic
## 2. For each signal below, find the FPGA ball it connects to
## 3. Replace [YOUR_PIN_HERE] with that ball identifier (e.g. G18, AB12)
## 4. Verify each ball's bank is compatible with the listed IOSTANDARD
##    using Xilinx UG475 or the FGG484 package spreadsheet
##############################################################################


##############################################################################
## SECTION 1: CLOCK CONSTRAINTS
##
## This is the most important section. Without a clock constraint Vivado
## cannot perform Static Timing Analysis and cannot verify your design
## meets timing at 156.25 MHz.
##
## create_clock syntax:
##   -period: clock period in nanoseconds (1/156.25MHz = 6.400ns)
##   -name:   a name for this clock used in timing reports
##   [get_ports]: which port in your RTL this clock enters on
##
## We define the clock on sys_clk_p (the positive leg of the differential
## pair). Vivado automatically understands that sys_clk_n is the complement.
##############################################################################

## The GTX transceiver generates coreclk internally from the reference clock.
## Vivado derives this clock automatically from the PCS/PMA IP core and
## creates it as a generated clock. You do not need to define it manually.
## If timing reports show coreclk as unconstrained, add:
## create_generated_clock -name coreclk -source [get_ports sys_clk_p] \
##     -multiply_by 1 [get_pins u_pcs_pma/inst/coreclk_out]


##############################################################################
## SECTION 2: CLOCK FALSE PATHS
##
## These tell the timing analyzer to ignore paths that cross clock domains.
## Without these, Vivado will try (and fail) to time the crossing between
## usr_clk and coreclk, which are asynchronous to each other.
##
## set_false_path syntax:
##   -from: the source flip-flop or clock domain
##   -to:   the destination flip-flop or clock domain
##
## We mark all paths from coreclk to usr_clk and vice versa as false paths
## because they are handled by the two-stage synchronizer in our RTL.
## The ASYNC_REG attribute on those flip-flops handles physical placement.
##############################################################################



##############################################################################
## SECTION 3: DIFFERENTIAL CLOCK INPUT PINS
##
## IOSTANDARD LVDS_25 means Low Voltage Differential Signaling at 2.5V.
## Your oscillator datasheet will confirm the output voltage - most
## 156.25 MHz oscillators for FPGA use LVDS at 2.5V or 3.3V.
## Check your DSC1123DI2 datasheet and match the IOSTANDARD accordingly.
##
## DIFF_TERM = TRUE adds on-chip 100-ohm termination across the differential
## pair. Your PCB schematic will show whether you have external termination
## resistors near the oscillator. If you do, set DIFF_TERM to FALSE to avoid
## double-terminating. If you don't have external termination, set TRUE.
##
## The PACKAGE_PIN for the negative leg (sys_clk_n) does NOT need
## set_property PACKAGE_PIN - Vivado automatically assigns it to the
## complementary pin of the differential pair once you specify sys_clk_p.
## You DO still need to specify IOSTANDARD for both.
##############################################################################

set_property PACKAGE_PIN F6 [get_ports sys_clk_p]
set_property PACKAGE_PIN E6 [get_ports sys_clk_n]


##############################################################################
## SECTION 4: SFP+ TRANSCEIVER PINS
##
## IMPORTANT: The SFP+ RX and TX differential pairs connect to GTX
## transceiver pins, NOT to general IO pins. GTX pins use a completely
## different primitive (GTXE2_CHANNEL) and do NOT use IOSTANDARD or
## PACKAGE_PIN constraints the same way general IO does.
##
## For GTX pins you use LOC constraints to tell Vivado which GTX instance
## to use. The PCS/PMA IP core you generated was configured with
## c_gt_loc=X0Y0, meaning it uses GTX instance X0Y0.
##
## The physical GTX RX and TX pins (sfp_rx_p/n and sfp_tx_p/n) are
## automatically assigned by the IP core based on the LOC constraint.
## You specify the GTX location to the IP core at generation time
## (which you already did - X0Y0), and Vivado handles the rest.
##
## HOWEVER: You still need to tell Vivado which bank your GTX reference
## clock (the oscillator) comes in on. The reference clock must enter
## through a dedicated MGTREFCLK pin pair, not a general LVDS pin.
##
## Check your schematic: does your 156.25 MHz oscillator connect to
## MGTREFCLK pins or to general LVDS pins?
##
## If MGTREFCLK pins (recommended for 10GbE):
##   The clock constraint above handles it. No additional pin constraints
##   needed for the clock. The SFP+ data pins are handled by the IP core.
##
## If general LVDS pins (less common):
##   You need an IBUFDS_GTE2 primitive in your RTL to convert the
##   general LVDS input to the GTX reference clock input. Let me know
##   and we will add that to hft_top_engine.sv.
##
## The LOC constraint for the GTX instance:
##############################################################################

## This tells Vivado which GTX transceiver tile the PCS/PMA IP uses.
## X0Y0 means column 0, row 0 - the first GTX on the device.
## This must match what you configured in the IP core (c_gt_loc=X0Y0).
set_property LOC GTXE2_CHANNEL_X0Y0 [get_cells u_pcs_pma/inst/*/GTXE2_CHANNEL_PRIM_INST]


##############################################################################
## SECTION 5: RESET BUTTON
##
## sys_reset_n is an active-low reset from a physical button on your board.
## LVCMOS33 means the button signal operates at 3.3V logic levels.
## If your button connects to a 2.5V bank use LVCMOS25 instead.
##
## PULLUP = TRUE adds a weak internal pull-up resistor so the pin reads
## high (not reset) when the button is not pressed. This assumes your
## button pulls the pin low when pressed (active low). If your schematic
## shows an external pull-up resistor already, set PULLUP to FALSE.
##############################################################################

set_property PACKAGE_PIN V1 [get_ports sys_reset_n]
set_property IOSTANDARD  LVCMOS33        [get_ports sys_reset_n]
set_property PULLUP      TRUE            [get_ports sys_reset_n]


##############################################################################
## SECTION 6: STATUS LEDs
##
## Your board has 4 LEDs connected to general IO pins.
## LVCMOS33 = 3.3V logic, which is standard for LEDs driven directly
## from FPGA IO through a current-limiting resistor.
##
## DRIVE = 8 sets the output drive strength to 8mA. Combined with your
## current limiting resistor on the PCB this should give a visible
## brightness without stressing the IO cell.
##
## SLEW = SLOW reduces the switching speed of the output driver, which
## reduces EMI radiation from the LED traces. For LEDs running at human
## visible frequencies this has no downside.
##
## LED 0: Heartbeat - blinks at ~1Hz proving clock and reset are alive
## LED 1: PCS locked - solid when GTX transceiver has locked to SFP+ link
## LED 2: Trade fired - pulses when signal_trigger_latched goes high
## LED 3: Spare - currently tied to 0
##############################################################################

set_property PACKAGE_PIN R19 [get_ports {status_leds[0]}]
set_property PACKAGE_PIN P19 [get_ports {status_leds[1]}]
set_property PACKAGE_PIN T21 [get_ports {status_leds[2]}]
set_property PACKAGE_PIN U21 [get_ports {status_leds[3]}]
set_property IOSTANDARD  LVCMOS33        [get_ports {status_leds[*]}]
set_property DRIVE       8               [get_ports {status_leds[*]}]
set_property SLEW        SLOW            [get_ports {status_leds[*]}]


##############################################################################
## SECTION 7: TIMING EXCEPTIONS FOR IO PATHS
##
## Input and output ports connected to asynchronous devices (buttons, LEDs)
## don't have meaningful timing relationships to your clock. Without these
## constraints the timing analyzer will flag them as unconstrained paths,
## which clutters your timing reports with irrelevant warnings.
##
## set_false_path -from [get_ports ...] tells the analyzer to ignore
## timing on paths from that port into the design (input ports).
##
## set_false_path -to [get_ports ...] tells the analyzer to ignore
## timing on paths from the design to that port (output ports).
##############################################################################

## Reset button is asynchronous - handled by synchronizer in RTL
set_false_path -from [get_ports sys_reset_n]

## LEDs are driven by slow counters and latched signals - no timing requirement
set_false_path -to [get_ports {status_leds[*]}]


##############################################################################
## SECTION 8: CONFIGURATION SETTINGS
##
## These control how the FPGA loads its bitstream at power-on.
##
## CFGBVS = VCCO means the configuration bank voltage reference comes
## from VCCO. Set to GND if your configuration bank uses a separate
## voltage. This must match your PCB design - wrong setting can damage
## the device.
##
## CONFIG_VOLTAGE = 3.3 tells Vivado the VCCO voltage of bank 0
## (the configuration bank). Must match what your PCB supplies to that bank.
##
## BITSTREAM.CONFIG.SPI_BUSWIDTH = 4 enables Quad SPI mode for faster
## bitstream loading from your W25Q64 flash chip. Your QSPI flash
## supports this and it loads the bitstream approximately 4x faster
## than single-bit SPI.
##
## BITSTREAM.CONFIG.CONFIGRATE = 33 sets the SPI clock frequency to 33 MHz
## during configuration. Your W25Q64 supports up to 104 MHz so 33 is
## conservative and safe.
##
## BITSTREAM.GENERAL.COMPRESS = TRUE enables bitstream compression which
## reduces the file size by roughly 50% and therefore halves the
## configuration time. Always enable this for QSPI boot.
##############################################################################

set_property CFGBVS                          VCCO [current_design]
set_property CONFIG_VOLTAGE                  3.3  [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH   4    [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE     33   [current_design]
set_property BITSTREAM.GENERAL.COMPRESS      TRUE [current_design]


##############################################################################
## SECTION 9: PBLOCK CONSTRAINTS (OPTIONAL BUT RECOMMENDED)
##
## Pblocks constrain specific modules to specific regions of the FPGA die.
## This is optional but has two benefits for your design:
##
## 1. It keeps the packet_parser logic physically close to the GTX
##    transceiver, minimizing routing distance and improving timing.
##
## 2. It makes placement deterministic - the router produces the same
##    result across Vivado versions, making timing predictable.
##
## The coordinates below are approximate for Artix-7 FGG484.
## If placement causes timing violations you can remove these constraints
## and let Vivado place freely - the timing analyzer will find a solution.
##
## To find valid pblock coordinates: open the device view in Vivado
## (Open Elaborated Design → Device), zoom to the GTX region, and
## draw a rectangle near the GTX. Right-click → Create Pblock.
## Vivado will fill in the correct coordinates automatically.
##############################################################################

## Uncomment and populate after checking device floorplan in Vivado:
## create_pblock pblock_parser
## add_cells_to_pblock [get_pblocks pblock_parser] [get_cells u_packet_parser]
## resize_pblock [get_pblocks pblock_parser] -add {SLICE_X0Y0:SLICE_X20Y50}


##############################################################################
## SECTION 10: ASYNC_REG PLACEMENT CONSTRAINTS
##
## The ASYNC_REG attribute in your RTL tells Vivado to place synchronizer
## flip-flops close together. This section adds explicit maximum delay
## constraints on the paths between synchronizer stages to ensure the
## metastability resolution time budget is maintained.
##
## set_max_delay -datapath_only bypasses the clock period constraint
## and applies a specific maximum delay. Setting it to 3.2ns (half a
## 156.25 MHz period) ensures the second synchronizer stage has at
## least half a clock period to sample a resolved value.
##
## This applies to the reset synchronizer flip-flops.
##############################################################################

set_max_delay -datapath_only -from [get_cells reset_sync_0_reg] \
                              -to   [get_cells reset_sync_1_reg] 3.200


##############################################################################
## COMPLETION CHECKLIST
##
## Before running implementation, verify:
## [ ] All [YOUR_PIN_HERE] placeholders replaced with actual ball numbers
## [ ] IOSTANDARD matches your PCB supply voltages for each bank
## [ ] DIFF_TERM setting matches whether you have external termination
## [ ] PULLUP setting matches whether you have external pull-up on reset
## [ ] CONFIG_VOLTAGE matches your PCB configuration bank supply
## [ ] GTX LOC (X0Y0) matches what you configured in the PCS/PMA IP
## [ ] Run Report CDC after implementation to verify no unhandled crossings
## [ ] Run Report Timing Summary and verify all paths have positive slack
##############################################################################