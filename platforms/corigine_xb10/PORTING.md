# FireSim Port: Corigine XB-10

This document captures the design decisions, gotchas, and implementation
notes from porting FireSim to the Corigine XB-10 FPGA board. It is meant
to help future maintainers reason about why the port is shaped the way
it is, beyond what the code itself reveals.

## Board overview

- **FPGA**: Xilinx Virtex UltraScale+ `xcvu19p-fsvb3824-2-e` (VU19P).
- **DDR4**: 1x 64-bit channel, `MT40A1G16RC-062E`, 250 MHz reference
  clock (single channel — u250 has four 300 MHz channels).
- **PCIe**: Gen3 x16 with 100 MHz refclk.
- **Resets**: Two active-low board resets — `resetn` and `pcie_perstn`.
- **Config flash**: Quad SPI `MT25QU02GCBB8E12` (2 Gb, 1.8V supply).
  JTAG via Digilent USB is also supported as the alternate config path.

## Reference material

- `/scratch/raghavgupta/project_xb10/xb10.tcl` — 525-line block-design
  tcl from a reference Vivado project targeting the XB-10. This is the
  ground-truth for all IP configs, port frequencies, and BD connections.
- `/scratch/raghavgupta/project_xb10/XB-10 User Guide V1.1.pdf` —
  vendor user guide. Section 2.2 (config modes), section 2.4 (SPI
  flash part), and the bank voltage table were the primary sources
  for the bitstream config XDC.
- `/nscratch/fpga-cluster/x10/` — vendor example designs (`xb10_exdes`
  and the wrapper). Used to cross-check XDC pin names.
- `platforms/xilinx_alveo_u250/` — structural template for the entire
  FireSim side of the port.

## Top-level decisions

### No Xilinx board file

There is no `xilinx.com:*:xb10:*` board file. The u250 flow leans
heavily on the board file for DDR4/PCIe/clock/reset pin constraints.
For XB-10 we instead:

- Leave `board_part` empty in `cl_firesim/scripts/xb10.tcl`.
- Drop `*_BOARD_INTERFACE` properties from IP configs (set them to
  `Custom`).
- Ship an explicit `cl_firesim/design/xb10_pins.xdc` (copied from the
  reference project)
  and wire it into both `synth_fileset` and `impl_fileset` in
  `main.tcl`. See the "Pin XDC fileset routing" note below.

### Collapsed `bd_lib` to a single unversioned layout

u250's `bd_lib/` has per-Vivado-version subdirectories (`2021.1`,
`2021.2`, `2022.1`, `2022.2`, `2023.1`), but those files are
byte-identical across versions. We collapsed them to a single
`bd_lib/{create_bd_instances,create_bd_interfaces,create_bd_connections,ip_mod_list}.tcl`
and patched `create_bd.tcl::get_bd_lib_file` to ignore the version
segment. This port only targets Vivado 2025.1, so the version
fan-out would be dead weight.

### No Aurora / QSFP

The reference BD has no Aurora and `overall_fpga_top.v` does not wire
any QSFP. All Aurora IPs, AXIS converters/FIFOs, and the Aurora exdes
helper from the u250 template were removed rather than carried as
dead code. The Scala `CorigineXB10Config` overrides
`F1ShimHasQSFPPorts => false` so Golden Gate does not emit QSFP
ports on the F1Shim boundary.

### Dynamic XDMA VLNV lookup

Different Vivado releases pin XDMA to different version suffixes
(e.g. `4.1`, `5.0`). Rather than hard-coding one, `create_bd_instances.tcl`
picks the latest installed version:

```tcl
set xdma_vlnv [lindex [lsort -dictionary [get_ipdefs xilinx.com:ip:xdma:*]] end]
```

This keeps the port portable across Vivado upgrades without churning
the tcl.

## Bitstream config (`bitstream_config.xdc`)

The final properties are:

```tcl
set_property CONFIG_VOLTAGE 1.8                        [current_design]
set_property CONFIG_MODE SPIx4                         [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK Enable    [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE           [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES        [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR Yes       [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4           [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup         [current_design]
```

Why each one:

- `CONFIG_VOLTAGE 1.8` — the config banks use `VCC_1_8V` per the user
  guide's bank-voltage table.
- `CONFIG_MODE SPIx4` — the XB-10 boots from its on-board Quad SPI
  flash; SPIx4 matches the flash part's 4-bit interface.
- `SPI_32BIT_ADDR Yes` — the MT25QU02GCBB8E12 is 2 Gb, which exceeds
  the 24-bit address space, so 32-bit addressing is required.
- **`SPI_BUSWIDTH 4` — gotcha**: setting `SPI_32BIT_ADDR Yes` silently
  resets `SPI_BUSWIDTH` to 1. `write_cfgmem` for `spix4` then fails
  with `[Writecfgmem 68-20] SPI_BUSWIDTH property is set to "1" ...
  has to be set to "4"`. `SPI_BUSWIDTH 4` must be set **after**
  `SPI_32BIT_ADDR` in the XDC to stick.
