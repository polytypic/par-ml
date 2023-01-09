# Experimental parallel and concurrent OCaml

_*NOTE*_: There are multiple different approaches implemented in this
repository. See the different
[branches](https://github.com/polytypic/par-ml/branches/all).

This particular approach basically uses
[Treiber stacks](https://en.wikipedia.org/wiki/Treiber_stack) for work-stealing.
This gives low overhead and effective sharing of the last few work items.

TODO:

- Support for cancellation.
- `sleep` mechanism.
- Composable synchronization primitives (e.g. ability to `race` fibers).
- Various synchronization primitives (mutex, condition, ...) as examples.

## Benchmarks to be taken with plenty of salt

These have been run on Apple M1 with 4 + 4 cores (in normal mode).

> As an aside, let's assume cache size differences do not matter. As Apple M1
> has 4 cores at 3228 MHz and 4 cores at 2064 MHz, one could estimate that the
> best possible parallel speed up would be (4 \* (3228 + 2064)) / 3228 or
> roughly 6.5.

```sh
➜  P=FibFiber.exe; N=37; hyperfine --warmup 1 --shell none "$P --num-workers=1 $N" "$P --num-workers=2 $N" "$P --num-workers=4 $N" "$P --num-workers=8 $N"
Benchmark 1: FibFiber.exe --num-workers=1 37
  Time (mean ± σ):     868.3 ms ±   0.9 ms    [User: 865.1 ms, System: 2.6 ms]
  Range (min … max):   866.8 ms … 869.6 ms    10 runs

Benchmark 2: FibFiber.exe --num-workers=2 37
  Time (mean ± σ):     573.8 ms ±  12.2 ms    [User: 1139.3 ms, System: 3.6 ms]
  Range (min … max):   556.4 ms … 595.9 ms    10 runs

Benchmark 3: FibFiber.exe --num-workers=4 37
  Time (mean ± σ):     334.7 ms ±  15.1 ms    [User: 1316.3 ms, System: 5.6 ms]
  Range (min … max):   308.2 ms … 352.8 ms    10 runs

Benchmark 4: FibFiber.exe --num-workers=8 37
  Time (mean ± σ):     487.2 ms ±  27.7 ms    [User: 3149.2 ms, System: 63.5 ms]
  Range (min … max):   454.7 ms … 540.8 ms    10 runs

Summary
  'FibFiber.exe --num-workers=4 37' ran
    1.46 ± 0.11 times faster than 'FibFiber.exe --num-workers=8 37'
    1.71 ± 0.09 times faster than 'FibFiber.exe --num-workers=2 37'
    2.59 ± 0.12 times faster than 'FibFiber.exe --num-workers=1 37'
```

```sh
➜  P=FibPar.exe; N=37; hyperfine --warmup 1 --shell none "$P --num-workers=1 $N" "$P --num-workers=2 $N" "$P --num-workers=4 $N" "$P --num-workers=8 $N"
Benchmark 1: FibPar.exe --num-workers=1 37
  Time (mean ± σ):     627.6 ms ±   1.1 ms    [User: 624.8 ms, System: 2.2 ms]
  Range (min … max):   626.4 ms … 629.7 ms    10 runs

Benchmark 2: FibPar.exe --num-workers=2 37
  Time (mean ± σ):     423.1 ms ±   6.0 ms    [User: 838.3 ms, System: 2.8 ms]
  Range (min … max):   414.8 ms … 431.0 ms    10 runs

Benchmark 3: FibPar.exe --num-workers=4 37
  Time (mean ± σ):     247.6 ms ±   6.9 ms    [User: 966.3 ms, System: 5.6 ms]
  Range (min … max):   233.4 ms … 255.8 ms    12 runs

Benchmark 4: FibPar.exe --num-workers=8 37
  Time (mean ± σ):     544.6 ms ±  51.5 ms    [User: 3362.9 ms, System: 77.2 ms]
  Range (min … max):   482.3 ms … 647.2 ms    10 runs

Summary
  'FibPar.exe --num-workers=4 37' ran
    1.71 ± 0.05 times faster than 'FibPar.exe --num-workers=2 37'
    2.20 ± 0.22 times faster than 'FibPar.exe --num-workers=8 37'
    2.54 ± 0.07 times faster than 'FibPar.exe --num-workers=1 37'
```

In the following, the `fib_par` example of domainslib

```ocaml
let rec fib_par pool n =
  if n < 2 then n
  else
    let b = T.async pool (fun _ -> fib_par pool (n - 1)) in
    let a = fib_par pool (n - 2) in
    a + T.await pool b
```

has been modified as above

- to not drop down to sequential version (intention is to measure overheads),
- to perform better (using fewer `async`/`await`s), and
- to give same numerical result as the `par-ml` versions.

```sh
➜  P=fib_par.exe; N=37; hyperfine --warmup 1 --shell none "$P 1 $N" "$P 2 $N" "$P 4 $N" "$P 8 $N"
Benchmark 1: fib_par.exe 1 37
  Time (mean ± σ):      7.101 s ±  0.027 s    [User: 7.084 s, System: 0.017 s]
  Range (min … max):    7.065 s …  7.172 s    10 runs

Benchmark 2: fib_par.exe 2 37
  Time (mean ± σ):      4.647 s ±  0.038 s    [User: 9.264 s, System: 0.016 s]
  Range (min … max):    4.610 s …  4.712 s    10 runs

Benchmark 3: fib_par.exe 4 37
  Time (mean ± σ):      3.095 s ±  0.062 s    [User: 12.309 s, System: 0.018 s]
  Range (min … max):    3.028 s …  3.205 s    10 runs

Benchmark 4: fib_par.exe 8 37
  Time (mean ± σ):      4.950 s ±  0.053 s    [User: 36.023 s, System: 0.269 s]
  Range (min … max):    4.852 s …  5.040 s    10 runs

Summary
  'fib_par.exe 4 37' ran
    1.50 ± 0.03 times faster than 'fib_par.exe 2 37'
    1.60 ± 0.04 times faster than 'fib_par.exe 8 37'
    2.29 ± 0.05 times faster than 'fib_par.exe 1 37'
```
