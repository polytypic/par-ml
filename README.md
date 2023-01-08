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

These have been run on Apple M1 with 4 + 4 cores (in normal mode).

> As an aside, let's assume cache size differences do not matter. As Apple M1
> has 4 cores at 3228 MHz and 4 cores at 2064 MHz, one could estimate that the
> best possible parallel speed up would be (4 \* (3228 + 2064)) / 3228 or
> roughly 6.5.

```sh
➜  P=FibFiber.exe; N=37; hyperfine "$P --num-workers=1 $N" "$P --num-workers=2 $N" "$P --num-workers=4 $N" "$P --num-workers=8 $N"
Benchmark 1: FibFiber.exe --num-workers=1 37
  Time (mean ± σ):      1.367 s ±  0.001 s    [User: 1.362 s, System: 0.004 s]
  Range (min … max):    1.366 s …  1.368 s    10 runs

Benchmark 2: FibFiber.exe --num-workers=2 37
  Time (mean ± σ):     732.0 ms ±   0.6 ms    [User: 1450.1 ms, System: 4.2 ms]
  Range (min … max):   731.0 ms … 732.8 ms    10 runs

Benchmark 3: FibFiber.exe --num-workers=4 37
  Time (mean ± σ):     395.8 ms ±   2.6 ms    [User: 1532.5 ms, System: 9.2 ms]
  Range (min … max):   393.2 ms … 400.6 ms    10 runs

Benchmark 4: FibFiber.exe --num-workers=8 37
  Time (mean ± σ):     666.5 ms ±  21.0 ms    [User: 4258.6 ms, System: 127.3 ms]
  Range (min … max):   621.3 ms … 695.0 ms    10 runs

Summary
  'FibFiber.exe --num-workers=4 37' ran
    1.68 ± 0.05 times faster than 'FibFiber.exe --num-workers=8 37'
    1.85 ± 0.01 times faster than 'FibFiber.exe --num-workers=2 37'
    3.45 ± 0.02 times faster than 'FibFiber.exe --num-workers=1 37'
```

```sh
➜  P=FibPar.exe; N=37; hyperfine "$P --num-workers=1 $N" "$P --num-workers=2 $N" "$P --num-workers=4 $N" "$P --num-workers=8 $N"
Benchmark 1: FibPar.exe --num-workers=1 37
  Time (mean ± σ):      1.030 s ±  0.011 s    [User: 1.027 s, System: 0.003 s]
  Range (min … max):    1.017 s …  1.046 s    10 runs

Benchmark 2: FibPar.exe --num-workers=2 37
  Time (mean ± σ):     617.6 ms ±   0.8 ms    [User: 1221.4 ms, System: 3.8 ms]
  Range (min … max):   615.9 ms … 618.9 ms    10 runs

Benchmark 3: FibPar.exe --num-workers=4 37
  Time (mean ± σ):     332.8 ms ±   2.0 ms    [User: 1282.0 ms, System: 8.3 ms]
  Range (min … max):   329.8 ms … 336.0 ms    10 runs

Benchmark 4: FibPar.exe --num-workers=8 37
  Time (mean ± σ):     749.9 ms ±  48.8 ms    [User: 4698.4 ms, System: 143.7 ms]
  Range (min … max):   682.1 ms … 853.9 ms    10 runs

Summary
  'FibPar.exe --num-workers=4 37' ran
    1.86 ± 0.01 times faster than 'FibPar.exe --num-workers=2 37'
    2.25 ± 0.15 times faster than 'FibPar.exe --num-workers=8 37'
    3.10 ± 0.04 times faster than 'FibPar.exe --num-workers=1 37'
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