- `CONFIGFALLBACK Enable`, `COMPRESS TRUE`, `SPI_FALL_EDGE YES`,
  `UNUSEDPIN Pullup` — standard Xilinx defaults for SPI-flash boot,
  carried over from the u250 reference.

The `xb10_exdes.xdc` vendor example under `/nscratch/fpga-cluster/x10/`
only sets `CONFIG_VOLTAGE 1.8` because that example project only ships
a `.bit` (JTAG flow). FireSim needs an `.mcs` for flash programming,
so the full SPIx4 block is required.

## Pin XDC fileset routing

`xb10_pins.xdc` contains both `create_clock` entries (needed during
synthesis) and `PACKAGE_PIN` / `IOSTANDARD` properties (needed during
implementation). `main.tcl` adds it to **both** `synth_fileset` and
`impl_fileset` **after** the `USED_IN` foreach loops that set the
other XDCs to synth-only or impl-only. This preserves the default
"used in both" semantics for the pin XDC. See the comment block
around the `check_file_exists ... xb10_pins.xdc` call.

## DDR4 IP

Config mirrors the reference project's `xb10.tcl` verbatim. Notable settings:

- `No_Controller 1` — despite the name, this is **not** PHY-only mode.
  `PHY_MODE` stays `Complete_Memory_Controller`. The u250 config
  ends up at the same value via defaults.
- `DDR4_EN_PARITY true`, `DDR4_DataMask DM_NO_DBI`,
  `DDR4_Mem_Add_Map ROW_COLUMN_BANK_INTLV` — all taken from
  `xb10.tcl`.
- `C0_CLOCK_BOARD_INTERFACE Custom`, `C0_DDR4_BOARD_INTERFACE Custom`,
  `RESET_BOARD_INTERFACE Custom` — no board file to source these from.

## FireSim-side integration

- `deploy/buildtools/bitbuilder.py` — added `CorigineXB10BitBuilder`
  subclassing `XilinxAlveoBitBuilder` (same dispatch pattern as u200/u280).
- `deploy/bit-builder-recipes/corigine_xb10.yaml` — new recipe, mirrors
  the u250 one with `bit_builder_type: CorigineXB10BitBuilder`.
- `sim/make/fpga.mk`, `sim/make/driver.mk` — added `corigine_xb10`
  branches for `board_dir` and driver compilation.
- `sim/midas/src/main/cc/simif_corigine_xb10.cc` — symlink to
  `simif_xilinx_alveo_u250.cc` (XDMA driver is board-agnostic, matches
  the u200/u280 symlink pattern).
- `sim/midas/src/main/scala/midas/Config.scala` — `CorigineXB10Config`
  inherits from `XilinxAlveoU250Config` with
  `F1ShimHasQSFPPorts => false` override.
- `sim/midas/src/main/scala/configs/CompilerConfigs.scala` —
  `BaseCorigineXB10Config` wraps `CorigineXB10Config` with the usual
  transform stack.
- `.github/scripts/utils.py` — `FpgaPlatform.corigine_xb10` enum entry.
- `.github/scripts/check-docs-generated-components.py` — parallel
  branch for `corigine_xb10` in the platform matching.

## Known gotchas (if you hit these, check here first)

1. **`write_cfgmem` fails with "SPI_BUSWIDTH ... has to be set to 4"** —
   `SPI_32BIT_ADDR Yes` is resetting `SPI_BUSWIDTH`. Make sure the
   `SPI_BUSWIDTH 4` line comes after it in `bitstream_config.xdc`.
2. **Vivado can't find XDMA IP** — `create_bd_instances.tcl` does a
   dynamic `get_ipdefs` lookup. If the IP catalog is stale,
   `report_ip_status` in `main.tcl` will surface it before BD creation
   runs.
3. **`validate_bd_design` complains about unconnected clock ports** —
   the clock fanout in `create_bd_connections.tcl` is specifically
   tuned to match `xb10.tcl`. Don't mirror u250's fanout pattern —
   u250 has 4 DDR channels and different refclks.
4. **`overall_fpga_top` has unconnected `io_qsfp_*` ports after
   elaboration** — `F1ShimHasQSFPPorts` didn't get overridden. Check
   the Config ordering in `CorigineXB10Config` — `++` makes the left
   side win on conflicts, so the override must be on the left of
   `new XilinxAlveoU250Config`.

## Runtime deployment (not yet done)

`firesim buildbitstream` works end-to-end. `firesim runworkload` does
not yet — the `deploy/firesim` CLI has a literal `elif
args.platform == ...` chain around line 187 that needs a branch for
`corigine_xb10`, and there is no `CorigineXB10InstanceDeployManager`
equivalent yet. This is a follow-up once a bitstream has been
successfully programmed and brought up on real hardware.
