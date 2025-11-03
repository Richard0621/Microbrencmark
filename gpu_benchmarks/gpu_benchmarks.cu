// gpu_benchmarks.cu
// GPU microbenchmarks: naive GEMM (compute-bound) and 3D stencil (memory-bound)
// Uses Google Benchmark for repetition and NVML for power/temperature.
// Writes results to results_gpu.csv

#include <benchmark/benchmark.h>
#include <cuda_runtime.h>
#include <nvml.h>

#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// Small helper timestamp
static std::string getTimestamp() {
    auto t = std::chrono::system_clock::now();
    auto tt = std::chrono::system_clock::to_time_t(t);
    std::ostringstream oss;
    oss << std::put_time(std::localtime(&tt), "%Y-%m-%dT%H:%M:%S");
    return oss.str();
}

// --------------------- NVML wrapper ---------------------
class GPUMonitor {
public:
    GPUMonitor(int dev = 0) : device_index(dev), nvml_inited(false), nvml_dev(0) {
        nvmlReturn_t r = nvmlInit();
        if (r == NVML_SUCCESS) {
            nvml_inited = true;
            if (nvmlDeviceGetHandleByIndex(device_index, &nvml_dev) != NVML_SUCCESS) {
                nvml_inited = false;
            }
        }
    }

    ~GPUMonitor() {
        if (nvml_inited) nvmlShutdown();
    }

    // Power in milliwatts, returns 0 on failure
    unsigned int getPowerMilliWatts() const {
        if (!nvml_inited) return 0;
        unsigned int power = 0;
        if (nvmlDeviceGetPowerUsage(nvml_dev, &power) != NVML_SUCCESS) return 0;
        return power;
    }

    // Temperature in Celsius, returns -1 on failure
    int getTemperatureC() const {
        if (!nvml_inited) return -1;
        unsigned int temp = 0;
        if (nvmlDeviceGetTemperature(nvml_dev, NVML_TEMPERATURE_GPU, &temp) != NVML_SUCCESS) return -1;
        return static_cast<int>(temp);
    }

private:
    int device_index;
    bool nvml_inited;
    nvmlDevice_t nvml_dev;
};

// --------------------- CSV helper ---------------------
static void appendCsvRow(const std::string &path, const std::string &row) {
    std::ofstream ofs(path, std::ios::app);
    if (!ofs) return;
    ofs << row << "\n";
}

// --------------------- GPU kernels ---------------------
// Naive GEMM: each thread computes one C[row,col]
__global__ void gemm_naive(const float* A, const float* B, float* C, int M, int K, int N) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (row < M && col < N) {
        float sum = 0.0f;
        for (int k = 0; k < K; ++k) {
            sum += A[row * K + k] * B[k * N + col];
        }
        C[row * N + col] = sum;
    }
}

// 7-point 3D stencil (interior points only)
__global__ void stencil3d_7point(const float* src, float* dst, int X, int Y, int Z) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x <= 0 || y <= 0 || z <= 0 || x >= X-1 || y >= Y-1 || z >= Z-1) return;
    int idx = (z * Y + y) * X + x;
    float center = src[idx];
    float xp = src[idx + 1];
    float xm = src[idx - 1];
    float yp = src[idx + X];
    float ym = src[idx - X];
    float zp = src[idx + X*Y];
    float zm = src[idx - X*Y];
    // simple average-based update
    dst[idx] = 0.5f * center + 0.0833333f * (xp + xm + yp + ym + zp + zm);
}

