GPU Microbenchmarks (CUDA)
=================================

This folder contains two example GPU microbenchmarks that pair Google Benchmark with NVML for power/temperature sampling and simple CSV output.

Files
- `gpu_benchmarks.cu` : CUDA source with two benchmarks:
  - `BM_GEMM_GPU` : naive GEMM kernel (compute-bound) measuring GFLOPS, time, energy, temperature, occupancy and EDP.
  - `BM_Stencil3D_GPU` : 7-point 3D stencil (memory-bound) estimating bandwidth, energy, temperature and EDP.

Build

Requirements:
- CUDA toolkit (nvcc)
- Google Benchmark library installed and linkable
- NVML available (comes with NVIDIA driver), link with `-lnvidia-ml`

Example compile (adjust include/library paths as needed):

```bash
# replace /path/to/benchmark/include and /path/to/benchmark/lib with your paths
nvcc -O3 gpu_benchmarks.cu -o gpu_benchmarks \
    -I/path/to/benchmark/include -L/path/to/benchmark/lib -lbenchmark -lpthread -lnvidia-ml
```

Run

NVML power reads require that NVIDIA drivers are present. Root is not strictly required for NVML but some system configs may restrict access.

```bash
./gpu_benchmarks --benchmark_repetitions=5
```

Output
- `results_gpu.csv` will be appended with rows containing timestamp, benchmark, sizes, time_ms, perf (GFLOPS or GB/s), energy_j, temperature, occupancy, and EDP.

Notes & Caveats
- The GEMM kernel is deliberately naive to expose compute-bound behavior. For production or baselines, compare against cuBLAS.
- Energy is approximated by sampling instantaneous NVML power before/after the kernel and taking the time-weighted average.
- Occupancy is estimated via `cudaOccupancyMaxActiveBlocksPerMultiprocessor` and is intended as a relative indicator.
- Kernel launches use moderate block sizes; tune `block` dimensions for your GPU.

Next steps
- Add a small CMake target to build the benchmark alongside your existing build system.
- Add more advanced GPU metrics (SM utilization, memory throughput counters) via CUPTI if needed.
