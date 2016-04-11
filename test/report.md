# Benchmark Report

## Job Properties

*Commit(s):* [jrevels/julia@25c3659d6cec2ebf6e6c7d16b03adac76a47b42a](https://github.com/jrevels/julia/commit/25c3659d6cec2ebf6e6c7d16b03adac76a47b42a) vs [JuliaLang/julia@bb73f3489d837e3339fce2c1aab283d3b2e97a4c](https://github.com/JuliaLang/julia/commit/bb73f3489d837e3339fce2c1aab283d3b2e97a4c)

*Tag Predicate:* `"arrays"`

*Triggered By:* [link](www.example.com)

## Results

Below is a table of this job's results. If available, the data used to generate this
table can be found in the JSON file in this directory.

Benchmark definitions can be found in [JuliaCI/BaseBenchmarks.jl](https://github.com/JuliaCI/BaseBenchmarks.jl).

The percentages accompanying time and memory values in the below table are noise tolerances. The "true"
time/memory value for a given benchmark is expected to fall within this percentage of the reported value.

The values in the below table take the form `primary_result / comparison_result`. A ratio greater than
`1.0` denotes a possible regression (marked with :x:), while a ratio less than `1.0` denotes
a possible improvement (marked with :white_check_mark:).

Only significant results - results that indicate possible regressions or improvements - are shown below
(thus, an empty table means that all benchmark results remained invariant between builds).

| Group ID | Benchmark ID | time ratio | memory ratio |
|----------|--------------|------------|--------------|
| `"g"` | `("y",1)` | 2.00 (5.0%) :x: | 0.00 (5.0%) :white_check_mark: |
| `"g"` | `("y",2)` | 0.50 (5.0%) :white_check_mark: | 1.00 (5.0%)  |
| `"g"` | `"z"` | 1.00 (60.0%)  | 5.00 (27.0%) :x: |

## Version Info

#### Primary Build

```
Julia Version 0.4.3-pre+6
Commit adffe19 (2015-12-11 00:38 UTC)
Platform Info:
  System: Darwin (x86_64-apple-darwin13.4.0)
  CPU: Intel(R) Core(TM) i5-4288U CPU @ 2.60GHz
  WORD_SIZE: 64
  uname: Darwin 13.4.0 Darwin Kernel Version 13.4.0: Wed Dec 17 19:05:52 PST 2014; root:xnu-2422.115.10~1/RELEASE_X86_64 x86_64 i386
Memory: 8.0 GB (1025.07421875 MB free)
Uptime: 646189.0 sec
Load Avg:  1.38427734375  1.416015625  1.41455078125
Intel(R) Core(TM) i5-4288U CPU @ 2.60GHz:
       speed         user         nice          sys         idle          irq
#1  2600 MHz     186848 s          0 s     114241 s    1462955 s          0 s
#2  2600 MHz     114716 s          0 s      43882 s    1605408 s          0 s
#3  2600 MHz     189864 s          0 s      77629 s    1496513 s          0 s
#4  2600 MHz     114652 s          0 s      42497 s    1606856 s          0 s

  BLAS: libopenblas (USE64BITINT DYNAMIC_ARCH NO_AFFINITY Haswell)
  LAPACK: libopenblas64_
  LIBM: libopenlibm
  LLVM: libLLVM-3.3

```

#### Comparison Build

```
Julia Version 0.4.3-pre+6
Commit adffe19 (2015-12-11 00:38 UTC)
Platform Info:
  System: Darwin (x86_64-apple-darwin13.4.0)
  CPU: Intel(R) Core(TM) i5-4288U CPU @ 2.60GHz
  WORD_SIZE: 64
  uname: Darwin 13.4.0 Darwin Kernel Version 13.4.0: Wed Dec 17 19:05:52 PST 2014; root:xnu-2422.115.10~1/RELEASE_X86_64 x86_64 i386
Memory: 8.0 GB (1025.07421875 MB free)
Uptime: 646189.0 sec
Load Avg:  1.38427734375  1.416015625  1.41455078125
Intel(R) Core(TM) i5-4288U CPU @ 2.60GHz:
       speed         user         nice          sys         idle          irq
#1  2600 MHz     186848 s          0 s     114241 s    1462955 s          0 s
#2  2600 MHz     114716 s          0 s      43882 s    1605408 s          0 s
#3  2600 MHz     189864 s          0 s      77629 s    1496513 s          0 s
#4  2600 MHz     114652 s          0 s      42497 s    1606856 s          0 s

  BLAS: libopenblas (USE64BITINT DYNAMIC_ARCH NO_AFFINITY Haswell)
  LAPACK: libopenblas64_
  LIBM: libopenlibm
  LLVM: libLLVM-3.3

```

## Benchmark Group List

Here's a list of all the benchmark groups executed by this job:

- `"g"`
