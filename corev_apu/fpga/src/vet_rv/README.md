# VET-RV FPGA integration RTL

These sources implement the lossless pre-commit evidence path used by the
SATI VET-RV Genesys 2 experiments. They are kept in dependency order by the
top-level `Makefile` and instantiated by `../ariane_xilinx.sv`.

The initial `sati` branch import is byte-identical to the hash-locked M4 RTL in
SATI commit `3d27177acf6b76ed130436dfb661562cc3436699`. The finite protected
sink contains 4,095 32-bit words (195 complete frames); it is a bounded
experiment sink, not a general unbounded production transport.
