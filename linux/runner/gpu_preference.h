#ifndef RUNNER_GPU_PREFERENCE_H_
#define RUNNER_GPU_PREFERENCE_H_

// Call before creating GtkApplication or any graphics contexts. The probe is
// a separate process so a broken offload driver cannot poison the real app.
bool HandleGpuProbe(int argc, char** argv, int* exit_code);
void PreferHighPerformanceGpu(char** argv);

#endif  // RUNNER_GPU_PREFERENCE_H_
