# SATI / VET-RV integration branch

The `sati` branch carries the CVA6-side implementation used by the VET-RV
experiments in the SATI superproject.

## Reproducible base

This branch starts from CVA6 `v5.3.0`, commit
`2ef1c1b1fca419354920c5487293bc605294904e`. That commit is an ancestor of the
fork's `master` branch and is the exact version used by the recorded Demo,
Verilator, Vivado 2025.2, and Genesys 2 evidence. At migration time the fork's
`master` was 184 commits newer; the frozen experiment patches did not apply to
that tip, so rebasing onto it would require a separate complete revalidation.

## Integrated experiment features

- D1 post-commit RVFI sidecar and XLEN-correct interrupt-cause decoding;
- D1.5 fetch/decode/resolve/flush observation monitor;
- D1.6 lossless pre-commit request/grant/fire admission, including closure of
  architectural side effects and a tag-sticky simulation sink; and
- deterministic Verilator lifecycle and plusarg support for both observation
  and admission traces.

The implementation was migrated from the hash-locked patches and RTL in SATI
commit `3d27177acf6b76ed130436dfb661562cc3436699`. Generated Vivado projects,
runtime metadata, and Windows symlink materializations are not source changes
and are excluded.

## Validation boundary

The SATI repository owns the Docker entrypoints, workloads, independent
comparators, FPGA overlays, constraints, board scripts, and evidence index.
This branch owns the CVA6-side source. A future merge or rebase onto a newer
CVA6 `master` must rerun the full Demo gate and all CVA6/Vivado/Genesys 2
experiments before any prior result is claimed for the new base.
