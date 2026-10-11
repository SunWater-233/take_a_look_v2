typedef unsigned int u32;
typedef struct { float gain; int count; u32 samples[4]; } Control;
volatile Control first = {1.5f, 3, {1, 2, 3, 4}};
volatile Control second = {2.5f, 5, {5, 6, 7, 8}};
volatile int *pointer = &first.count;
enum Mode { idle, running };
volatile enum Mode mode = running;
int main(void) {
  first.count += second.samples[1];
  second.count += first.count;
  return first.count;
}
