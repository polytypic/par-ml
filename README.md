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
➜  P=FibFiber.exe; N=37; hyperfine --warmup 1 --shell none "$P --num-workers=1 $N" "$P --num-workers=2 $N" "$P --num-workers=4 $N" "$P --num-workers=8 $N"
Benchmark 1: FibFiber.exe --num-workers=1 37
  Time (mean ± σ):      1.251 s ±  0.001 s    [User: 1.246 s, System: 0.004 s]
  Range (min … max):    1.249 s …  1.252 s    10 runs

Benchmark 2: FibFiber.exe --num-workers=2 37
  Time (mean ± σ):     674.7 ms ±   0.5 ms    [User: 1335.8 ms, System: 3.8 ms]
  Range (min … max):   673.6 ms … 675.4 ms    10 runs

Benchmark 3: FibFiber.exe --num-workers=4 37
  Time (mean ± σ):     361.2 ms ±   2.4 ms    [User: 1404.8 ms, System: 7.2 ms]
  Range (min … max):   358.9 ms … 365.7 ms    10 runs

Benchmark 4: FibFiber.exe --num-workers=8 37
  Time (mean ± σ):     489.9 ms ±  16.1 ms    [User: 3193.0 ms, System: 80.9 ms]
  Range (min … max):   472.3 ms … 520.4 ms    10 runs

Summary
  'FibFiber.exe --num-workers=4 37' ran
    1.36 ± 0.05 times faster than 'FibFiber.exe --num-workers=8 37'
    1.87 ± 0.01 times faster than 'FibFiber.exe --num-workers=2 37'
    3.46 ± 0.02 times faster than 'FibFiber.exe --num-workers=1 37'
```

```sh
➜  P=FibPar.exe; N=37; hyperfine --warmup 1 --shell none "$P --num-workers=1 $N" "$P --num-workers=2 $N" "$P --num-workers=4 $N" "$P --num-workers=8 $N"
Benchmark 1: FibPar.exe --num-workers=1 37
  Time (mean ± σ):     934.8 ms ±   1.8 ms    [User: 931.2 ms, System: 3.0 ms]
  Range (min … max):   931.6 ms … 937.6 ms    10 runs

Benchmark 2: FibPar.exe --num-workers=2 37
  Time (mean ± σ):     564.9 ms ±   1.5 ms    [User: 1115.9 ms, System: 3.6 ms]
  Range (min … max):   563.9 ms … 568.9 ms    10 runs

Benchmark 3: FibPar.exe --num-workers=4 37
  Time (mean ± σ):     305.3 ms ±   1.0 ms    [User: 1178.0 ms, System: 7.9 ms]
  Range (min … max):   303.5 ms … 306.8 ms    10 runs

Benchmark 4: FibPar.exe --num-workers=8 37
  Time (mean ± σ):     473.3 ms ±  21.4 ms    [User: 3016.0 ms, System: 97.8 ms]
  Range (min … max):   427.9 ms … 499.9 ms    10 runs

Summary
  'FibPar.exe --num-workers=4 37' ran
    1.55 ± 0.07 times faster than 'FibPar.exe --num-workers=8 37'
    1.85 ± 0.01 times faster than 'FibPar.exe --num-workers=2 37'
    3.06 ± 0.01 times faster than 'FibPar.exe --num-workers=1 37'
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