// --------------------- Benchmarks ---------------------
// GEMM benchmark: measures GFLOPS, time, energy, temp, occupancy, EDP
static void BM_GEMM_GPU(benchmark::State& state) {
    const int M = static_cast<int>(state.range(0));
    const int K = static_cast<int>(state.range(1));
    const int N = static_cast<int>(state.range(2));

    const size_t sizeA = static_cast<size_t>(M) * K;
    const size_t sizeB = static_cast<size_t>(K) * N;
    const size_t sizeC = static_cast<size_t>(M) * N;

    // Host buffers (single precision)
    std::vector<float> hA(sizeA, 1.0f);
    std::vector<float> hB(sizeB, 1.0f);
    std::vector<float> hC(sizeC, 0.0f);

    // Device buffers
    float *dA = nullptr, *dB = nullptr, *dC = nullptr;
    cudaMalloc(&dA, sizeA * sizeof(float));
    cudaMalloc(&dB, sizeB * sizeof(float));
    cudaMalloc(&dC, sizeC * sizeof(float));

    cudaMemcpy(dA, hA.data(), sizeA * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(dB, hB.data(), sizeB * sizeof(float), cudaMemcpyHostToDevice);

    // kernel launch params
    dim3 block(16, 16);
    dim3 grid((N + block.x - 1) / block.x, (M + block.y - 1) / block.y);

    // monitor
    GPUMonitor mon(0);

    // occupancy estimation
    cudaDeviceProp prop; cudaGetDeviceProperties(&prop, 0);
    int activeBlocksPerSM = 0;
    cudaOccupancyMaxActiveBlocksPerMultiprocessor(&activeBlocksPerSM, (const void*)gemm_naive, block.x * block.y, 0);
    int activeThreadsPerSM = activeBlocksPerSM * (block.x * block.y);
    float occupancy = 0.0f;
    if (prop.maxThreadsPerMultiProcessor > 0) occupancy = 100.0f * (float)activeThreadsPerSM / (float)prop.maxThreadsPerMultiProcessor;

    for (auto _ : state) {
        // sample power before
        unsigned int p_before_mw = mon.getPowerMilliWatts();

        cudaEvent_t start, stop; cudaEventCreate(&start); cudaEventCreate(&stop);
        cudaEventRecord(start);

        // launch
        gemm_naive<<<grid, block>>>(dA, dB, dC, M, K, N);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float ms = 0.0f; cudaEventElapsedTime(&ms, start, stop);
        double time_s = ms / 1000.0;

        unsigned int p_after_mw = mon.getPowerMilliWatts();
        double avg_power_w = ((double)p_before_mw + (double)p_after_mw) / 2.0 / 1000.0; // W
        double energy_j = avg_power_w * time_s;

        // GFLOPS: 2*M*N*K ops
        double gflops = (2.0 * (double)M * (double)N * (double)K) / (time_s * 1e9);

        // EDP
        double edp = energy_j * time_s;

        int temp_c = mon.getTemperatureC();

        // write CSV row
        std::ostringstream row;
        row << getTimestamp() << ",GEMM," << M << "," << K << "," << N << ","
            << std::fixed << std::setprecision(3) << ms << "," << gflops << ","
            << energy_j << "," << temp_c << "," << occupancy << "," << edp;
        appendCsvRow("results_gpu.csv", row.str());

        // record time for Google Benchmark reporting
        state.SetIterationTime(time_s);

        cudaEventDestroy(start); cudaEventDestroy(stop);
    }

    // cleanup
    cudaMemcpy(hC.data(), dC, sizeC * sizeof(float), cudaMemcpyDeviceToHost);
    cudaFree(dA); cudaFree(dB); cudaFree(dC);

    // report theoretical FLOPS for google-benchmark
    state.SetItemsProcessed(int64_t(state.iterations()) * int64_t(2) * M * N * K);
}

// Stencil 3D benchmark: memory-bound kernel
static void BM_Stencil3D_GPU(benchmark::State& state) {
    const int dim = static_cast<int>(state.range(0));
    const int X = dim, Y = dim, Z = dim;
    const size_t N = (size_t)X * Y * Z;

    std::vector<float> hA(N, 1.0f);
    std::vector<float> hB(N, 0.0f);

    float *dSrc = nullptr, *dDst = nullptr;
    cudaMalloc(&dSrc, N * sizeof(float));
    cudaMalloc(&dDst, N * sizeof(float));
    cudaMemcpy(dSrc, hA.data(), N * sizeof(float), cudaMemcpyHostToDevice);

    dim3 block(8, 8, 8);
    dim3 grid((X + block.x - 1) / block.x, (Y + block.y - 1) / block.y, (Z + block.z - 1) / block.z);

    GPUMonitor mon(0);

    // simple occupancy estimate
    cudaDeviceProp prop; cudaGetDeviceProperties(&prop, 0);
    int activeBlocksPerSM = 0;
    cudaOccupancyMaxActiveBlocksPerMultiprocessor(&activeBlocksPerSM, (const void*)stencil3d_7point, block.x * block.y * block.z, 0);
    int activeThreadsPerSM = activeBlocksPerSM * (block.x * block.y * block.z);
    float occupancy = 0.0f;
    if (prop.maxThreadsPerMultiProcessor > 0) occupancy = 100.0f * (float)activeThreadsPerSM / (float)prop.maxThreadsPerMultiProcessor;

    for (auto _ : state) {
        unsigned int p_before = mon.getPowerMilliWatts();

        cudaEvent_t start, stop; cudaEventCreate(&start); cudaEventCreate(&stop);
        cudaEventRecord(start);

        stencil3d_7point<<<grid, block>>>(dSrc, dDst, X, Y, Z);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);

        float ms = 0.0f; cudaEventElapsedTime(&ms, start, stop);
        double time_s = ms / 1000.0;

        unsigned int p_after = mon.getPowerMilliWatts();
        double avg_power_w = ((double)p_before + (double)p_after) / 2.0 / 1000.0;
        double energy_j = avg_power_w * time_s;

        // Estimate memory traffic: each interior point reads 7 floats and writes 1 float -> 8 * 4 bytes
        double bytes = double((X-2)*(Y-2)*(Z-2)) * 8.0 * 4.0;
        double bandwidth_GBps = (bytes / time_s) / 1e9;

        double edp = energy_j * time_s;
        int temp_c = mon.getTemperatureC();

        std::ostringstream row;
        row << getTimestamp() << ",STENCIL3D," << X << "," << Y << "," << Z << ","
            << std::fixed << std::setprecision(3) << ms << "," << bandwidth_GBps << ","
            << energy_j << "," << temp_c << "," << occupancy << "," << edp;
        appendCsvRow("results_gpu.csv", row.str());

        state.SetIterationTime(time_s);

        cudaEventDestroy(start); cudaEventDestroy(stop);
    }

    cudaMemcpy(hB.data(), dDst, N * sizeof(float), cudaMemcpyDeviceToHost);
    cudaFree(dSrc); cudaFree(dDst);

    state.SetItemsProcessed(int64_t(state.iterations()) * int64_t((X-2)*(Y-2)*(Z-2)));
}

// Register benchmarks with sensible sizes
BENCHMARK(BM_GEMM_GPU)->Args({128, 128, 128})->Args({256,256,256})->Args({512,512,512})->UseManualTime();
BENCHMARK(BM_Stencil3D_GPU)->Arg(64)->Arg(96)->Arg(128)->UseManualTime();

// main
int main(int argc, char** argv) {
    // create CSV header if not present
    std::ofstream ofs("results_gpu.csv", std::ios::app);
    if (ofs.tellp() == 0) {
        ofs << "timestamp,benchmark,M,K,N,time_ms,perf,energy_j,temp_c,occupancy,edp\n";
    }
    ofs.close();

    benchmark::Initialize(&argc, argv);
    benchmark::RunSpecifiedBenchmarks();
    return 0;
}
