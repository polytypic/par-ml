# Experimental parallel and concurrent OCaml

Compared to [lockfree](https://github.com/ocaml-multicore/lockfree)
work-stealing deque:

- Only
  [a single atomic variable](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.ml#L12)
  is used (closer to
  [original paper](https://www.semanticscholar.org/paper/Dynamic-circular-work-stealing-deque-Chase-Lev/f856a996e7aec0ea6db55e9247a00a01cb695090)).
- A level of (pointer) indirection is avoided by using
  [a different technique to release stolen elements](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.ml#L37-L46).
- [`mark` and `drop_at` operations](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.mli#L20-L25)
  are provided to allow owner to remove elements from deque without dropping to
  main loop (see
  [here](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L156)
  and
  [here](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L164),
  for example).

Compared to [domainslib](https://github.com/ocaml-multicore/domainslib):

- A more general
  [`Suspend` effect](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L9)
  is used to allow synchronization primitives to be built on top of the
  scheduler.
- The pool of workers is not exposed. The idea is that there is only one system
  level pool of workers to be used by all parallel and concurrent code.
  [`Domain.self ()` is used as index](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.ml#L90)
  and are assumed to be consecutive numbers in the range `[0, n[`.
- A lower overhead
  [`par` operation](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/Par.mli#L4-L6)
  is provided for parallel execution. It avoids need to maintain a list of
  readers.

TODO:

- Is the
  [work-stealing deque](https://github.com/polytypic/par-ml/blob/d64a7f5941409b3ce56a91912075ac27fdc5341f/src/main/DCYL.ml)
  implementation correct?
- Implement more scalable wake-up mechanism.
- Support for cancellation.
- `sleep` mechanism.
- Composable synchronization primitives (e.g. ability to `race` fibers).
- Various synchronization primitives (mutex, condition, ...) as examples.

## Benchmarks to be taken with plenty of salt

These have been run on Apple M1 with 4 + 4 cores in low power mode.

```sh
➜  N=37; hyperfine "FibFiber.exe --num-workers=1 $N" "FibFiber.exe --num-workers=2 $N" "FibFiber.exe --num-workers=4 $N" "FibFiber.exe --num-workers=8 $N"
Benchmark 1: FibFiber.exe --num-workers=1 37
  Time (mean ± σ):      1.241 s ±  0.009 s    [User: 1.236 s, System: 0.003 s]
  Range (min … max):    1.223 s …  1.250 s    10 runs

Benchmark 2: FibFiber.exe --num-workers=2 37
  Time (mean ± σ):     923.8 ms ±  12.2 ms    [User: 1832.2 ms, System: 5.0 ms]
  Range (min … max):   907.7 ms … 935.9 ms    10 runs

Benchmark 3: FibFiber.exe --num-workers=4 37
  Time (mean ± σ):     570.7 ms ±  66.0 ms    [User: 2234.5 ms, System: 8.4 ms]
  Range (min … max):   547.5 ms … 758.6 ms    10 runs

  Warning: Statistical outliers were detected. Consider re-running this benchmark on a quiet PC without any interferences from other programs. It might help to use the '--warmup' or '--prepare' options.

Benchmark 4: FibFiber.exe --num-workers=8 37
  Time (mean ± σ):     695.6 ms ±  89.2 ms    [User: 4779.8 ms, System: 93.7 ms]
  Range (min … max):   597.8 ms … 823.5 ms    10 runs

Summary
  'FibFiber.exe --num-workers=4 37' ran
    1.22 ± 0.21 times faster than 'FibFiber.exe --num-workers=8 37'
    1.62 ± 0.19 times faster than 'FibFiber.exe --num-workers=2 37'
    2.17 ± 0.25 times faster than 'FibFiber.exe --num-workers=1 37'
```

```sh
➜  N=37; hyperfine "FibPar.exe --num-workers=1 $N" "FibPar.exe --num-workers=2 $N" "FibPar.exe --num-workers=4 $N" "FibPar.exe --num-workers=8 $N"
Benchmark 1: FibPar.exe --num-workers=1 37
  Time (mean ± σ):     897.8 ms ±   8.3 ms    [User: 894.3 ms, System: 2.7 ms]
  Range (min … max):   889.8 ms … 908.4 ms    10 runs

Benchmark 2: FibPar.exe --num-workers=2 37
  Time (mean ± σ):     862.6 ms ±   3.8 ms    [User: 1709.9 ms, System: 4.6 ms]
  Range (min … max):   858.6 ms … 869.8 ms    10 runs

Benchmark 3: FibPar.exe --num-workers=4 37
  Time (mean ± σ):     528.5 ms ±   2.1 ms    [User: 2064.4 ms, System: 8.8 ms]
  Range (min … max):   525.9 ms … 532.0 ms    10 runs

Benchmark 4: FibPar.exe --num-workers=8 37
  Time (mean ± σ):     780.6 ms ± 351.1 ms    [User: 5359.7 ms, System: 110.4 ms]
  Range (min … max):   602.0 ms … 1740.9 ms    10 runs

  Warning: Statistical outliers were detected. Consider re-running this benchmark on a quiet PC without any interferences from other programs. It might help to use the '--warmup' or '--prepare' options.

Summary
  'FibPar.exe --num-workers=4 37' ran
    1.48 ± 0.66 times faster than 'FibPar.exe --num-workers=8 37'
    1.63 ± 0.01 times faster than 'FibPar.exe --num-workers=2 37'
    1.70 ± 0.02 times faster than 'FibPar.exe --num-workers=1 37'
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
➜  N=37; hyperfine "fib_par.exe 1 $N" "fib_par.exe 2 $N" "fib_par.exe 4 $N" "fib_par.exe 8 $N"
Benchmark 1: fib_par.exe 1 37
  Time (mean ± σ):      7.027 s ±  0.059 s    [User: 7.006 s, System: 0.018 s]
  Range (min … max):    6.966 s …  7.098 s    10 runs

Benchmark 2: fib_par.exe 2 37
  Time (mean ± σ):      4.690 s ±  0.128 s    [User: 9.351 s, System: 0.016 s]
  Range (min … max):    4.617 s …  5.042 s    10 runs

Benchmark 3: fib_par.exe 4 37
  Time (mean ± σ):      3.087 s ±  0.061 s    [User: 12.275 s, System: 0.019 s]
  Range (min … max):    3.020 s …  3.181 s    10 runs

Benchmark 4: fib_par.exe 8 37
  Time (mean ± σ):      5.011 s ±  0.127 s    [User: 36.348 s, System: 0.272 s]
  Range (min … max):    4.861 s …  5.257 s    10 runs

Summary
  'fib_par.exe 4 37' ran
    1.52 ± 0.05 times faster than 'fib_par.exe 2 37'
    1.62 ± 0.05 times faster than 'fib_par.exe 8 37'
    2.28 ± 0.05 times faster than 'fib_par.exe 1 37'
```
